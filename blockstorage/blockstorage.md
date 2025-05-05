# `BlockTreeDB`

```cpp
namespace kernel {
/** Access to the block database (blocks/index/) */
class BlockTreeDB : public CDBWrapper
{
public:
    using CDBWrapper::CDBWrapper;
    bool WriteBatchSync(const std::vector<std::pair<int, const CBlockFileInfo*>>& fileInfo, int nLastFile, const std::vector<const CBlockIndex*>& blockinfo);
    bool ReadBlockFileInfo(int nFile, CBlockFileInfo& info);
    bool ReadLastBlockFile(int& nFile);
    bool WriteReindexing(bool fReindexing);
    void ReadReindexing(bool& fReindexing);
    bool WriteFlag(const std::string& name, bool fValue);
    bool ReadFlag(const std::string& name, bool& fValue);
    bool LoadBlockIndexGuts(const Consensus::Params& consensusParams, std::function<CBlockIndex*(const uint256&)> insertBlockIndex, const util::SignalInterrupt& interrupt)
        EXCLUSIVE_LOCKS_REQUIRED(::cs_main);
};
} // namespace kernel
```

Has a dedicated function for reading the `CBlockFileInfo` info for a given
nFile. Is nFile the file descriptor, or some private index? Probably a private
index I suspect, since the `int fd` would not be stable across different runs.

## `CBlockFileInfo`

```cpp
bool BlockTreeDB::ReadBlockFileInfo(int nFile, CBlockFileInfo& info)
{
    // [ Interesting, the "key" is a std::pair, how well-enforced is the way thing
    //   serializes? Is this a common pattern, where the first element is a
    //   prefix (KV-db abuse) and the second is the "key" ]
    return Read(std::make_pair(DB_BLOCK_FILES, nFile), info);
}
```

Let's look at the `CBlockFileInfo` data structure:

```cpp
class CBlockFileInfo
{
public:
    unsigned int nBlocks{};      //!< number of blocks stored in file
    unsigned int nSize{};        //!< number of used bytes of block file
    unsigned int nUndoSize{};    //!< number of used bytes in the undo file
    unsigned int nHeightFirst{}; //!< lowest height of block in file
    unsigned int nHeightLast{};  //!< highest height of block in file
    uint64_t nTimeFirst{};       //!< earliest time of block in file
    uint64_t nTimeLast{};        //!< latest time of block in file

    // [ This probably describes how it gets serialized into DB, wonder if it
    //   gets serialized anywhere else? ]
    SERIALIZE_METHODS(CBlockFileInfo, obj)
    {
        READWRITE(VARINT(obj.nBlocks));
        READWRITE(VARINT(obj.nSize));
        READWRITE(VARINT(obj.nUndoSize));
        READWRITE(VARINT(obj.nHeightFirst));
        READWRITE(VARINT(obj.nHeightLast));
        READWRITE(VARINT(obj.nTimeFirst));
        READWRITE(VARINT(obj.nTimeLast));
    }

    CBlockFileInfo() = default;

    std::string ToString() const; // [ Used only in logging, by BlockManager. ]

    // [ Always followed up with updating nSize, maybe this could be refactored
    //   to also update nSize ]
    /** update statistics (does not update nSize) */
    void AddBlock(unsigned int nHeightIn, uint64_t nTimeIn)
    {
        if (nBlocks == 0 || nHeightFirst > nHeightIn)
            nHeightFirst = nHeightIn;
        if (nBlocks == 0 || nTimeFirst > nTimeIn)
            nTimeFirst = nTimeIn;
        nBlocks++;
        if (nHeightIn > nHeightLast)
            nHeightLast = nHeightIn;
        if (nTimeIn > nTimeLast)
            nTimeLast = nTimeIn;
    }
};
```

## Reindexing flag

```cpp
bool BlockTreeDB::WriteReindexing(bool fReindexing)
{
    if (fReindexing) {
        return Write(DB_REINDEX_FLAG, uint8_t{'1'});
    } else {
        // [ I wonder why erase rather than setting to 0 ]
        return Erase(DB_REINDEX_FLAG);
    }
}

void BlockTreeDB::ReadReindexing(bool& fReindexing)
{
    fReindexing = Exists(DB_REINDEX_FLAG);
}
```

## last block file

```cpp
bool BlockTreeDB::ReadLastBlockFile(int& nFile)
{
    return Read(DB_LAST_BLOCK, nFile);
}
```

## Sync

