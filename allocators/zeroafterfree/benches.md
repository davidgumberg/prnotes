Command being timed:
```bash
./src/bitcoind -daemon=0 -connect=amd-ryzen-7900x-node:8333 -stopatheight=815000 -port=8444 -rpcport=8445 -dbcache=2048 -prune=550 -debug=bench -debug=blockstorage -debug=coindb -debug=mempool -debug=prune"
```

I applied my branch on
[6d546336e800](https://github.com/bitcoin/bitcoin/commit/6d546336e800), which is
"master" in the data below.

Average master time (hh:mm:ss): 48:17:15 (173835s)
Average branch time (hh:mm:ss): 35:58:40 (129520s)

~25% reduction in IBD time on a raspberry Pi 5 with a DB cache of 2GB.

# Master run 1
Wall clock time (hh:mm:ss): 49:38:31 (178711s)

Bitcoin Core version v27.99.0-6d546336e800 (release build)
- Connect block: 158290.53s (620.94ms/blk)
    - Sanity checks: 10.89s (0.01ms/blk)
    - Fork checks: 151.82s (0.02ms/blk)
    - Verify 7077 txins: 135057.68s (165.71ms/blk)
      - Connect 1760 transactions: 134786.36s (165.38ms/blk)
    - Write undo data: 2681.34s (7.38ms/blk)
    - Index writing: 52.76s (0.03ms/blk)
  - Connect total: 138100.75s (611.27ms/blk)
  - Flush: 3933.29s (8.97ms/blk)
  - Writing chainstate: 15814.36s (0.14ms/blk)
  - Connect postprocess: 273.39s (0.52ms/blk)

# Master run 2
Wall clock time (hh:mm:ss): 46:55:58 (168958s)

Bitcoin Core version v27.99.0-6d546336e800 (release build)
- Connect block: 145449.95s (940.78ms/blk)
    - Sanity checks: 10.69s (0.01ms/blk)
    - Fork checks: 155.81s (0.02ms/blk)
    - Verify 7077 txins: 115935.55s (142.25ms/blk)
      - Connect 1760 transactions: 115481.15s (141.69ms/blk)
    - Write undo data: 2561.36s (9.05ms/blk)
    - Index writing: 73.63s (0.04ms/blk)
  - Connect total: 118877.56s (929.93ms/blk)
  - Flush: 3864.34s (10.11ms/blk)
  - Writing chainstate: 22294.82s (0.14ms/blk)
  - Connect postprocess: 267.68s (0.56ms/blk)

# Branch run 1
Wall clock time (hh:mm:ss): 34:28:56 (124136s)

Bitcoin Core version v27.99.0-a0dddf8b4092 (release build)
- Connect block: 107134.59s (1017.01ms/blk)
    - Sanity checks: 11.01s (0.01ms/blk)
    - Fork checks: 150.93s (0.03ms/blk)
    - Verify 7077 txins: 87446.53s (107.30ms/blk)
      - Connect 1760 transactions: 87329.99s (107.15ms/blk)
    - Write undo data: 2495.47s (7.36ms/blk)
    - Index writing: 37.95s (0.04ms/blk)
  - Connect total: 90318.60s (1006.42ms/blk)
  - Flush: 3917.28s (9.92ms/blk)
  - Writing chainstate: 12560.43s (0.15ms/blk)
  - Connect postprocess: 259.89s (0.47ms/blk)

# Branch run 2
Wall clock time (hh:mm:ss): 37:28:24 (134904s)

Bitcoin Core version v27.99.0-a0dddf8b4092 (release build)
- Connect block: 117991.55s (144.77ms/blk)
  - Connect total: 101298.20s (124.29ms/blk)
    - Sanity checks: 11.17s (0.01ms/blk)
    - Fork checks: 151.24s (0.19ms/blk)
    - Verify 7077 txins: 98446.38s (120.79ms/blk)
      - Connect 1760 transactions: 98339.79s (120.66ms/blk)
    - Write undo data: 2484.75s (3.05ms/blk)
    - Index writing: 36.62s (0.04ms/blk)
  - Flush: 3892.28s (4.78ms/blk)
  - Writing chainstate: 12446.33s (15.27ms/blk)
  - Connect postprocess: 259.11s (0.32ms/blk)
