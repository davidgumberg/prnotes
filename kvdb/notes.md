What would be desirable in a leveldb alternative?

1. Performance improvements:
    - Faster IBD.
    - Faster block connection.
    - Faster wallet importing
    - Lower storage requirements
    - Less I/O, less storage wear.
2. Reliability improvements:
    - More durable
3. Features:
    - Multiple readers

It seems to me unlikely that any DB is likely to do all of those things better
than leveldb, and whatever improvements in these areas exist are likely to
depend on hardware/use-case.

# Questions for any alternative to leveldb

- Does it support 32-bit platforms?
    - This poses a problem for mmap-based databases (LMDB, libmdbx), since our CoinsDB is(?)
      larger than the 4 GiB address limit.
- Is on-disk serialization consistent between platforms? Between versions? Is it
  documented?
    - this has been mentioned as an issue with lmdb

# Coinsdb properties

Keys are 35 bytes serialized as:
    - 1 byte "key" prefix that indicates the type of the data.
        - key(`DB_COIN`) == 'C'
    - 32-byte txid of the parent transaction
    - 4-byte vout index of the utxo in the parent tx.

Values are serialized as:
    - `VARINT code` at most 5 bytes long
        `code = 
    - `TxOutCompression` serialization:
        - `VarINT` of compressed transaction amount(uint64_t) - 9 bytes worst case
            - `struct AmountCompression` is a bit mysterious to me, but I think
              it tries to save a byte or two on-disk if a certain pattern
              appears in the amount.
        - scriptpubkey serialization:
            - Seems like usually >200 bytes
                - Let's measure it!
            - Worst case:  16507 bytes.


## Rocksdb

From the [FAQ](https://github.com/facebook/rocksdb/wiki/rocksdb-faq) of
rocksdb:

    **Q: Is it safe to close RocksDB while another thread is issuing read, write
    or manual compaction requests?**

    No. The users of RocksDB need to make sure all functions have finished
    before they close RocksDB. You can speed up the waiting by calling
    DisableManualCompaction().
