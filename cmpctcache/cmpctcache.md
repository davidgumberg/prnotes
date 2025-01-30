# Observation:

During assumevalid block validations, we skip CheckingInputScripts and only do
`CheckTxInputs`. This does not require the scriptPubKey of a coin, furthermore,
there around 184 million coutpoints that could be in our dbcache, but we spend
36 bytes uniquely identifying them with a txid and vout index, I hypothesize
that we could use some smaller number of bytes in the cache table, maybe 8byte
shortxid + 4 byte vout, with the risk of a collision and having to fall back to
ddbcache, then disk, we could compactly represent all the data needed for
pre-assumevalid validation that would afford low dbcache machines an effectively
infinite dbcache until the assumevalid checkpoint.

Data needed in `CheckTxInputs`, aside from identifying whether or not the input
is unspent:

```cpp
// editorialized.
using CCoinsMap = std::unordered_map<COutPoint, Coin>;
class COutPoint {
public:
    Txid hash; // uint256_t, 32 bytes
    uint32_t n;
}
class Coin
{
public:
    //! value of the coin in satoshis.
    CAmount nValue; // uint64_t, 8 bytes

    CScript scriptPubKey; // std::vector<unsigned char>, variable size

    //! whether containing transaction was a coinbase
    unsigned int fCoinBase : 1;

    //! at which height this containing transaction was included in the active block chain
    uint32_t nHeight : 31;
}
```

At block height ~881,000: 184 million utxo's / 1024 bytes/KiB / 1024 KiB/MiB = 175.5 MiB per byte we use
to represent the UTXO set.




<details> <summary> Thinking out loud </summary>

We need 97 bits of value data per `Coin`, but we can steal a high-order bit from either
nValue or nHeight, 2^63-1 / 100,000,000 > 21,000,000 and 2^31-1 blocks will buy us until
~42,000 AD to fix this, so 96 bits | 12 bytes.

My first idea was to use 8 bytes as a shorttxid and keep the vout index at 4
bytes.

q: formula for estimating the number of collisions in a birthday problem with
large numbers?

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

</details>

What about 1bit that indicates whether or not tx can be compactly represented
fcoinbase collision or otherwise, 7 bits for the vout index (q: how many txo's
have vout > 127?), 48 bits for shorttxid, 40 bits for camount?)

```cpp
// 1 bit indicating if we can compactly represent this utxo
// !(fCoinBase || nValue > 2^40-1 || vout index > 2^7-1)
// maybe this will also represent whether or not we've had a collision?
bool is_compact_cacheable : 1;

// TODO: data on vout counts of all historical txo's.
// 7 bits vout index, up to 127 vout's
uint8_t n : 7;

// 48-bit shorttxid that is collision tolerant, in the event of a collision,
// fall back to backing cache / disk
uint8_t shorttxid[6];

// TODO: data on camount vals of all historical txo's.
// 40 bit nValue, can represent outputs up to 11k btc
uint8_t nValue[5];
```

96 bits ~ 12 bytes, 2.1 GiB getting closer, but a lot of complexity, and this
will probably be a hash map? how big are the hashes? Is it possible to not store
the shorttxid's in this data structure and just use a 64-bit hash of txid and
outpoint, mark collisions as invalid?

alternative approach: make ccoinsviewcache more compact?

doesn't work because ccoinsviewcache is really a write buffer, it can't lose any
fat, so no shorttxid's, etc.
