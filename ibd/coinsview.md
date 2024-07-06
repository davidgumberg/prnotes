# `CCoinsView`
_All code comments in `[]` are my own._

First, an incomplete picture:
<pre>
                                  CCoinsView        
                                     |              
                                     |              
                                     |              
                       +-------------+-------+      
                       |                     |      
                       v                     v      
                CCoinsViewBacked        CCoinsViewDB
                      |                 ------------
                      |                             
                      |                             
        +-------------+------+                      
        |                    |                      
        v                    v                      
CCoinsViewMempool      CCoinsViewCache
</pre>

## Background

`CCoinsView` and `CCoinsViewBacked` are base classes that are meant to be
overriden by descendants.

### `COutPoint` & `Coin`

A `COutPoint` consists of a txid `hash` and `vout` index. (`uint32_t`). 

A `Coin` is used to represent an unspent transaction output (utxo), its attributes are:
- `CTxOut out` which holds the `scriptPubKey` and `nValue` of a transaction
  output (txout).
- `unsigned int fCoinBase`: a boolean that represents whether or not
  the output's transaction was a coinbase.
- `uint32_t nHeight`: the height of the block this utxo was included in

When a `Coin` is spent, Coin::Clear() is called, which sets `fCoinbase = true`,
`nHeight = 0` and calls `out.SetNull()`. 

`CTxOut::SetNull` sets `nValue = -1` and clears the scriptPubKey.
Coin::IsSpent() just returns the result of `CTxOut::IsNull()`. (true if `nvalue
== -1`)

<details>

<summary>Source for `class Coin` from `src/coins.h`</summary>

```cpp
class Coin
{
public
    // [ a CTxOut represents a transaction output, it holds the `scriptPubKey` and
    //   and nValue of a txout. ]
    //! unspent transaction output
    CTxOut out;
    
    // [ Question: Why these initial values of fCoinBase and nHeight? ]
    // [ A bit unclear... added in 41aa5b79a3d "Pack coin more tightly" from 
    //   #10195 https://github.com/bitcoin/bitcoin/pull/10195 ]

    //! whether containing transaction was a coinbase
    unsigned int fCoinBase : 1;

    //! at which height this containing transaction was included in the active block chain
    uint32_t nHeight : 31;

    //! construct a Coin from a CTxOut and height/coinbase information.
    Coin(CTxOut&& outIn, int nHeightIn, bool fCoinBaseIn) : out(std::move(outIn)), fCoinBase(fCoinBaseIn), nHeight(nHeightIn) {}
    Coin(const CTxOut& outIn, int nHeightIn, bool fCoinBaseIn) : out(outIn), fCoinBase(fCoinBaseIn),nHeight(nHeightIn) {}

    void Clear() {
        // CTxOut::SetNull() makes the nValue = -1, and calls scriptPubKey.clear();
        out.SetNull();
        fCoinBase = false;
        nHeight = 0;
    }

    //! empty constructor
    Coin() : fCoinBase(false), nHeight(0) { }

    bool IsCoinBase() const {
        return fCoinBase;
    }

    template<typename Stream>
    void Serialize(Stream &s) const {
        assert(!IsSpent());
        uint32_t code = nHeight * uint32_t{2} + fCoinBase;
        ::Serialize(s, VARINT(code));
        ::Serialize(s, Using<TxOutCompression>(out));
    }

    template<typename Stream>
    void Unserialize(Stream &s) {
        uint32_t code = 0;
        ::Unserialize(s, VARINT(code));
        nHeight = code >> 1;
        fCoinBase = code & 1;
        ::Unserialize(s, Using<TxOutCompression>(out));
    }

    /** Either this coin never existed (see e.g. coinEmpty in coins.cpp), or it
      * did exist and has been spent.
      */
    bool IsSpent() const {
        return out.IsNull();
    }

    size_t DynamicMemoryUsage() const {
        return memusage::DynamicUsage(out.scriptPubKey);
    }
};
```

</details>

### `class CCoinsView`
This class provides an abstraction for working with a txout dataset. It is the 
base class of descendants `CCoinsViewBacked` and `CCoinsViewCache`

In theory, there could be a sequence of `CCoinsViewCache`'s that are backed by either another
`CCoinsViewCache` or an ultimate `CCoinsViewDB final : public CCoinsView` that
is backed by the on-disk 'chainstate' db.

