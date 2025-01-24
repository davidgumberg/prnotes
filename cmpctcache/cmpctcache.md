# Observation:

During assumevalid block validations, we skip CheckingInputScripts and only do
`CheckTxInputs`. This does not require the scriptPubKey of a coin, furthermore,
there around 184 million coutpoints that could be in our dbcache, but we spend
36 bytes uniquely identifying them with a txid and vout index, I hypothesize
that we could use some smaller number of bytes in the cache table, maybe 8byte
shortxid + 4 byte vout, with the risk of a collision and having to fall back to
dbcache, then disk, we could compactly represent all the data needed for
pre-assumevalid validation that would afford low dbcache machines an effectively
infinite dbcache until the assumevalid checkpoint.

Data needed in `CheckTxInputs`, aside from identifying whether or not the input
is unspent:

```
    //! value of the coin in satoshis.
    uint64_t nValue;
    //! whether containing transaction was a coinbase
    uint1_t fCoinBase : 1;
    //! at which height the containing transaction was included in the active block chain
    uint32_t nHeight : 31;
```

We need 97 bits of value data per coin, but we can steal a high-order bit from either
nValue or nHeight, 2^63-1 / 100,000,000 > 21,000,000 and 2^31-1 blocks will buy us until
~42,000 AD to fix this, so 96 bits | 12 bytes.

If we use 12 bytes to ~uniquely identify transactions+vouts, we have 8 bytes of
entropy and collision odds of any 2 colliding is .001, if we try to insert a
shorttxid collision flag the entry as invalid. Maybe this is too
aggressive, q: formula for estimating the number of collisions in a birthday
problem with large numbers?

184 million utxo's / 1024 bytes/KiB / 1024 KiB/MiB = 175.5 MiB per byte we use
to represent the UTXO set.

so if we need 12 bytes to ~uniquely identify inputs, and 12 bytes of value data
for each input, it will take 4.2 GiB to represent the Utxo set, not quite good
enough to be worth it :(

OK, but we only need nHeight for coinbase transactions, we can shove fCoinBase
into nvalue and fall back on the full coins view cache for coinbases, ~3.5 GiB,
still no good!

But we can eat a little more into nValue, specifically we can use 13 bits since
2^51-1 is greater than 21,000,000*100,000,000, so if one of those bits is
fCoinBase, and 3 bytes for the vout, we're at 8+8 bytes -> 2.8 GiB, still not
good enough.

What about 1bit that indicates whether or not tx can be compactly represented
fcoinbase collosion or otherwise, 7 bits for the vout index (q: how many txo's
have vout > 127?), 48 bits for shorttxid, 40 bits for camount?

1 bit valid compact flag
7 bits vout index
48 bits shortxid
40 bits for camount

96 bits ~ 12 bytes, 2.1 GiB getting closer, but a lot of complexity, and this
will probably be a hash map? how big are the hashes? Is it possible to not store
the shorttxid's in this data structure and just use a 64-bit hash of txid and
outpoint, mark collisions as invalid?

alternative approach: compact ccoinsviewcache?

doesn't work because ccoinsviewcache is really a write buffer, it can't lose any
fat, so no shorttxid's, etc.
