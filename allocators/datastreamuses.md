I look, briefly, at every single use of `DataStream` outside of test code, to
see whether or not it contains information that should be zeroed out, or should
be mlocked to prevent paging to swap:

In `src/addrdb.cpp`+`src/addrdb.h`:

```cpp
/** Only used by tests. */
void ReadFromStream(AddrMan& addr, DataStream& ssPeers);
```

😺 Only used by tests.

-----

In `src/addrman.cpp` `Addrman::Serialize(DataStream&)` &
`Unserialize(DataStream&)`, are explicitly instantiated, these are used in
`SerializeFileDB` and `DeserializeDB` which are used to serialize
(`DumpPeerAddresses`) addrman to disk, and to deserialize addrman from disk
(`LoadAddrman`).

The most valuable secret seems to be addrman's `nKey` used to determine the
address buckets randomly.

-------

In `src/blockencodings.cpp`:

```cpp
void CBlockHeaderAndShortTxIDs::FillShortTxIDSelector() const {
    DataStream stream{};
    stream << header << nonce;
    CSHA256 hasher;
    hasher.Write((unsigned char*)&(*stream.begin()), stream.end() - stream.begin());
    uint256 shorttxidhash;
    hasher.Finalize(shorttxidhash.begin());
    shorttxidk0 = shorttxidhash.GetUint64(0);
    shorttxidk1 = shorttxidhash.GetUint64(1);
}
```