In practice, the class 'CoinsViews' in `src/validation.h` establishes the
hierarchy used to manage the UTXO set. Starting from the bottom, a
CCoinsViewDB `m_dbview` facilitates access to the comprehensive on-disk LevelDB
utxo db. That is wrapped by a `CCoinsViewErrorCatcher`, which gracefully shuts
down when LevelDB errors occur, and at the top we have a CCoinsViewCache that is
our coin cache.

    🙋Question: Why isn't database error handling built in to CCoinsViewDB?

<details>

<summary>Source code for the `CCoinsView` base class</summary>

```cpp
/** Abstract view on the open txout dataset. */
class CCoinsView
{
public:
    // [ COutPoint represents a `Txid hash` and vout index `uint32_t n`. ]
    /** Retrieve the Coin (unspent transaction output) for a given outpoint.
     *  Returns true only when an unspent coin was found, which is returned in coin.
     *  When false is returned, coin's value is unspecified.
     */
    virtual bool GetCoin(const COutPoint &outpoint, Coin &coin) const;

    //! Just check whether a given outpoint is unspent.
    virtual bool HaveCoin(const COutPoint &outpoint) const;

    //! Retrieve the block hash whose state this CCoinsView currently represents
    virtual uint256 GetBestBlock() const;

    //! Retrieve the range of blocks that may have been only partially written.
    //! If the database is in a consistent state, the result is the empty vector.
    //! Otherwise, a two-element vector is returned consisting of the new and
    //! the old block hash, in that order.
    virtual std::vector<uint256> GetHeadBlocks() const;

    //! Do a bulk modification (multiple Coin changes + BestBlock change).
    //! The passed pairs are a linked list that can be modified.
    //! If will_erase is true, the coins will be erased by the caller afterwards,
    //! so the coins can be moved out of the pairs instead of copied
    virtual bool BatchWrite(CoinsCachePair *pairs, const uint256 &hashBlock, bool will_erase = true);

    //! Get a cursor to iterate over the whole state
    virtual std::unique_ptr<CCoinsViewCursor> Cursor() const;

    //! As we use CCoinsViews polymorphically, have a virtual destructor
    virtual ~CCoinsView() {}

    //! Estimate database size (0 if not implemented)
    virtual size_t EstimateSize() const { return 0; }
};
```

</details>

### `class CCoinsViewBacked : public CCoinsView`

`CCoinsViewBacked` extends `CCoinView` with a protected attribute `CCoinsView
*base;` and a public setter method `void SetBackend(CCoinsView &viewIn)` to set
`base`. All of the virtual methods from `CCoinsView` are redeclared with the
`override` specifier and overriden to delegate to the backing CoinsView `base`'s
methods:

```cpp
CCoinsViewBacked::CCoinsViewBacked(CCoinsView *viewIn) : base(viewIn) { }
bool CCoinsViewBacked::GetCoin(const COutPoint &outpoint, Coin &coin) const { return base->GetCoin(outpoint, coin); }
bool CCoinsViewBacked::HaveCoin(const COutPoint &outpoint) const { return base->HaveCoin(outpoint); }
uint256 CCoinsViewBacked::GetBestBlock() const { return base->GetBestBlock(); }
std::vector<uint256> CCoinsViewBacked::GetHeadBlocks() const { return base->GetHeadBlocks(); }
void CCoinsViewBacked::SetBackend(CCoinsView &viewIn) { base = &viewIn; }
bool CCoinsViewBacked::BatchWrite(CCoinsMap &mapCoins, const uint256 &hashBlock, bool erase) { return base->BatchWrite(mapCoins, hashBlock, erase); }
std::unique_ptr<CCoinsViewCursor> CCoinsViewBacked::Cursor() const { return base->Cursor(); }
size_t CCoinsViewBacked::EstimateSize() const { return base->EstimateSize(); }
```

### `class CCoinsViewCache : public CCoinsViewBacked`

This class extends `CCoinsViewBacked` with the attribute `CCoinsMap cacheCoins`, which
is an unordered map from `COutPoint`'s to `CCoinsCacheEntry`'s.

<details> 

<summary>`CCoinsMap` Source</summary>

```cpp
/* [

    template<
        class Key,
        class T,
        class Hash = std::hash<Key>,
        class KeyEqual = std::equal_to<Key>,
        class Allocator = std::allocator<std::pair<const Key, T>>
    > class unordered_map;
] */

using CCoinsMap = std::unordered_map<COutPoint, // [ Key ]
                                     CCoinsCacheEntry, // [ Value ]
                                     SaltedOutpointHasher, // [ Uses SipHashUint256Extra ]
                                     std::equal_to<COutPoint>, // [ default ] 
                                     PoolAllocator<std::pair<const COutPoint, CCoinsCacheEntry>, // [ Use pool allocator, see src/support/allocators/pool.h ]
                                                   sizeof(std::pair<const COutPoint, CCoinsCacheEntry>) + sizeof(void*) * 4>>;
```

