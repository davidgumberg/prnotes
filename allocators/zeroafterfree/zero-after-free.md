This PR modifies `DataStream`'s byte-vector `vch` to use the default allocator `std::allocator` rather than the `zero_after_free_allocator` which degrades performance greatly. The `zero_after_free_allocator` is identical to the default `std::allocator` except that it zeroes memory using `memory_cleanse()` before deallocating.

This PR also drops the `zero_after_free_allocator`, since this was only used by `DataStream` and `SerializeData`. 

In my testing (n=2) on a Raspberry Pi 5 with 4GB of memory, syncing from a fast connection to a stable dedicated node, my branch takes **~74%** of the time taken by master[^1] to sync to height 815,000; average wall clock time was 35h 58m 40s on this branch and 48h 17m 15s on master, see the benchmarking appendix for more detail.

I expect most of the performance improvement to come from the use of `DataStream` for all `CDBWrapper` keys and values, and for all P2P messages. I suspect there are other use cases where performance is improved, but I have only tested IBD.

Any objects that contains secrets should *not* be allocated using `zero_after_free_allocator` since they are liable to get mapped to swap space and written to disk if the user is running low on memory, and I intuit this is a likelier path than scanning unzero'd memory for an attacker to find cryptographic secrets. Secrets should be allocated using `secure_allocator` which cleanses on deallocation and `mlock()`s the memory reserved for secrets to prevent it from being mapped to swap space.

## Are any secrets stored in `DataStream` that will lose security?

I have reviewed every appearance of `DataStream` and `SerializeData` as of [`39219fe`](https://github.com/bitcoin/bitcoin/commit/39219fe145e5e6e6f079b591e3f4b5fea8e718040) and have made notes in the appendix below with notes that provide context for each instance where either is used.

The only use case that I wasn't certain of is PSBT's, I believe these are never secrets, but I am not certain if there are use cases where PSBT's are worthy of being treated as secrets, and being vigilant about not writing them to disk is wise.

As I understand, most of the use of `DataStream` in the wallet code is for the reading and writing of "crypted" key and value data, and they get decrypted somewhere else in a `ScriptPubKeyMan` far away from any `DataStream` container, but I could also be wrong about this, or have misunderstood its use elsewhere in the wallet.

## Zero-after-free as a buffer overflow mitigation

The `zero_after_free` allocator was added as a buffer overflow mitigation, the idea being that `DataStream`'s store a lot of unsecured data that we don't control like the UTXO set and all P2P messages, and an attacker could fill memory in a predictable way to escalate a buffer overflow into an RCE. (See Historical Background in the Appendix).

I agree completely with practicing security in depth, but I don't think this mitigation is worth the performance hit because: 

1. Aren't there still an abundance of other opportunities for an attacker to fill memory that never gets deallocated?
2. Doesn't ASLR mostly mitigate this issue and don't most devices have some form of ASLR?

I'm not a security expert and I had a hard time finding any writing anywhere that discusses this particular mitigation strategy of zeroing memory, so I hope someone with more knowledge of memory vulnerabilities can assist.

----------

#### Other notes

- I opted to leave `SerializeData` as `std::vector<std::byte>` instead of deleting it and refactoring in the spots where it's used in the wallet to keep the PR small, if others think it would be better to delete it I would be happy to do it.
- I have a feeling that it's not just that we're memsetting everything to 0 in `memory_cleanse` that is causing the performance issue, but the trick we do to prevent compilers from optimizing out the `memset` call is also preventing other optimizations on the `DataStream`'s, but I have yet to test this.
-  I also make a small change to a unit test where boost mysteriously fails to find a left shift-operator for `SerializeData` once it loses its custom allocator.

[^1]: Master at the time of my testing was: [`6d546336e800`](https://github.com/bitcoin/bitcoin/commit/6d546336e800)
