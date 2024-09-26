# Zero after free allocator

## Historical background

At some point prior to the oldest git commit for the repo, an allocator
`secure_allocator` was
[added](https://github.com/bitcoin/bitcoin/blob/0a61b0df1224a5470bcddab302bc199ca5a9e356/serialize.h#L675-L702)
that zeroes out memory on deallocation with `memset()`, and was
[used](https://github.com/bitcoin/bitcoin/blob/0a61b0df1224a5470bcddab302bc199ca5a9e356/serialize.h#L711-L714)
as the allocator for the vector `vch` in `CDataStream` (now `DataStream`).

In July 2011, PR [#352](https://github.com/bitcoin/bitcoin/pull/352) adding
support for encrypted wallets `secure_allocator` was
[modified](https://github.com/bitcoin/bitcoin/pull/352/commits/c1aacf0be347b10a6ab9bbce841e8127412bce41)
to also `mlock()` data on allocation to prevent the wallet passphrase or other
secrets from being paged to swap space (written to disk).

In January 2012, findings were shared
(https://bitcointalk.org/index.php?topic=56491.0) that
[#352](https://github.com/bitcoin/bitcoin/pull/352) modifying `CDataStream`'s
allocator slowed down IBD substantially[^1], since `CDataStream` was used in
many places that did not need the guarantees of `mlock()`, and since every call
to `mlock()` results in a flush of the TLB (a cache that maps virtual memory to
physical memory).

PR [#740](https://github.com/bitcoin/bitcoin/pull/740) was opened to fix
this, initially[^2] by removing the custom allocator `secure_allocator` from
`CDataStream`'s `vector_type`:

```diff
 class CDataStream
 {
 protected:
-    typedef std::vector<char, secure_allocator<char> > vector_type;
+    typedef std::vector<char> vector_type;
     vector_type vch;
```

A reviewer of [#740](https://github.com/bitcoin/bitcoin/pull/740)
[suggested](https://github.com/bitcoin/bitcoin/pull/740#issuecomment-3356239)
that dropping `mlock()` was a good idea, but that the original behavior of
zeroing-after-freeing (should it be zeroing-*before*-freeing?) `CDataStream`
should be restored as a mitigation for buffer overflows:

> I love the performance improvement, but I still don't like the elimination of zero-after-free. Security in depth is important.
>
> Here's the danger:
>
> Attacker finds a remotely-exploitable buffer overrun somewhere in the networking code that crashes the process.
> They turn the crash into a full remote exploit by sending carefully constructed packets before the crash packet, to initialize used-but-then-freed memory to a known state.
>
> Unlikely? Sure.
>
> Is it ugly to define a zero_after_free_allocator for CDataStream? Sure. (simplest implementation: copy secure_allocator, remove the mlock/munlock calls).
>
> But given that CDataStream is the primary interface between bitcoin and the network, I think being extra paranoid here is a very good idea.

Another reviewer benchmarked `CDataStream` with an allocator that zeroed
memory using `memset` without `mlock`ing it and found that performance was almost identical to
the default allocator, while both were substantially faster than the `mlock`ing
variant of `CDataStream`.
(https://web.archive.org/web/20130622160044/https://people.xiph.org/~greg/bitcoin-sync.png).

Based on the benchmark, and the potential security benefit, the
`zero_after_free` allocator was created and used as `CDataStream`'s
allocator.

In November 2012, PR [#1992](https://github.com/bitcoin/bitcoin/pull/1992) was
opened to address the fact that in many cases `memset()` calls are optimized
away by compilers as part of a family of compiler optimizations called
[dead store elimination](https://www.usenix.org/conference/usenixsecurity17/technical-sessions/presentation/yang)
by replacing the `memset` call with openssl's `OPENSSL_cleanse` which is meant
to solve this problem. Given that all of the data being zero'ed out in the
deallocator is also having it's only pointer destroyed, these memset calls were
candidates for being optimized.

I suspect that the reason no performance regression was found in the
benchmarking of [#740](https://github.com/bitcoin/bitcoin/pull/740) which
introduced the `zero_after_free` allocator is that the `memset` calls were being
optimized out.

I am not the first to suggest that this is a performance issue:

https://bitcoin-irc.chaincode.com/bitcoin-core-dev/2015-11-06#1446837840-1446854100;

https://bitcoin-irc.chaincode.com/bitcoin-core-dev/2016-11-23#1479883620-1479882900;

Or to write a patch changing it:

https://github.com/bitcoin/bitcoin/commit/671c724716abdd69b9d253a01f8fec67a37ab7d7

## 

[^1]: Maybe as much as 50x: https://github.com/bitcoin/bitcoin/pull/740#issuecomment-3337245
[^2]: I am assuming this from the discussion, github seems to not have dead
      commits for old pr's