</details>

#### CCoinsCacheEntry

`CCoinsCacheEntry` is used for tracking the status of a coin "in one level of the
coins database caching hierarchy." Namely, whether or not that coin is spent or
unspent, `DIRTY` or `!DIRTY`, `FRESH` or `!FRESH`.

As described in the comments in `src/coins.h`:

`DIRTY`ness indicates that this cache entry is "potentially different from the
version in the parent (backing) cache", a `DIRTY` entry gets written on the next cache
flush.

`FRESH`ness indicates *either* "the parent cache does not have this coin" *or*
"it is a spent coin in the parent cache." `FRESH` coins can be spent without
being deleted from the parent cache on the next flush since the parent either 1)
does not know about the coin or 2) knows about the coin and knows that it is
spent.

`coins.h` provides the following summary of the valid (5 out of 8)
possible states of these three indicators on a cache entry:

     Out of these 2^3 = 8 states, only some combinations are valid:
     - unspent, FRESH, DIRTY (e.g. a new coin created in the cache)
     - unspent, not FRESH, DIRTY (e.g. a coin changed in the cache during a reorg)
     - unspent, not FRESH, not DIRTY (e.g. an unspent coin fetched from the parent cache)
     - spent, FRESH, not DIRTY (e.g. a spent coin fetched from the parent cache)
     - spent, not FRESH, DIRTY (e.g. a coin is spent and spentness needs to be flushed to the parent)

Worth noting are the three invalid states:

- spent, not FRESH, not DIRTY - If a coin is not DIRTY, then our version does
  not differ from the parent cache, but if the parent cache sees a coin as spent
  then the coin is FRESH.
- unspent, FRESH, not DIRTY - If a coin is FRESH then the parent cache either
  does not know of it, or believes it to be spent. But since we know of it, AND
  believe it to be unspent, our version differs from the parent cache, so it
  shoult be DIRTY.
- spent, FRESH, DIRTY - I am less sure of this case. If the coin is FRESH then
  either our parent does not have it, or knows it as spent, and that seems fine.
  But why couldn't the coin be spent, our parent knows about it as spent, and
  DIRTY since something other than its spentness has changed?

<details>

<summary>Source for `class CCoinsCacheEntry` from `src/coins.h`</summary>

```cpp
/**
 * A Coin in one level of the coins database caching hierarchy.
 *
 * A coin can either be:
 * - unspent or spent (in which case the Coin object will be nulled out - see Coin.Clear())
 * - DIRTY or not DIRTY
 * - FRESH or not FRESH
 *
 * Out of these 2^3 = 8 states, only some combinations are valid:
 * - unspent, FRESH, DIRTY (e.g. a new coin created in the cache)
 * - unspent, not FRESH, DIRTY (e.g. a coin changed in the cache during a reorg)
 * - unspent, not FRESH, not DIRTY (e.g. an unspent coin fetched from the parent cache)
 * - spent, FRESH, not DIRTY (e.g. a spent coin fetched from the parent cache)
 * - spent, not FRESH, DIRTY (e.g. a coin is spent and spentness needs to be flushed to the parent)
 */
struct CCoinsCacheEntry
{
    Coin coin; // The actual cached data.
    unsigned char flags;

    enum Flags {
        /**
         * DIRTY means the CCoinsCacheEntry is potentially different from the
         * version in the parent cache. Failure to mark a coin as DIRTY when
         * it is potentially different from the parent cache will cause a
         * consensus failure, since the coin's state won't get written to the
         * parent when the cache is flushed.
         */
        DIRTY = (1 << 0),
        /**
         * FRESH means the parent cache does not have this coin or that it is a
         * spent coin in the parent cache. If a FRESH coin in the cache is
         * later spent, it can be deleted entirely and doesn't ever need to be
         * flushed to the parent. This is a performance optimization. Marking a
         * coin as FRESH when it exists unspent in the parent cache will cause a
         * consensus failure, since it might not be deleted from the parent
         * when this cache is flushed.
         */
        FRESH = (1 << 1),
    };

    CCoinsCacheEntry() : flags(0) {}
    explicit CCoinsCacheEntry(Coin&& coin_) : coin(std::move(coin_)), flags(0) {}
    CCoinsCacheEntry(Coin&& coin_, unsigned char flag) : coin(std::move(coin_)), flags(flag) {}
};
```

