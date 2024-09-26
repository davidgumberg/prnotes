- Add hostname support to `disconnectnode` which only works with addresses at present.
- `getaddednodeinfo` expose v2 flags of added nodes
- Add CoinGrinder functional tests
- Make the low disk space check in `AppInitMain` calculate
  `additional_bytes_needed` as additional bytes needed instead of total bytes
  needed.
- More consistently respect `-logips`/`fLogIPs`.
- retry dns seed loading 
    - reproduce this issue by starting up a fresh node with no internet and then
      switch it on.
- Sometimes headers pre-synchronization is really slow
    - My assumption is we may get unlucky with the speed of the peer we choose
      for doing this?
- [Add](https://github.com/bitcoin/bitcoin/pull/28280/commits/8737c0cefa6ec49a4d17d9bef9e5e1a7990af1ac#r1703187118)
  a move constructor for `Coin`.
  - Another contributor has an open PR for this:
    [bitcoin/bitcoin#30643](https://github.com/bitcoin/bitcoin/pull/30643)
- Avoid an unnecessary copy with struct CoinsEntry
- Use secure allocator instead of memcleanse for cleaning up fallback windows
  seed generation (randomenv.cpp):
  https://bitcoin-irc.chaincode.com/bitcoin-core-dev/2021-10-15#723906
