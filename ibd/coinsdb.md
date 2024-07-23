# `CCoinsViewDB`

## `class CDBWrapper`

<details>


<summary>CDBWrapper Annotated</summary>

```cpp
class CDBWrapper
{
    friend const std::vector<unsigned char>& dbwrapper_private::GetObfuscateKey(const CDBWrapper &w);
private:
    //! holds all leveldb-specific fields of this class
    std::unique_ptr<LevelDBContext> m_db_context;

    //! the name of this database
    std::string m_name;

    // [ Obfuscation stuff added by James O'Beirne in #6650 which does XOR
    //   obfuscation of chainstate db to prevent spurious detection and
    //   quarantining by AV software that scans our plaintext db. ]

    //! a key used for optional XOR-obfuscation of the database
    std::vector<unsigned char> obfuscate_key;

    //! the key under which the obfuscation key is stored
    static const std::string OBFUSCATE_KEY_KEY;

    //! the length of the obfuscate key in number of bytes
    static const unsigned int OBFUSCATE_KEY_NUM_BYTES;

    std::vector<unsigned char> CreateObfuscateKey() const;

    //! path to filesystem storage
    const fs::path m_path;

    //! whether or not the database resides in memory
    bool m_is_memory;

    // [ Collection of some db-specific stuff. ] 
    std::optional<std::string> ReadImpl(Span<const std::byte> key) const;
    bool ExistsImpl(Span<const std::byte> key) const;
    size_t EstimateSizeImpl(Span<const std::byte> key1, Span<const std::byte> key2) const;
    auto& DBContext() const LIFETIMEBOUND { return *Assert(m_db_context); }

public:
    CDBWrapper(const DBParams& params);
    ~CDBWrapper();

    // [ Delete copy constructor ]
    CDBWrapper(const CDBWrapper&) = delete;
    CDBWrapper& operator=(const CDBWrapper&) = delete;

    template <typename K, typename V>
    bool Read(const K& key, V& value) const
    {
        // [ DataStream provides a "Double ended buffer combining vector and
        //   stream-like interfaces."
        //
        //   It stores data in 'vch', a vector of bytes with a "zero-after-free"
        //   allocator named "zero_after_free_allocator". ]
        DataStream ssKey{};

        // [ std::vector::reserve preallocates a vector to a given capacity. ]
        ssKey.reserve(DBWRAPPER_PREALLOC_KEY_SIZE);

        // [ Serialize the key argument to the byte stream/vector ssKey. ]
        ssKey << key;

        // [ Pass the 
        std::optional<std::string> strValue{ReadImpl(ssKey)};
        if (!strValue) {
            return false;
        }
        try {
            DataStream ssValue{MakeByteSpan(*strValue)};
            ssValue.Xor(obfuscate_key);
            ssValue >> value;
        } catch (const std::exception&) {
            return false;
        }
        return true;
    }

    template <typename K, typename V>
    bool Write(const K& key, const V& value, bool fSync = false)
    {
        CDBBatch batch(*this);
        batch.Write(key, value);
        return WriteBatch(batch, fSync);
    }

    //! @returns filesystem path to the on-disk data.
    std::optional<fs::path> StoragePath() {
        if (m_is_memory) {
            return {};
        }
        return m_path;
    }

    template <typename K>
    bool Exists(const K& key) const
    {
        DataStream ssKey{};
        ssKey.reserve(DBWRAPPER_PREALLOC_KEY_SIZE);
        ssKey << key;
        return ExistsImpl(ssKey);
    }

    template <typename K>
    bool Erase(const K& key, bool fSync = false)
    {
        CDBBatch batch(*this);
        batch.Erase(key);
        return WriteBatch(batch, fSync);
    }

    bool WriteBatch(CDBBatch& batch, bool fSync = false);

    // Get an estimate of LevelDB memory usage (in bytes).
    size_t DynamicMemoryUsage() const;

    CDBIterator* NewIterator();

    /**
     * Return true if the database managed by this class contains no entries.
     */
    bool IsEmpty();

    template<typename K>
    size_t EstimateSize(const K& key_begin, const K& key_end) const
    {
        DataStream ssKey1{}, ssKey2{};
        ssKey1.reserve(DBWRAPPER_PREALLOC_KEY_SIZE);
        ssKey2.reserve(DBWRAPPER_PREALLOC_KEY_SIZE);
        ssKey1 << key_begin;
        ssKey2 << key_end;
        return EstimateSizeImpl(ssKey1, ssKey2);
    }
};
```


