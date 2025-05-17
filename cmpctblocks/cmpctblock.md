First, some background structures from `src/blockencodings.h`:

```cpp
class CBlockHeaderAndShortTxIDs {
private:
    // [ To avoid DoS attacks with shorttxid collisions, BIP 152 specifies the
    //   use of SipHash with the txid as input, and keys k0 and k1 taken from
    //   SHA256(blockheader || nonce). This nonce is also broadcast in the
    //   cmpctblock.
    mutable uint64_t shorttxidk0, shorttxidk1;
    uint64_t nonce;

    void FillShortTxIDSelector() const;

    friend class PartiallyDownloadedBlock;

protected:
    std::vector<uint64_t> shorttxids;
    std::vector<PrefilledTransaction> prefilledtxn;

public:
    static constexpr int SHORTTXIDS_LENGTH = 6;

    // [ Const maybe? ]
    CBlockHeader header;

    /**
     * Dummy for deserialization
     */
    CBlockHeaderAndShortTxIDs() = default;

    /**
     * @param[in]  nonce  This should be randomly generated, and is used for the siphash secret key
     */
    CBlockHeaderAndShortTxIDs(const CBlock& block, const uint64_t nonce);

    uint64_t GetShortID(const Wtxid& wtxid) const;

    size_t BlockTxCount() const { return shorttxids.size() + prefilledtxn.size(); }
};

// [ This class is primarily a utility used to perform compact block
//   reconciliation with the mempool, it's initialized with a pointer to the
//   node's mempool, and then `InitData()` is just used to check if we *can* do
//   reconciliation. ]
class PartiallyDownloadedBlock {
protected:
    std::vector<CTransactionRef> txn_available;
    size_t prefilled_count = 0, mempool_count = 0, extra_count = 0;
    const CTxMemPool* pool;
public:
    CBlockHeader header;

    explicit PartiallyDownloadedBlock(CTxMemPool* poolIn) : pool(poolIn) {}

    // extra_txn is a list of extra orphan/conflicted/etc transactions to look at
    ReadStatus InitData(const CBlockHeaderAndShortTxIDs& cmpctblock, const std::vector<CTransactionRef>& extra_txn);
    bool IsTxAvailable(size_t index) const;
    ReadStatus FillBlock(CBlock& block, const std::vector<CTransactionRef>& vtx_missing);
};
```

Let's look at how a node handles receipt of a `cmpctblock` or
`NetMsgType::CMPCTBLOCK` message:

