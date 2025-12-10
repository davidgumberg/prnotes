To set up, I cleaned my build dir and used pyperf.
```bash
rm -rf ./build 
pip install pyperf && sudo pyperf system tune
```

Master + benchmarks
```bash
git checkout 8abee2b
# I also cleaned out my build dir before doing this.
cmake -B build -DBUILD_BENCH=ON && cmake --build build -j $(nproc)
./build/bin/bench_bitcoin --filter="WalletEncrypt.*" -min-time=12000
```

|              ns/key |               key/s |    err% |         ins/key |         cyc/key |    IPC |        bra/key |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|          293,553.20 |            3,406.54 |    0.1% |    6,848,134.51 |    1,258,326.47 |  5.442 |     151,429.70 |    0.9% |     12.91 | `WalletEncryptDescriptors`
|          104,682.68 |            9,552.68 |    0.1% |    2,329,994.28 |      448,813.08 |  5.191 |      74,084.65 |    0.9% |     13.02 | `WalletEncryptDescriptorsBenchOverhead`


-----

Branch
```bash
git checkout e54690a
cmake -B build -DBUILD_BENCH=ON && cmake --build build -j $(nproc)
./build/bin/bench_bitcoin --filter="WalletEncrypt.*" -min-time=12000
```

|              ns/key |               key/s |    err% |         ins/key |         cyc/key |    IPC |        bra/key |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|          294,794.46 |            3,392.19 |    0.3% |    6,855,246.26 |    1,264,321.32 |  5.422 |     153,125.52 |    0.9% |     12.97 | `WalletEncryptDescriptors`
|          104,329.09 |            9,585.05 |    0.1% |    2,330,778.18 |      447,414.99 |  5.209 |      74,203.06 |    0.8% |     12.94 | `WalletEncryptDescriptorsBenchOverhead`

# Cleaned up tables:

git range-diff 68ac9f1..8bdcd12 9890058..e54690a

| branch |  EncryptWallet (total - overhead) | total ns/key | overhead ns/key
|-------:|----------------------------------:|-------------:|:---------------
| master + benchmarks (8abee2b) | 192,652.62 ns | 293,553.20 ns | 104,682.68 ns
| branch (e54690a)                | 192,772.32 ns | 294,794.46 ns | 104,329.09 ns