</details>

#### CCoinsViewCache methods

##### `CCoinsMap::iterator CCoinsViewCache::FetchCoin(const COutPoint &outpoint) const`

Find the given outpoint (txid + vout) in the CCoinsViewCache's `CCoinsMap
cacheCoins`, if we don't already have the Outpoint in our cache, ask for it from
the backing CCoinsView (`base->GetCoin(outpoint, tmp_coin`). If found,
`map::emplace` it into the cache view, track the added memory usage in `size_t
cachedCoinsUsage` (which tracks the memory usage of `Coin`'s in the cache), and
return an iterator to the newly emplaced coin in our CCoinsMap. If not found,
return `cachecoins.end()`.

<details>

<summary>Source code for `CCoinsViewCache::FetchCoin`</summary>

```cpp
// [ Returns an iterator from the Cache's Coin Map of a given outpoint ]
CCoinsMap::iterator CCoinsViewCache::FetchCoin(const COutPoint &outpoint) const {
    // [ std::unordered_map::find returns std::unordered_map::end if nothing is
    //   found ]
    CCoinsMap::iterator it = cacheCoins.find(outpoint);
    // [ If the outpoint is available in the cache, return the iterator to our
    //   cache entry ]
    if (it != cacheCoins.end())
        return it;

    // [ Otherwise we fall back onto the backing CCoinsView (in practice this
    //   will be the CCoinsViewErrorCatcher that wraps our CCoinsViewDB ]
    Coin tmp;

    // [ If the backing view can't get us the coin we want, return the `end`
    //   iterator to indicate failure ]
    if (!base->GetCoin(outpoint, tmp))
        return cacheCoins.end();

    // [ Emplace lets us construct the key and value in place, without the need
    //   for a temporary std::Pair<Key, T>
    //   std::piecewise_construct lets us also create the key (COutPoint) and
    //   T (CCoinsCacheEntry) without causing an extra copy of each to be made due to
    //   the use of the pair(T1 const&, T2 const&) constructor.
    //   
    //   I am a bit fuzzy on all the details, but this is partly discussed in a
    //   blogpost by Raymond Chen: "What’s up with std::piecewise_construct and
    //   std::forward_as_tuple?" and a comment on the post:
    //   source: https://devblogs.microsoft.com/oldnewthing/20220428-00/?p=106540#comment-139252
    // 
    //   Question: Why don't we check the value of
    //   cacheCoins.emplace(...).second here?
    // 
    //   Answer: the only condition where emplace fails *without* throwing an
    //   exception is if the inserted element is already present.
    // ]

    CCoinsMap::iterator ret = cacheCoins.emplace(std::piecewise_construct, std::forward_as_tuple(outpoint), std::forward_as_tuple(std::move(tmp))).first;

    
    // [ The comment below may be a bit confusing: some background is that spent
    //   coins are marked as spent by calling Coin::Clear() which calls
    //   CTxOut::SetNull() on the Coin's `CTxOut out`.
    //   bool Coin::IsSpent() just returns `out.IsNull();`  ]
    if (ret->second.coin.IsSpent()) {
        // The parent only has an empty entry for this outpoint; we can consider our
        // version as fresh.
        ret->second.flags = CCoinsCacheEntry::FRESH;
    }

    // [ Track the memory usage of the newly emplaced coin, note that
    //   cachedCoinsUsage does not track the usage of the entire CCoinsMap, just
    //   the `Coin`'s ]
    cachedCoinsUsage += ret->second.coin.DynamicMemoryUsage();
    return ret;
}
```

</details>

#### `bool CCoinsViewCache::GetCoin(const COutPoint &outpoint, Coin &coin) const`
Relies on  CCoinsViewCache::FetchCoin, the only difference is that GetCoin
modifies a Coin passed by reference instead of returning a `Coin`, and it returns
true if the coin is unspent, false if it is spent or not found in the
CCoinsViewCache or its backing CCoinsView.

Pointlessly minor note: If the outpoint is not found, the `coin` parameter is
unmodified and false is returned, if the outpoit is found, the `coin` parameter
is modified and false is returned.

<details>

<summary> Source for `CCoinsViewCache::GetCoin()` </summary>

```cpp
bool CCoinsViewCache::GetCoin(const COutPoint &outpoint, Coin &coin) const {
    CCoinsMap::const_iterator it = FetchCoin(outpoint);
    // [ cacheCoins.end() is the value returned by FetchCoin when the outpoint
    //   could not found ]
    if (it != cacheCoins.end()) {
        coin = it->second.coin;
        // [ The main difference from FetchCoin is that we return true if we
        //   find an unspent coin... ]
        return !coin.IsSpent();
    }

    // [ ...and false otherwise. ]
    return false;
}
```

</details>

#### `void CCoinsViewCache::AddCoin(const COutPoint &outpoint, Coin&& coin, bool possible_overwrite)`

AddCoin is used in `ApplyTxInUndo(Coin&& undo, CCoinsViewCache& view, const
COutPoint& out)` which restores a Coin at a given outpoint to a CCoinsViewCache
as part of 'undoing' a transaction. `ApplyTxInUndo` at present is only used
whenever `Chainstate::DisconnectBlock` happens, and we loop through the block,
undoing transactions.

<details>

<summary>Source Code for `CCoinsViewCache::AddCoin`</summary>

```cpp
void CCoinsViewCache::AddCoin(const COutPoint &outpoint, Coin&& coin, bool possible_overwrite) {
    // [ Worth repeating here that a 'spent' Coin is empty (coin.out.IsNull() ==
    //   true), there would be no meaningful way for us to deal with the
    //   situation where someone wanted to restore a coin that is empty. ]
    assert(!coin.IsSpent());

    // [ An unspendable coin was never in our cache in the first place. ]
    if (coin.out.scriptPubKey.IsUnspendable()) return;
    CCoinsMap::iterator it;
    bool inserted;

    // [ std::unordered_map::emplace returns a tuple whose first value is the
    //   iterator of the newly emplaced member and whose second value
    //   is a boolean indicating whether or not the member was inserted.
    //
    //   The only case in which inserted would be false, is if insertion failed
    //   due to the element already being present, otherwise emplace would throw
    //   an exception. ] 
    std::tie(it, inserted) = cacheCoins.emplace(std::piecewise_construct, std::forward_as_tuple(outpoint), std::tuple<>());
    bool fresh = false;

    // [ if !inserted, subtract the existing memory usage since we are about to
    //   modify the coin and then we'll check in on the DynamicMemoryUsage and
    //   add back the new DynamicMemoryUsage().
    //
    //   Question: Is behavior here defined if cachedCoinsUsage underflows? We
    //   are going to be adding back the new usage later, is there a danger if
    //   cachedCoinsUsage < it->second.coin.DynamicMemoryUsage()? 
    // 
    //   Answer: I think no! Since cachedCoinsUsage is size_t which is unsigned,
    //   and unsigned integer overflow / underflow is defined as result % 2^n
    //   where n is the size of the expression's type in bits, associativity is
    //   preserved when doing unsigned integer arithmetic:

    //   (existingUsage - oldCoin) + newCoin == (existingUsage + newCoin) - oldCoin)

    if (!inserted) {
        cachedCoinsUsage -= it->second.coin.DynamicMemoryUsage();
    }
    if (!possible_overwrite) {
        // [ Question: In what case could the coin be unspent here? ]
        if (!it->second.coin.IsSpent()) {
            throw std::logic_error("Attempted to overwrite an unspent coin (when possible_overwrite is false)");
        }
        // If the coin exists in this cache as a spent coin and is DIRTY, then
        // its spentness hasn't been flushed to the parent cache. We're
        // re-adding the coin to this cache now but we can't mark it as FRESH.
        // If we mark it FRESH and then spend it before the cache is flushed
        // we would remove it from this cache and would never flush spentness
        // to the parent cache.
        //
        // Re-adding a spent coin can happen in the case of a re-org (the coin
        // is 'spent' when the block adding it is disconnected and then
        // re-added when it is also added in a newly connected block).
        //
        // If the coin doesn't exist in the current cache, or is spent but not
        // DIRTY, then it can be marked FRESH.
        fresh = !(it->second.flags & CCoinsCacheEntry::DIRTY);
    }
    it->second.coin = std::move(coin);
    it->second.flags |= CCoinsCacheEntry::DIRTY | (fresh ? CCoinsCacheEntry::FRESH : 0);
    cachedCoinsUsage += it->second.coin.DynamicMemoryUsage();
    TRACE5(utxocache, add,
           outpoint.hash.data(),
           (uint32_t)outpoint.n,
           (uint32_t)it->second.coin.nHeight,
           (int64_t)it->second.coin.out.nValue,
           (bool)it->second.coin.IsCoinBase());
}
```
</details>
