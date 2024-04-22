- Add hostname support to `disconnectnode` which only works with addresses at present.
- `getaddednodeinfo` expose v2 flags of added nodes
- Add CoinGrinder unit tests
- Make the low disk space check in `AppInitMain` calculate
  `additional_bytes_needed` as additional bytes needed instead of total bytes
  needed.