Here we are just using the DataStream to be able to Serialize the block header
and nonce into a string of bytes that get hashed to make short id k0 and k1 for
[BIP 152](https://github.com/bitcoin/bips/blob/master/bip-0152.mediawiki#short-transaction-ids).

This gets invoked when we construct a `CBlockHeaderandShortTxIDs` for an INV of
type `MSG_CMPCT_BLOCK` in `PeerManagerImpl::SendMessage()`.

-------

In `src/common/blooms.cpp`:

DataStream is used to deserialize outpoints into our bloom filter, these are not
secrets in any way:

```cpp
void CBloomFilter::insert(const COutPoint& outpoint)
{
    DataStream stream{};
    stream << outpoint;
    insert(MakeUCharSpan(stream));
}
```

-------

In `src/core_read.cpp`:

DataStream is used in `DecodeTx` for serialization/deserialization of the
transaction data, used afaict only in RPC's for deserializing user arguments
into `CMutableTransaction`'s.

It's used in `DecodeHexBlockHeader()`which deserializes a block header argument
into a `CBlockHeader` for the `submitheader` rpc.

Similar for `DecodeHexBlk()` used by the `getblocktemplate` and `submitblock`
rpc's.

----

In `src/core_write.cpp`:

```cpp
void CBloomFilter::insert(const COutPoint& outpoint)
{
    DataStream stream{};
    stream << outpoint;
    insert(MakeUCharSpan(stream));
}
```

`EncodeHexTx` is only used in RPC's, and transaction data does not contain
secrets.

------

In `dbwrapper.h` and `dbwrapper.cpp` it is used exclusively to serialize and
deserialize coinsdb keys and values, none of which is secret.

--------

In `src/external_signer`:

```cpp
bool ExternalSigner::SignTransaction(PartiallySignedTransaction& psbtx, std::string& error)
{
    // Serialize the PSBT
    DataStream ssTx{};
    ssTx << psbtx;
```

I don't think this is secret, but I don't know enough about PSBT's.

-------

There is some scaffolding for being able to transmit serializable stuff over the
IPC wire in `src/capnp/common-types.h`, I assume this depends on how it's used,
nothing essentially secret.

--------

In `src/kernel/coinstats.cpp`:

```cpp
void ApplyCoinHash(MuHash3072& muhash, const COutPoint& outpoint, const Coin& coin)
{
    DataStream ss{};
    TxOutSer(ss, outpoint, coin);
    muhash.Insert(MakeUCharSpan(ss));
}
```

Here it's used for serializing oupoints and coins for creating the AssumeUTXO
assumed utxo set hash, nothing secret.

-------

In `src/net.cpp`:

In `ConvertSeeds()` serialized seeds get converted into usable address objects, we
initialize a DataStream with the input seeds that we are going to try connecting
to during node bootstrapping.

```cpp
//! Convert the serialized seeds into usable address objects.
static std::vector<CAddress> ConvertSeeds(const std::vector<uint8_t> &vSeedsIn)
{
    // It'll only connect to one or two seed nodes because once it connects,
    // it'll get a pile of addresses with newer timestamps.
    // Seed nodes are given a random 'last seen time' of between one and two
    // weeks ago.
    const auto one_week{7 * 24h};
    std::vector<CAddress> vSeedsOut;
    FastRandomContext rng;
    ParamsStream s{DataStream{vSeedsIn}, CAddress::V2_NETWORK};
    while (!s.eof()) {
        CService endpoint;
        s >> endpoint;
        CAddress addr{endpoint, SeedsServiceFlags()};
        addr.nTime = rng.rand_uniform_delay(Now<NodeSeconds>() - one_week, -one_week);
        LogDebug(BCLog::NET, "Added hardcoded seed: %s\n", addr.ToStringAddrPort());
        vSeedsOut.push_back(addr);
    }
    return vSeedsOut;
}
```

It is also used for creating an empty `CNetMessage` which has a `DataStream`
member in `CNetMessage V2Transport::GetReceivedMessage()`:

```cpp
//! Convert the serialized seeds into usable address objects.
static std::vector<CAddress> ConvertSeeds(const std::vector<uint8_t> &vSeedsIn)
{
    // It'll only connect to one or two seed nodes because once it connects,
    // it'll get a pile of addresses with newer timestamps.
    // Seed nodes are given a random 'last seen time' of between one and two
    // weeks ago.
    const auto one_week{7 * 24h};
    std::vector<CAddress> vSeedsOut;
    FastRandomContext rng;
    ParamsStream s{DataStream{vSeedsIn}, CAddress::V2_NETWORK};
    while (!s.eof()) {
        CService endpoint;
        s >> endpoint;
        CAddress addr{endpoint, SeedsServiceFlags()};
        addr.nTime = rng.rand_uniform_delay(Now<NodeSeconds>() - one_week, -one_week);
        LogDebug(BCLog::NET, "Added hardcoded seed: %s\n", addr.ToStringAddrPort());
        vSeedsOut.push_back(addr);
    }
    return vSeedsOut;
}
```

--------

In `net.h`

`CNetMessage` the universal p2p message container used a `DataStream` to store
received message data.

```cpp
/** Transport protocol agnostic message container.
 * Ideally it should only contain receive time, payload,
 * type and size.
 */
class CNetMessage
{
public:
    DataStream m_recv;                   //!< received message data
    std::chrono::microseconds m_time{0}; //!< time of message receipt
    uint32_t m_message_size{0};          //!< size of the payload
    uint32_t m_raw_message_size{0};      //!< used wire size of the message (including header/checksum)
    std::string m_type;

    explicit CNetMessage(DataStream&& recv_in) : m_recv(std::move(recv_in)) {}
    // Only one CNetMessage object will exist for the same message on either
    // the receive or processing queue. For performance reasons we therefore
    // delete the copy constructor and assignment operator to avoid the
    // possibility of copying CNetMessage objects.
    CNetMessage(CNetMessage&&) = default;
    CNetMessage(const CNetMessage&) = delete;
    CNetMessage& operator=(CNetMessage&&) = default;
    CNetMessage& operator=(const CNetMessage&) = delete;
};
```

It's also used for the lower level handling of messages, including partially
received header buffers and received socket data in `V1Transport` as in v2
transport above in `net.cpp`.

```cpp
/** Transport protocol agnostic message container.
 * Ideally it should only contain receive time, payload,
 * type and size.
 */
class CNetMessage
{
public:
    DataStream m_recv;                   //!< received message data
    std::chrono::microseconds m_time{0}; //!< time of message receipt
    uint32_t m_message_size{0};          //!< size of the payload
    uint32_t m_raw_message_size{0};      //!< used wire size of the message (including header/checksum)
    std::string m_type;

    explicit CNetMessage(DataStream&& recv_in) : m_recv(std::move(recv_in)) {}
    // Only one CNetMessage object will exist for the same message on either
    // the receive or processing queue. For performance reasons we therefore
    // delete the copy constructor and assignment operator to avoid the
    // possibility of copying CNetMessage objects.
    CNetMessage(CNetMessage&&) = default;
    CNetMessage(const CNetMessage&) = delete;
    CNetMessage& operator=(CNetMessage&&) = default;
    CNetMessage& operator=(const CNetMessage&) = delete;
};
```

--------

In `src/net_processing.cpp` it used for representing the received data when
processing messages in the great `PeerManagerImpl::ProcessMessage()`:

```cpp
void PeerManagerImpl::ProcessMessage(CNode& pfrom, const std::string& msg_type, DataStream& vRecv,
                                     const std::chrono::microseconds time_received,
                                     const std::atomic<bool>& interruptMsgProc)
{
```

And for Processing BIP 157 cfilters: 

```cpp
/**
 * Handle a cfilters request.
 *
 * May disconnect from the peer in the case of a bad request.
 *
 * @param[in]   node            The node that we received the request from
 * @param[in]   peer            The peer that we received the request from
 * @param[in]   vRecv           The raw message received
 */
void PeerManagerImpl::ProcessGetCFilters(CNode& node, Peer& peer, DataStream& vRecv)
{
    uint8_t filter_type_ser;
    uint32_t start_height;
    uint256 stop_hash;

    vRecv >> filter_type_ser >> start_height >> stop_hash;

    const BlockFilterType filter_type = static_cast<BlockFilterType>(filter_type_ser);

    const CBlockIndex* stop_index;
    BlockFilterIndex* filter_index;
    if (!PrepareBlockFilterRequest(node, peer, filter_type, start_height, stop_hash,
                                   MAX_GETCFILTERS_SIZE, stop_index, filter_index)) {
        return;
    }

    std::vector<BlockFilter> filters;
    if (!filter_index->LookupFilterRange(start_height, stop_index, filters)) {
        LogDebug(BCLog::NET, "Failed to find block filter in index: filter_type=%s, start_height=%d, stop_hash=%s\n",
                     BlockFilterTypeName(filter_type), start_height, stop_hash.ToString());
        return;
    }

    for (const auto& filter : filters) {
        MakeAndPushMessage(node, NetMsgType::CFILTER, filter);
    }
```

and bip 157 cfheaders:

```cpp
/**
 * Handle a cfheaders request.
 *
 * May disconnect from the peer in the case of a bad request.
 *
 * @param[in]   node            The node that we received the request from
 * @param[in]   peer            The peer that we received the request from
 * @param[in]   vRecv           The raw message received
 */
 void PeerManagerImpl::ProcessGetCFHeaders(CNode& node, Peer& peer, DataStream& vRecv)
{
    uint8_t filter_type_ser;
    uint32_t start_height;
    uint256 stop_hash;

    vRecv >> filter_type_ser >> start_height >> stop_hash;

    const BlockFilterType filter_type = static_cast<BlockFilterType>(filter_type_ser);

    const CBlockIndex* stop_index;
    BlockFilterIndex* filter_index;
    if (!PrepareBlockFilterRequest(node, peer, filter_type, start_height, stop_hash,
                                   MAX_GETCFHEADERS_SIZE, stop_index, filter_index)) {
        return;
    }

    uint256 prev_header;
    if (start_height > 0) {
        const CBlockIndex* const prev_block =
            stop_index->GetAncestor(static_cast<int>(start_height - 1));
        if (!filter_index->LookupFilterHeader(prev_block, prev_header)) {
            LogDebug(BCLog::NET, "Failed to find block filter header in index: filter_type=%s, block_hash=%s\n",
                         BlockFilterTypeName(filter_type), prev_block->GetBlockHash().ToString());
            return;
        }
    }

    std::vector<uint256> filter_hashes;
    if (!filter_index->LookupFilterHashRange(start_height, stop_index, filter_hashes)) {
        LogDebug(BCLog::NET, "Failed to find block filter hashes in index: filter_type=%s, start_height=%d, stop_hash=%s\n",
                     BlockFilterTypeName(filter_type), start_height, stop_hash.ToString());
        return;
    }

    MakeAndPushMessage(node, NetMsgType::CFHEADERS,
              filter_type_ser,
              stop_index->GetBlockHash(),
              prev_header,
              filter_hashes);
}
```

------

In `src/psbt.cpp`:

```cpp
bool DecodeRawPSBT(PartiallySignedTransaction& psbt, Span<const std::byte> tx_data, std::string& error)
{
    DataStream ss_data{tx_data};
    try {
        ss_data >> psbt;
        if (!ss_data.empty()) {
            error = "extra data after PSBT";
            return false;
        }
    } catch (const std::exception& e) {
        error = e.what();
        return false;
    }
    return true;
}
```

It is used for deserializing hex data into a `PartiallySignedTransaction`
object.

--------


In `src/qt/psbtoperationsdialog.cpp`:

Bitcoin Qt interface for 

Copying psbt to clipboard:

```cpp
void PSBTOperationsDialog::copyToClipboard() {
    DataStream ssTx{};
    ssTx << m_transaction_data;
    GUIUtil::setClipboard(EncodeBase64(ssTx.str()).c_str());
    showStatus(tr("PSBT copied to clipboard."), StatusLevel::INFO);
}
```

Saving PSBT to disk:
```cpp
void PSBTOperationsDialog::saveTransaction() {
    DataStream ssTx{};
    ssTx << m_transaction_data;

    QString selected_filter;
    QString filename_suggestion = "";
    bool first = true;
    for (const CTxOut& out : m_transaction_data.tx->vout) {
        if (!first) {
            filename_suggestion.append("-");
        }
        CTxDestination address;
        ExtractDestination(out.scriptPubKey, address);
        QString amount = BitcoinUnits::format(m_client_model->getOptionsModel()->getDisplayUnit(), out.nValue);
        QString address_str = QString::fromStdString(EncodeDestination(address));
        filename_suggestion.append(address_str + "-" + amount);
        first = false;
    }
    filename_suggestion.append(".psbt");
    QString filename = GUIUtil::getSaveFileName(this,
        tr("Save Transaction Data"), filename_suggestion,
        //: Expanded name of the binary PSBT file format. See: BIP 174.
        tr("Partially Signed Transaction (Binary)") + QLatin1String(" (*.psbt)"), &selected_filter);
    if (filename.isEmpty()) {
        return;
    }
    std::ofstream out{filename.toLocal8Bit().data(), std::ofstream::out | std::ofstream::binary};
    out << ssTx.str();
    out.close();
    showStatus(tr("PSBT saved to disk."), StatusLevel::INFO);
}
```

--------



