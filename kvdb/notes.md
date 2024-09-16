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