```cpp
void PeerManagerImpl::ProcessMessage(CNode& pfrom, const std::string& msg_type, DataStream& vRecv,
                                     const std::chrono::microseconds time_received,
                                     const std::atomic<bool>& interruptMsgProc)
{
    AssertLockHeld(g_msgproc_mutex);
    if (msg_type == NetMsgType::CMPCTBLOCK)
    {
        // Ignore cmpctblock received while importing
        if (m_chainman.m_blockman.LoadingBlocks()) {
            LogDebug(BCLog::NET, "Unexpected cmpctblock message received from peer %d\n", pfrom.GetId());
            return;
        }

        // [ Deserialize vRecv into cmpctblock. ]
        CBlockHeaderAndShortTxIDs cmpctblock;
        vRecv >> cmpctblock;

        bool received_new_header = false;
        const auto blockhash = cmpctblock.header.GetHash();

        {
        // [ It's the Block index lookups that require cs_main locks. ]
        LOCK(cs_main);

        // [ The header has the hash of the previous block, and we look to see if we have
        //   that block indexed. ]
        const CBlockIndex* prev_block = m_chainman.m_blockman.LookupBlockIndex(cmpctblock.header.hashPrevBlock);
        if (!prev_block) {
            // [ I struggle to understand this comment, "instead of DoSing in AcceptBlockHeader". ]
            // Doesn't connect (or is genesis), instead of DoSing in AcceptBlockHeader, request deeper headers
            if (!m_chainman.IsInitialBlockDownload()) {
                MaybeSendGetHeaders(pfrom, GetLocator(m_chainman.m_best_header), *peer);
            }
            return;

        // [ OK, we have the block's parent, check the work, why is it both? nChainWork represents the cumulative work of the
        //   chain at that block, add to that the work in the header, the AntiDoSWorkThreshold is the work amount as far as 144 blocks
        //   below tip..
        } else if (prev_block->nChainWork + CalculateClaimedHeadersWork({{cmpctblock.header}}) < GetAntiDoSWorkThreshold()) {
            // If we get a low-work header in a compact block, we can ignore it.
            LogDebug(BCLog::NET, "Ignoring low-work compact block from peer %d\n", pfrom.GetId());
            return;
        }

        // [ Check if we already know this cmpctblock, is it's hash in our index? ]
        if (!m_chainman.m_blockman.LookupBlockIndex(blockhash)) {
            received_new_header = true;
        }
        }

        const CBlockIndex *pindex = nullptr;
        BlockValidationState state;
        if (!m_chainman.ProcessNewBlockHeaders({{cmpctblock.header}}, /*min_pow_checked=*/true, state, &pindex)) {
            if (state.IsInvalid()) {
                MaybePunishNodeForBlock(pfrom.GetId(), state, /*via_compact_block=*/true, "invalid header via cmpctblock");
                return;
            }
        }

        // If AcceptBlockHeader returned true, it set pindex
        Assert(pindex);
        if (received_new_header) {
            LogBlockHeader(*pindex, pfrom, /*via_compact_block=*/true);
        }

        bool fProcessBLOCKTXN = false;

        // If we end up treating this as a plain headers message, call that as well
        // without cs_main.
        bool fRevertToHeaderProcessing = false;

        // Keep a CBlock for "optimistic" compactblock reconstructions (see
        // below)
        std::shared_ptr<CBlock> pblock = std::make_shared<CBlock>();
        bool fBlockReconstructed = false;

        {
        LOCK(cs_main);
        UpdateBlockAvailability(pfrom.GetId(), pindex->GetBlockHash());

        CNodeState *nodestate = State(pfrom.GetId());

        // If this was a new header with more work than our tip, update the
        // peer's last block announcement time
        if (received_new_header && pindex->nChainWork > m_chainman.ActiveChain().Tip()->nChainWork) {
            nodestate->m_last_block_announcement = GetTime();
        }

        if (pindex->nStatus & BLOCK_HAVE_DATA) // Nothing to do here
            return;


        // [ mapBlocksInFlight is a multimap of `block_hash:pair<node, QueuedBlock>`, where QueuedBlock
        //   maintains some state for a queued block in transit from a peer.
        auto range_flight = mapBlocksInFlight.equal_range(pindex->GetBlockHash());
        // [ equal_range returns a pair, with the first element not less than the value, and the first
        //   element greater than the value. So, if the element is not found, the distance here will be 0. ]
        size_t already_in_flight = std::distance(range_flight.first, range_flight.second);
        bool requested_block_from_this_peer{false};

        // Multimap ensures ordering of outstanding requests. It's either empty or first in line.
        bool first_in_flight = already_in_flight == 0 || (range_flight.first->second.first == pfrom.GetId());

        while (range_flight.first != range_flight.second) {
            if (range_flight.first->second.first == pfrom.GetId()) {
                requested_block_from_this_peer = true;
                break;
            }
            range_flight.first++;
        }

        if (pindex->nChainWork <= m_chainman.ActiveChain().Tip()->nChainWork || // We know something better
                pindex->nTx != 0) { // We had this block at some point, but pruned it
            if (requested_block_from_this_peer) {
                // We requested this block for some reason, but our mempool will probably be useless
                // so we just grab the block via normal getdata
                std::vector<CInv> vInv(1);
                vInv[0] = CInv(MSG_BLOCK | GetFetchFlags(*peer), blockhash);
                MakeAndPushMessage(pfrom, NetMsgType::GETDATA, vInv);
            }
            return;
        }

        // If we're not close to tip yet, give up and let parallel block fetch work its magic
        if (!already_in_flight && !CanDirectFetch()) {
            return;
        }

        // We want to be a bit conservative just to be extra careful about DoS
        // possibilities in compact block processing...
        if (pindex->nHeight <= m_chainman.ActiveChain().Height() + 2) {
            // [ Two anti-dos checks, per-block inflight limit not exceeded, per-node inflight limit not exceeded, unless
            //   requested the block, make an exception. ]
            if ((already_in_flight < MAX_CMPCTBLOCKS_INFLIGHT_PER_BLOCK && nodestate->vBlocksInFlight.size() < MAX_BLOCKS_IN_TRANSIT_PER_PEER) ||
                 requested_block_from_this_peer) {

                // [ Precarious IMO, we depend on `BlockRequested` to initialize this pointer, else null deref below. ]
                std::list<QueuedBlock>::iterator* queuedBlockIt = nullptr;
                if (!BlockRequested(pfrom.GetId(), *pindex, &queuedBlockIt)) {
                    if (!(*queuedBlockIt)->partialBlock)
                        (*queuedBlockIt)->partialBlock.reset(new PartiallyDownloadedBlock(&m_mempool));
                    else {
                        // The block was already in flight using compact blocks from the same peer
                        LogDebug(BCLog::NET, "Peer sent us compact block we were already syncing!\n");
                        return;
                    }
                }

                // [ Super dangerous in my opinion, but it *just* works, if true returned
                //   and an iterator pointer passed to BlockRequested, this will always be
                //   initialized, if false, it sometimes won't be but that's handled above. ]
                PartiallyDownloadedBlock& partialBlock = *(*queuedBlockIt)->partialBlock;
                // [ Check if cmpct block can be reconciled with partialBlock ]
                ReadStatus status = partialBlock.InitData(cmpctblock, vExtraTxnForCompact);
                if (status == READ_STATUS_INVALID) {
                    RemoveBlockRequest(pindex->GetBlockHash(), pfrom.GetId()); // Reset in-flight state in case Misbehaving does not result in a disconnect
                    Misbehaving(*peer, "invalid compact block");
                    return;
                } else if (status == READ_STATUS_FAILED) {
                    if (first_in_flight)  {
                        // Duplicate txindexes, the block is now in-flight, so just request it
                        std::vector<CInv> vInv(1);
                        vInv[0] = CInv(MSG_BLOCK | GetFetchFlags(*peer), blockhash);
                        MakeAndPushMessage(pfrom, NetMsgType::GETDATA, vInv);
                    } else {
                        // Give up for this peer and wait for other peer(s)
                        RemoveBlockRequest(pindex->GetBlockHash(), pfrom.GetId());
                    }
                    return;
                }

                BlockTransactionsRequest req;
                for (size_t i = 0; i < cmpctblock.BlockTxCount(); i++) {
                    if (!partialBlock.IsTxAvailable(i))
                        req.indexes.push_back(i);
                }
                if (req.indexes.empty()) {
                    fProcessBLOCKTXN = true;
                } else if (first_in_flight) {
                    // We will try to round-trip any compact blocks we get on failure,
                    // as long as it's first...
                    req.blockhash = pindex->GetBlockHash();
                    MakeAndPushMessage(pfrom, NetMsgType::GETBLOCKTXN, req);
                } else if (pfrom.m_bip152_highbandwidth_to &&
                    (!pfrom.IsInboundConn() ||
                    IsBlockRequestedFromOutbound(blockhash) ||
                    already_in_flight < MAX_CMPCTBLOCKS_INFLIGHT_PER_BLOCK - 1)) {
                    // ... or it's a hb relay peer and:
                    // - peer is outbound, or
                    // - we already have an outbound attempt in flight(so we'll take what we can get), or
                    // - it's not the final parallel download slot (which we may reserve for first outbound)
                    req.blockhash = pindex->GetBlockHash();
                    MakeAndPushMessage(pfrom, NetMsgType::GETBLOCKTXN, req);
                } else {
                    // Give up for this peer and wait for other peer(s)
                    RemoveBlockRequest(pindex->GetBlockHash(), pfrom.GetId());
                }
            } else {
                // This block is either already in flight from a different
                // peer, or this peer has too many blocks outstanding to
                // download from.
                // Optimistically try to reconstruct anyway since we might be
                // able to without any round trips.
                PartiallyDownloadedBlock tempBlock(&m_mempool);
                ReadStatus status = tempBlock.InitData(cmpctblock, vExtraTxnForCompact);
                if (status != READ_STATUS_OK) {
                    // TODO: don't ignore failures
                    return;
                }
                std::vector<CTransactionRef> dummy;
                status = tempBlock.FillBlock(*pblock, dummy);
                if (status == READ_STATUS_OK) {
                    fBlockReconstructed = true;
                }
            }
        } else {
            if (requested_block_from_this_peer) {
                // We requested this block, but its far into the future, so our
                // mempool will probably be useless - request the block normally
                std::vector<CInv> vInv(1);
                vInv[0] = CInv(MSG_BLOCK | GetFetchFlags(*peer), blockhash);
                MakeAndPushMessage(pfrom, NetMsgType::GETDATA, vInv);
                return;
            } else {
                // If this was an announce-cmpctblock, we want the same treatment as a header message
                fRevertToHeaderProcessing = true;
            }
        }
        } // cs_main

        if (fProcessBLOCKTXN) {
            BlockTransactions txn;
            txn.blockhash = blockhash;
            return ProcessCompactBlockTxns(pfrom, *peer, txn);
        }

        if (fRevertToHeaderProcessing) {
            // Headers received from HB compact block peers are permitted to be
            // relayed before full validation (see BIP 152), so we don't want to disconnect
            // the peer if the header turns out to be for an invalid block.
            // Note that if a peer tries to build on an invalid chain, that
            // will be detected and the peer will be disconnected/discouraged.
            return ProcessHeadersMessage(pfrom, *peer, {cmpctblock.header}, /*via_compact_block=*/true);
        }

        if (fBlockReconstructed) {
            // If we got here, we were able to optimistically reconstruct a
            // block that is in flight from some other peer.
            {
                LOCK(cs_main);
                mapBlockSource.emplace(pblock->GetHash(), std::make_pair(pfrom.GetId(), false));
            }
            // Setting force_processing to true means that we bypass some of
            // our anti-DoS protections in AcceptBlock, which filters
            // unrequested blocks that might be trying to waste our resources
            // (eg disk space). Because we only try to reconstruct blocks when
            // we're close to caught up (via the CanDirectFetch() requirement
            // above, combined with the behavior of not requesting blocks until
            // we have a chain with at least the minimum chain work), and we ignore
            // compact blocks with less work than our tip, it is safe to treat
            // reconstructed compact blocks as having been requested.
            ProcessBlock(pfrom, pblock, /*force_processing=*/true, /*min_pow_checked=*/true);
            LOCK(cs_main); // hold cs_main for CBlockIndex::IsValid()
            if (pindex->IsValid(BLOCK_VALID_TRANSACTIONS)) {
                // Clear download state for this block, which is in
                // process from some other peer.  We do this after calling
                // ProcessNewBlock so that a malleated cmpctblock announcement
                // can't be used to interfere with block relay.
                RemoveBlockRequest(pblock->GetHash(), std::nullopt);
            }
        }
        return;
    }
}
```

