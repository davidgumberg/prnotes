##Raspberry Pi 5 4GB

Original zero-after-free allocator still in use with DataStream

```console
~/bitcoin $ git checkout --detach $yeszero && cmake -B build -DBUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release &>/dev/null && cmake --build build -j $(nproc) &>/dev/null && ./build/src/bench/bench_bitcoin -filter="(DataStream.*|CCoinsViewDB.*|ProcessMessage.*|Deserial.*)" -min-time=60000
HEAD is now at 772b1f606f test: avoid BOOST_CHECK_EQUAL for complex types
```


|             ns/byte |              byte/s |    err% |        ins/byte |        cyc/byte |    IPC |       bra/byte |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|               20.67 |       48,369,994.69 |    0.6% |           61.83 |           47.04 |  1.314 |           8.87 |    0.8% |     68.71 | `CCoinsViewDBFlush`
|                0.86 |    1,165,414,983.28 |    0.0% |            5.14 |            2.06 |  2.498 |           1.04 |    0.0% |     66.01 | `DataStreamAlloc`
|                0.18 |    5,416,728,210.85 |    0.1% |            1.26 |            0.44 |  2.839 |           0.25 |    0.0% |     66.00 | `DataStreamSerializeScript`
|                9.06 |      110,322,628.58 |    0.1% |           32.40 |           21.69 |  1.493 |           6.06 |    0.7% |     66.09 | `ProcessMessageBlock`

|            ns/block |             block/s |    err% |       ins/block |       cyc/block |    IPC |      bra/block |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|        4,319,764.64 |              231.49 |    0.2% |   21,518,823.54 |   10,347,746.41 |  2.080 |   3,965,023.40 |    1.1% |     64.06 | `DeserializeAndCheckBlockTest`
|        2,983,304.65 |              335.20 |    0.1% |   14,726,319.41 |    7,146,940.53 |  2.061 |   2,622,747.10 |    0.7% |     66.04 | `DeserializeBlockTest`

Modified zero-after-free allocator that prevents memory optimization but doesn't
zero memory.

```console
~/bitcoin $ git checkout --detach $partzero && cmake -B build -DBUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release &>/dev/null && cmake --build build -j $(nproc) &>/dev/null && ./build/src/bench/bench_bitcoin -filter="(DataStream.*|CCoinsViewDB.*|ProcessMessage.*|Deserial.*)" -min-time=60000
HEAD is now at 0351c4242a Modify zero after free allocator to prevent optimizations without zeroing memory
```

|             ns/byte |              byte/s |    err% |        ins/byte |        cyc/byte |    IPC |       bra/byte |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|               20.64 |       48,461,301.71 |    0.5% |           61.84 |           46.60 |  1.327 |           8.87 |    0.8% |     68.28 | `CCoinsViewDBFlush`
|                0.84 |    1,183,775,230.65 |    0.0% |            5.08 |            2.03 |  2.505 |           1.02 |    0.0% |     66.02 | `DataStreamAlloc`
|                0.14 |    6,951,563,016.33 |    0.0% |            1.13 |            0.35 |  3.273 |           0.21 |    0.0% |     66.00 | `DataStreamSerializeScript`
|                9.45 |      105,798,798.06 |    0.3% |           46.75 |           22.67 |  2.062 |           8.46 |    0.5% |     66.14 | `ProcessMessageBlock`

|            ns/block |             block/s |    err% |       ins/block |       cyc/block |    IPC |      bra/block |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|        4,172,021.00 |              239.69 |    0.1% |   21,543,066.84 |    9,993,817.02 |  2.156 |   3,988,350.18 |    1.0% |     63.92 | `DeserializeAndCheckBlockTest`
|        2,919,977.25 |              342.47 |    0.0% |   14,750,310.48 |    6,994,754.12 |  2.109 |   2,646,087.06 |    0.5% |     66.07 | `DeserializeBlockTest`

My PR branch with no zero-after-free allocator:

