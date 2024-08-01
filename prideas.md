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