`PartiallyDownloadedBlock::InitData()`:

```cpp
ReadStatus PartiallyDownloadedBlock::InitData(const CBlockHeaderAndShortTxIDs& cmpctblock, const std::vector<CTransactionRef>& extra_txn) {
    // [ If it's nuttin' it's no good. ]
    if (cmpctblock.header.IsNull() || (cmpctblock.shorttxids.empty() && cmpctblock.prefilledtxn.empty()))
        return READ_STATUS_INVALID;
    // [ If it's too big, it's no good. ]
    if (cmpctblock.shorttxids.size() + cmpctblock.prefilledtxn.size() > MAX_BLOCK_WEIGHT / MIN_SERIALIZABLE_TRANSACTION_WEIGHT)
        return READ_STATUS_INVALID;

    // [ This partially downloaded block object should not be initialized already. ]
    if (!header.IsNull() || !txn_available.empty()) return READ_STATUS_INVALID;

    // [ initialize headers. ]
    header = cmpctblock.header;
    // [ preallocate tx vector txn_available based on cmpctblock tx count (shorttxid count + prefill count.) ]
    txn_available.resize(cmpctblock.BlockTxCount());

    // [ Loop through each prefill tx. ]
    int32_t lastprefilledindex = -1;
    for (size_t i = 0; i < cmpctblock.prefilledtxn.size(); i++) {
        // [ If it's null, this cmpct is no good! ]
        if (cmpctblock.prefilledtxn[i].tx->IsNull())
            return READ_STATUS_INVALID;

        // [ why is this += ?? ]
        // [ answer: prefilled txn indexes are relative, they tell you how many shorttxid's
        //   to skip. ]
        lastprefilledindex += cmpctblock.prefilledtxn[i].index + 1; //index is a uint16_t, so can't overflow here
        if (lastprefilledindex > std::numeric_limits<uint16_t>::max())
            return READ_STATUS_INVALID;
        if ((uint32_t)lastprefilledindex > cmpctblock.shorttxids.size() + i) {
            // If we are inserting a tx at an index greater than our full list of shorttxids
            // plus the number of prefilled txn we've inserted, then we have txn for which we
            // have neither a prefilled txn or a shorttxid!
            return READ_STATUS_INVALID;
        }
        // [ insert the prefill into the txn_available array at the right position. ]
        txn_available[lastprefilledindex] = cmpctblock.prefilledtxn[i].tx;
    }
    prefilled_count = cmpctblock.prefilledtxn.size();

    // Calculate map of txids -> positions and check mempool to see what we have (or don't)
    // Because well-formed cmpctblock messages will have a (relatively) uniform distribution
    // of short IDs, any highly-uneven distribution of elements can be safely treated as a
    // READ_STATUS_FAILED.
    std::unordered_map<uint64_t, uint16_t> shorttxids(cmpctblock.shorttxids.size());
    uint16_t index_offset = 0;
    for (size_t i = 0; i < cmpctblock.shorttxids.size(); i++) {
        // [ loop through the prefills, keep count of the offset. ]
        while (txn_available[i + index_offset])
            index_offset++;
        // [ the shorttxid cmpctblock.shorttxids[i], has i + index_offset position in the block. ]
        shorttxids[cmpctblock.shorttxids[i]] = i + index_offset;
        // To determine the chance that the number of entries in a bucket exceeds N,
        // we use the fact that the number of elements in a single bucket is
        // binomially distributed (with n = the number of shorttxids S, and p =
        // 1 / the number of buckets), that in the worst case the number of buckets is
        // equal to S (due to std::unordered_map having a default load factor of 1.0),
        // and that the chance for any bucket to exceed N elements is at most
        // buckets * (the chance that any given bucket is above N elements).
        // Thus: P(max_elements_per_bucket > N) <= S * (1 - cdf(binomial(n=S,p=1/S), N)).
        // If we assume blocks of up to 16000, allowing 12 elements per bucket should
        // only fail once per ~1 million block transfers (per peer and connection).
        if (shorttxids.bucket_size(shorttxids.bucket(cmpctblock.shorttxids[i])) > 12)
            return READ_STATUS_FAILED;
    }
    // TODO: in the shortid-collision case, we should instead request both transactions
    // which collided. Falling back to full-block-request here is overkill.
    if (shorttxids.size() != cmpctblock.shorttxids.size())
        return READ_STATUS_FAILED; // Short ID collision

    // [ Prealloc a vector of bools the size of txn_available. ]
    std::vector<bool> have_txn(txn_available.size());
    {
    // [ lock the pool mutex. ]
    LOCK(pool->cs);
    // [ loop through each tx in the mempool. ]
    for (const auto& tx : pool->txns_randomized) {
        // [ calculate the transaction's shortid (is this expensive?). ]
        uint64_t shortid = cmpctblock.GetShortID(tx->GetWitnessHash());
        // [ find it's position in the cmpct block shorttxid's. ]
        std::unordered_map<uint64_t, uint16_t>::iterator idit = shorttxids.find(shortid);
        if (idit != shorttxids.end()) {
            if (!have_txn[idit->second]) {
                txn_available[idit->second] = tx;
                have_txn[idit->second]  = true;
                mempool_count++;
            } else {
                // If we find two mempool txn that match the short id, just request it.
                // This should be rare enough that the extra bandwidth doesn't matter,
                // but eating a round-trip due to FillBlock failure would be annoying
                if (txn_available[idit->second]) {
                    txn_available[idit->second].reset();
                    mempool_count--;
                }
            }
        }
        // Though ideally we'd continue scanning for the two-txn-match-shortid case,
        // the performance win of an early exit here is too good to pass up and worth
        // the extra risk.
        if (mempool_count == shorttxids.size())
            break;
    }
    }

    for (size_t i = 0; i < extra_txn.size(); i++) {
        if (extra_txn[i] == nullptr) {
            continue;
        }
        uint64_t shortid = cmpctblock.GetShortID(extra_txn[i]->GetWitnessHash());
        std::unordered_map<uint64_t, uint16_t>::iterator idit = shorttxids.find(shortid);
        if (idit != shorttxids.end()) {
            if (!have_txn[idit->second]) {
                txn_available[idit->second] = extra_txn[i];
                have_txn[idit->second]  = true;
                mempool_count++;
                extra_count++;
            } else {
                // If we find two mempool/extra txn that match the short id, just
                // request it.
                // This should be rare enough that the extra bandwidth doesn't matter,
                // but eating a round-trip due to FillBlock failure would be annoying
                // Note that we don't want duplication between extra_txn and mempool to
                // trigger this case, so we compare witness hashes first
                if (txn_available[idit->second] &&
                        txn_available[idit->second]->GetWitnessHash() != extra_txn[i]->GetWitnessHash()) {
                    txn_available[idit->second].reset();
                    mempool_count--;
                    extra_count--;
                }
            }
        }
        // Though ideally we'd continue scanning for the two-txn-match-shortid case,
        // the performance win of an early exit here is too good to pass up and worth
        // the extra risk.
        if (mempool_count == shorttxids.size())
            break;
    }

    LogDebug(BCLog::CMPCTBLOCK, "Initialized PartiallyDownloadedBlock for block %s using a cmpctblock of size %lu\n", cmpctblock.header.GetHash().ToString(), GetSerializeSize(cmpctblock));

    return READ_STATUS_OK;
}
```