~/bitcoin $ git checkout --detach $nozero && cmake -B build -DBUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release &>/dev/null && cmake --build build -j $(nproc) &>/dev/null && ./build/src/bench/bench_bitcoin -filter="(DataStream.*|CCoinsViewDB.*|ProcessMessage.*|Deserial.*)" -min-time=60000
HEAD is now at 906e67b951 refactor: Drop unused `zero_after_free_allocator`

|             ns/byte |              byte/s |    err% |        ins/byte |        cyc/byte |    IPC |       bra/byte |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|               20.89 |       47,868,766.30 |    0.7% |           60.74 |           47.24 |  1.286 |           9.12 |    0.9% |     69.52 | `CCoinsViewDBFlush`
|                0.04 |   27,639,502,423.73 |    0.0% |            0.20 |            0.09 |  2.312 |           0.04 |    0.0% |     66.02 | `DataStreamAlloc`
|                0.14 |    7,030,720,015.31 |    0.0% |            1.09 |            0.34 |  3.203 |           0.22 |    0.0% |     66.03 | `DataStreamSerializeScript`
|                8.46 |      118,171,923.30 |    0.1% |           29.40 |           20.25 |  1.452 |           5.06 |    0.8% |     66.06 | `ProcessMessageBlock`

|            ns/block |             block/s |    err% |       ins/block |       cyc/block |    IPC |      bra/block |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|        4,111,234.73 |              243.24 |    0.1% |   21,519,664.21 |    9,847,208.26 |  2.185 |   3,965,210.98 |    1.0% |     63.80 | `DeserializeAndCheckBlockTest`
|        2,857,220.97 |              349.99 |    0.1% |   14,727,090.03 |    6,843,201.05 |  2.152 |   2,622,831.00 |    0.5% |     65.95 | `DeserializeBlockTest`

--------------------


## Ryzen 7900x 5200 MT/s DDR5

Original zero-after-free allocator still in use with DataStream

```console
~/bitcoin$ git checkout --detach $yeszero && cmake -B build -DBUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release &>/dev/null && cmake --build build -j $(nproc) &>/dev/null && ./build/src/bench/bench_bitcoin -filter="(DataStream.*|CCoinsViewDB.*|ProcessMessage.*|Deserial.*)" -min-time=60000
HEAD is now at 772b1f606f test: avoid BOOST_CHECK_EQUAL for complex types
```

|             ns/byte |              byte/s |    err% |        ins/byte |        cyc/byte |    IPC |       bra/byte |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|                6.14 |      162,782,032.39 |    0.7% |           56.96 |           27.77 |  2.051 |           8.25 |    0.7% |     61.54 | `CCoinsViewDBFlush`
|                0.19 |    5,280,744,677.81 |    0.1% |            5.10 |            0.89 |  5.755 |           1.02 |    0.0% |     65.93 | `DataStreamAlloc`
|                0.22 |    4,577,202,378.38 |    0.5% |            5.70 |            1.02 |  5.579 |           1.16 |    0.1% |     66.27 | `DataStreamSerializeScript`
|                2.37 |      422,778,468.05 |    0.2% |           32.39 |           11.06 |  2.929 |           5.12 |    0.6% |     66.04 | `ProcessMessageBlock`

|            ns/block |             block/s |    err% |       ins/block |       cyc/block |    IPC |      bra/block |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|        1,319,284.06 |              757.99 |    0.4% |   20,617,084.61 |    6,164,538.66 |  3.344 |   3,706,003.42 |    0.7% |     65.82 | `DeserializeAndCheckBlockTest`
|          879,982.73 |            1,136.39 |    0.4% |   14,213,986.82 |    4,113,201.90 |  3.456 |   2,432,431.24 |    0.2% |     65.87 | `DeserializeBlockTest`

Modified zero-after-free allocator that prevents memory optimization but doesn't
zero memory.