```cpp
bool BlockTreeDB::WriteBatchSync(const std::vector<std::pair<int, const CBlockFileInfo*>>& fileInfo, int nLastFile, const std::vector<const CBlockIndex*>& blockinfo)
{
    CDBBatch batch(*this);
    for (const auto& [file, info] : fileInfo) {
        batch.Write(std::make_pair(DB_BLOCK_FILES, file), *info);
    }
    batch.Write(DB_LAST_BLOCK, nLastFile);
    for (const CBlockIndex* bi : blockinfo) {
        batch.Write(std::make_pair(DB_BLOCK_INDEX, bi->GetBlockHash()), CDiskBlockIndex{bi});
    }
    return WriteBatch(batch, true);
}
```


## `CBlockIndex`

Each block has a corresponding `CBlockIndex` object, this index object tells you
what `nFile` this block is stored in, and the position of block data
(`nDataPos`), and the position of undo data (`nUndoPos`), 

```cpp
// [ In practice, how can multiple pprev's point to the same block? ]
/** The block chain is a tree shaped structure starting with the
 * genesis block at the root, with each block potentially having multiple
 * candidates to be the next block. A blockindex may have multiple pprev pointing
 * to it, but at most one of them can be part of the currently active branch.
 */
class CBlockIndex
{
public:
    // [ maybe this should be a unique_ptr? ]
    //! pointer to the hash of the block, if any. Memory is owned by this CBlockIndex
    const uint256* phashBlock{nullptr};

    //! pointer to the index of the predecessor of this block
    CBlockIndex* pprev{nullptr};

    // [ Why? ]
    //! pointer to the index of some further predecessor of this block
    CBlockIndex* pskip{nullptr};

    // [ 
    //! height of the entry in the chain. The genesis block has height 0
    int nHeight{0};

    // [ Re: the question above, the nfile of the block is this "blk{nFile}.dat"
    //   nomenclature ]
    //! Which # file this block is stored in (blk?????.dat)
    int nFile GUARDED_BY(::cs_main){0};

    //! Byte offset within blk?????.dat where this block's data is stored
    unsigned int nDataPos GUARDED_BY(::cs_main){0};

    //! Byte offset within rev?????.dat where this block's undo data is stored
    unsigned int nUndoPos GUARDED_BY(::cs_main){0};

    // [ Why? `CBlockIndex` is more `CBlock` than I thought... why? how? when is
    //   which used?
    //! (memory only) Total amount of work (expected number of hashes) in the chain up to and including this block
    arith_uint256 nChainWork{};

    //! Number of transactions in this block. This will be nonzero if the block
    //! reached the VALID_TRANSACTIONS level, and zero otherwise.
    //! Note: in a potential headers-first mode, this number cannot be relied upon
    unsigned int nTx{0};

    //! (memory only) Number of transactions in the chain up to and including this block.
    //! This value will be non-zero if this block and all previous blocks back
    //! to the genesis block or an assumeutxo snapshot block have reached the
    //! VALID_TRANSACTIONS level.
    uint64_t m_chain_tx_count{0};

    //! Verification status of this block. See enum BlockStatus
    //!
    //! Note: this value is modified to show BLOCK_OPT_WITNESS during UTXO snapshot // [ <-- insane! ]
    //! load to avoid a spurious startup failure requiring -reindex.
    //! @sa NeedsRedownload
    //! @sa ActivateSnapshot
    uint32_t nStatus GUARDED_BY(::cs_main){0};

    // [ Similar info in `CBlock`/`CBlockHeader` ]
    //! block header
    int32_t nVersion{0};
    uint256 hashMerkleRoot{};
    uint32_t nTime{0};
    uint32_t nBits{0};
    uint32_t nNonce{0};

    // [ hmmm..... Is this fork tiebreaker?]
    //! (memory only) Sequential id assigned to distinguish order in which blocks are received.
    int32_t nSequenceId{0};

    // [ I need to look at time. ]
    //! (memory only) Maximum nTime in the chain up to and including this block.
    unsigned int nTimeMax{0};

    explicit CBlockIndex(const CBlockHeader& block)
        : nVersion{block.nVersion},
          hashMerkleRoot{block.hashMerkleRoot},
          nTime{block.nTime},
          nBits{block.nBits},
          nNonce{block.nNonce}
    {
    }

    FlatFilePos GetBlockPos() const EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        AssertLockHeld(::cs_main);
        FlatFilePos ret;
        // [ Why the status check? Added in https://github.com/bitcoin/bitcoin/commit/857c61df0b71c8a0482b1bf8fc55849f8ad831b8
        //   When is this possible? Do callers check for this possibility? ]
        if (nStatus & BLOCK_HAVE_DATA) {
            ret.nFile = nFile;
            ret.nPos = nDataPos;
        }
        return ret;
    }

    FlatFilePos GetUndoPos() const EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        AssertLockHeld(::cs_main);
        FlatFilePos ret;
        // [ Same question as above. ]
        if (nStatus & BLOCK_HAVE_UNDO) {
            ret.nFile = nFile;
            ret.nPos = nUndoPos;
        }
        return ret;
    }

    CBlockHeader GetBlockHeader() const
    {
        CBlockHeader block;
        block.nVersion = nVersion;
        if (pprev) 
            // [ Genesis only? ]
            block.hashPrevBlock = pprev->GetBlockHash();
        block.hashMerkleRoot = hashMerkleRoot;
        block.nTime = nTime;
        block.nBits = nBits;
        block.nNonce = nNonce;
        return block;
    }

    uint256 GetBlockHash() const
    {
        assert(phashBlock != nullptr);
        return *phashBlock;
    }

    /**
     * Check whether this block and all previous blocks back to the genesis block or an assumeutxo snapshot block have
     * reached VALID_TRANSACTIONS and had transactions downloaded (and stored to disk) at some point.
     *
     * Does not imply the transactions are consensus-valid (ConnectTip might fail)
     * Does not imply the transactions are still stored on disk. (IsBlockPruned might return true)
     *
     * Note that this will be true for the snapshot base block, if one is loaded, since its m_chain_tx_count value will have
     * been set manually based on the related AssumeutxoData entry.
     */
    bool HaveNumChainTxs() const { return m_chain_tx_count != 0; }

    NodeSeconds Time() const
    {
        return NodeSeconds{std::chrono::seconds{nTime}};
    }

    int64_t GetBlockTime() const
    {
        return (int64_t)nTime;
    }

    int64_t GetBlockTimeMax() const
    {
        return (int64_t)nTimeMax;
    }

    static constexpr int nMedianTimeSpan = 11;

    int64_t GetMedianTimePast() const
    {
        int64_t pmedian[nMedianTimeSpan];
        int64_t* pbegin = &pmedian[nMedianTimeSpan];
        int64_t* pend = &pmedian[nMedianTimeSpan];

        const CBlockIndex* pindex = this;
        for (int i = 0; i < nMedianTimeSpan && pindex; i++, pindex = pindex->pprev)
            *(--pbegin) = pindex->GetBlockTime();

        std::sort(pbegin, pend);
        return pbegin[(pend - pbegin) / 2];
    }

    std::string ToString() const;

    //! Check whether this block index entry is valid up to the passed validity level.
    bool IsValid(enum BlockStatus nUpTo = BLOCK_VALID_TRANSACTIONS) const
        EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        AssertLockHeld(::cs_main);
        assert(!(nUpTo & ~BLOCK_VALID_MASK)); // Only validity flags allowed.
        if (nStatus & BLOCK_FAILED_MASK)
            return false;
        return ((nStatus & BLOCK_VALID_MASK) >= nUpTo);
    }

    //! Raise the validity level of this block index entry.
    //! Returns true if the validity was changed.
    bool RaiseValidity(enum BlockStatus nUpTo) EXCLUSIVE_LOCKS_REQUIRED(::cs_main)
    {
        AssertLockHeld(::cs_main);
        assert(!(nUpTo & ~BLOCK_VALID_MASK)); // Only validity flags allowed.
        if (nStatus & BLOCK_FAILED_MASK) return false;

        if ((nStatus & BLOCK_VALID_MASK) < nUpTo) {
            nStatus = (nStatus & ~BLOCK_VALID_MASK) | nUpTo;
            return true;
        }
        return false;
    }

    //! Build the skiplist pointer for this entry.
    void BuildSkip();

    //! Efficiently find an ancestor of this block.
    CBlockIndex* GetAncestor(int height);
    const CBlockIndex* GetAncestor(int height) const;

    CBlockIndex() = default;
    ~CBlockIndex() = default;

protected:
    //! CBlockIndex should not allow public copy construction because equality
    //! comparison via pointer is very common throughout the codebase, making
    //! use of copy a footgun. Also, use of copies do not have the benefit
    //! of simplifying lifetime considerations due to attributes like pprev and
    //! pskip, which are at risk of becoming dangling pointers in a copied
    //! instance.
    //!
    //! We declare these protected instead of simply deleting them so that
    //! CDiskBlockIndex can reuse copy construction.
    CBlockIndex(const CBlockIndex&) = default;
    CBlockIndex& operator=(const CBlockIndex&) = delete;
    CBlockIndex(CBlockIndex&&) = delete;
    CBlockIndex& operator=(CBlockIndex&&) = delete;
};
```

