# Questions for any alternative to leveldb

- Does it support 32-bit platforms?
    - This poses a problem for mmap-based databases (LMDB, libmdbx), since our CoinsDB is(?)
      larger than the 4 GiB address limit.
- Is on-disk serialization consistent between platforms? Between versions? Is it
  documented?
    - this has been mentioned as an issue with lmdb
