Current iteration of the secure allocator was introduced in
[#8573](https://github.com/bitcoin/bitcoin/pull/8573).

Gives access to `mlock'ed memory, which is memory that cannot be paged into swap
(disk), which is desirable for cryptographic secrets that we never want to be on
disk, we also zero out the memory on deallocation.