```console
~/btc/bitcoin$ git checkout --detach $partzero && cmake -B build -DBUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release &>/dev/null && cmake --build build -j $(nproc) &>/dev/null && ./build/src/bench/bench_bitcoin -filter="(DataStream.*|CCoinsViewDB.*|ProcessMessage.*|Deserial.*)" -min-time=60000
HEAD is now at 3bdd43680e Modify zero after free allocator to prevent optimizations without zeroing memory
```

|             ns/byte |              byte/s |    err% |        ins/byte |        cyc/byte |    IPC |       bra/byte |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|                6.24 |      160,226,428.51 |    0.5% |           56.96 |           27.99 |  2.035 |           8.25 |    0.7% |     62.34 | `CCoinsViewDBFlush`
|                0.18 |    5,415,824,062.30 |    0.1% |            5.07 |            0.86 |  5.869 |           1.02 |    0.0% |     65.99 | `DataStreamAlloc`
|                0.21 |    4,715,585,681.78 |    0.1% |            5.62 |            0.99 |  5.664 |           1.14 |    0.1% |     65.93 | `DataStreamSerializeScript`
|                2.36 |      424,307,427.06 |    0.1% |           32.36 |           11.02 |  2.938 |           5.12 |    0.6% |     66.07 | `ProcessMessageBlock`

|            ns/block |             block/s |    err% |       ins/block |       cyc/block |    IPC |      bra/block |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|        1,304,195.07 |              766.76 |    0.1% |   20,615,353.83 |    6,096,229.68 |  3.382 |   3,705,797.43 |    0.7% |     66.01 | `DeserializeAndCheckBlockTest`
|          876,218.51 |            1,141.27 |    0.0% |   14,212,309.42 |    4,095,993.88 |  3.470 |   2,431,660.20 |    0.2% |     65.98 | `DeserializeBlockTest`

My PR branch with no zero-after-free allocator:

```console
~/btc/bitcoin$ git checkout --detach $nozero && cmake -B build -DBUILD_BENCH=ON -DCMAKE_BUILD_TYPE=Release &>/dev/null && cmake --build build -j $(nproc) &>/dev/null && ./build/src/bench/bench_bitcoin -filter="(DataStream.*|CCoinsViewDB.*|ProcessMessage.*|Deserial.*)" -min-time=60000
HEAD is now at 906e67b951 refactor: Drop unused `zero_after_free_allocator`
```

|             ns/byte |              byte/s |    err% |        ins/byte |        cyc/byte |    IPC |       bra/byte |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|                6.24 |      160,367,026.40 |    0.8% |           57.70 |           28.03 |  2.059 |           8.46 |    0.7% |     62.47 | `CCoinsViewDBFlush`
|                0.01 |  113,328,653,394.82 |    0.0% |            0.12 |            0.04 |  2.854 |           0.02 |    0.0% |     65.69 | `DataStreamAlloc`
|                0.04 |   23,329,286,239.78 |    0.0% |            0.89 |            0.20 |  4.454 |           0.19 |    0.0% |     64.00 | `DataStreamSerializeScript`
|                2.26 |      441,734,425.78 |    0.1% |           29.88 |           10.58 |  2.825 |           4.62 |    0.6% |     65.89 | `ProcessMessageBlock`

|            ns/block |             block/s |    err% |       ins/block |       cyc/block |    IPC |      bra/block |   miss% |     total | benchmark
|--------------------:|--------------------:|--------:|----------------:|----------------:|-------:|---------------:|--------:|----------:|:----------
|        1,302,825.68 |              767.56 |    0.2% |   20,617,190.29 |    6,090,178.32 |  3.385 |   3,706,032.36 |    0.7% |     65.93 | `DeserializeAndCheckBlockTest`
|          874,097.45 |            1,144.04 |    0.1% |   14,212,631.31 |    4,085,149.78 |  3.479 |   2,431,804.86 |    0.2% |     66.24 | `DeserializeBlockTest`