</details>

## `class CDBBatch`

`CDBBatch` is used to represent

## `CCoinsViewDB::BatchWrite`

Called by `CCoinsViewCache::Flush()`. All that `Flush` does is call the backing CCoinsView cache's BatchWrite(), with `bool erase = true`, and ensure that the cache is indeed empty.

<details>

<summary>`CCoinsViewDB::BatchWrite`</summary>

```cpp
bool CCoinsViewDB::BatchWrite(CCoinsMap &nsvmapCoins, const uint256 &hashBlock, bool erase) {
    CDBBatch batch(*m_db);
    size_t count = 0;
    size_t changed = 0;
    assert(!hashBlock.IsNull());

    uint256 old_tip = GetBestBlock();
    if (old_tip.IsNull()) {
        // We may be in the middle of replaying.
        std::vector<uint256> old_heads = GetHeadBlocks();
        if (old_heads.size() == 2) {
            if (old_heads[0] != hashBlock) {
                LogPrintLevel(BCLog::COINDB, BCLog::Level::Error, "The coins database detected an inconsistent state, likely due to a previous crash or shutdown. You will need to restart bitcoind with the -reindex-chainstate or -reindex configuration option.\n");
            }
            assert(old_heads[0] == hashBlock);
            old_tip = old_heads[1];
        }
    }

    // In the first batch, mark the database as being in the middle of a
    // transition from old_tip to hashBlock.
    // A vector is used for future extensibility, as we may want to support
    // interrupting after partial writes from multiple independent reorgs.
    batch.Erase(DB_BEST_BLOCK);
    batch.Write(DB_HEAD_BLOCKS, Vector(hashBlock, old_tip));

    for (CCoinsMap::iterator it = mapCoins.begin(); it != mapCoins.end();) {
        if (it->second.flags & CCoinsCacheEntry::DIRTY) {
            CoinEntry entry(&it->first);
            if (it->second.coin.IsSpent())
                batch.Erase(entry);
            else
                batch.Write(entry, it->second.coin);
            changed++;
        }
        count++;
        it = erase ? mapCoins.erase(it) : std::next(it);
        if (batch.SizeEstimate() > m_options.batch_write_bytes) {
            LogPrint(BCLog::COINDB, "Writing partial batch of %.2f MiB\n", batch.SizeEstimate() * (1.0 / 1048576.0));
            m_db->WriteBatch(batch);
            batch.Clear();
            if (m_options.simulate_crash_ratio) {
                static FastRandomContext rng;
                if (rng.randrange(m_options.simulate_crash_ratio) == 0) {
                    LogPrintf("Simulating a crash. Goodbye.\n");
                    _Exit(0);
                }
            }
        }
    }

    // In the last batch, mark the database as consistent with hashBlock again.
    batch.Erase(DB_HEAD_BLOCKS);
    batch.Write(DB_BEST_BLOCK, hashBlock);

    LogPrint(BCLog::COINDB, "Writing final batch of %.2f MiB\n", batch.SizeEstimate() * (1.0 / 1048576.0));
    bool ret = m_db->WriteBatch(batch);
    LogPrint(BCLog::COINDB, "Committed %u changed transaction outputs (out of %u) to coin database...\n", (unsigned int)changed, (unsigned int)count);
    return ret;
}
```

</details>

