# [#27286](https://github.com/bitcoin/bitcoin/pull/27286) wallet: Keep track of the wallet's own transaction outputs in memory
_All code comments in `[]` are my own._

## Background

`CWallet`'s track transactions of interest in an unordered map from txid
(`uint256`) to `CWalletTx`.

```cpp
/**
 * A CWallet maintains a set of transactions and balances, and provides the ability to create new transactions.
 */
class CWallet final : public WalletStorage, public interfaces::Chain::Notifications
{
public:
    /** Map from txid to CWalletTx for all transactions this wallet is
     * interested in, including received and sent transactions. */
    std::unordered_map<uint256, CWalletTx, SaltedTxidHasher> mapWallet GUARDED_BY(cs_wallet);
}
```

`CWalletTx` is a `CTransactionRef` (shared pointer to a `CTransaction`), with
some metadata the wallet cares about, like the "comment/to" field which I think
the GUI displays, and some feebumping relationships for the `bumpfee` if they
exist, like the txid this replaces, or the txid this was replaced by, and
something called `nTimeSmart`, which seems to be a topic worth returning to but
which I'll avoid for now.

One big picture question I have about `CWalletTx`: Is any of this metadata
relevant to *only* the output we care about? If so, how are metadata for
transactions containing multiple outputs we care about handled?

<details>

<summary>

#### Sidebar: `CWalletTx` annotated

</summary>

```cpp
//! All possible CWalletTx states
using TxState = std::variant<TxStateConfirmed, TxStateInMempool, TxStateBlockConflicted, TxStateInactive, TxStateUnrecognized>;

// [ Used to imitate the key-value map in which
//   transaction data is serialized in the DB. ]
typedef std::map<std::string, std::string> mapValue_t;

/**
 * A transaction with a bunch of additional info that only the owner cares about.
 * It includes any unrecorded transactions needed to link it back to the block chain.
 */
class CWalletTx
{
public:
    /**
     * Key/value map with information about the transaction.
     *
     * The following keys can be read and written through the map and are
     * serialized in the wallet database:
     *
     *     "comment", "to"   - comment strings provided to sendtoaddress,
     *                         and sendmany wallet RPCs
     *     "replaces_txid"   - txid (as HexStr) of transaction replaced by
     *                         bumpfee on transaction created by bumpfee
     *     "replaced_by_txid" - txid (as HexStr) of transaction created by
     *                         bumpfee on transaction replaced by bumpfee
     *     "from", "message" - obsolete fields that could be set in UI prior to
     *                         2011 (removed in commit 4d9b223)
     *
     * The following keys are serialized in the wallet database, but shouldn't
     * be read or written through the map (they will be temporarily added and
     * removed from the map during serialization):
     *
     *     "fromaccount"     - serialized strFromAccount value
     *     "n"               - serialized nOrderPos value
     *     "timesmart"       - serialized nTimeSmart value
     *     "spent"           - serialized vfSpent value that existed prior to
     *                         2014 (removed in commit 93a18a3)
     */
    mapValue_t mapValue;
    // [ Mysterious! Added in [#521](https://github.com/bitcoin/bitcoin/pull/521),
    //   has something to do with address URI's. ]
    std::vector<std::pair<std::string, std::string> > vOrderForm;
    unsigned int fTimeReceivedIsTxTime;
    unsigned int nTimeReceived; //!< time received by this node
    /**
     * Stable timestamp that never changes, and reflects the order a transaction
     * was added to the wallet. Timestamp is based on the block time for a
     * transaction added as part of a block, or else the time when the
     * transaction was received if it wasn't part of a block, with the timestamp
     * adjusted in both cases so timestamp order matches the order transactions
     * were added to the wallet. More details can be found in
     * CWallet::ComputeTimeSmart().
     */
    unsigned int nTimeSmart;
    // [ Q: Why do we want to know this?
    //   A: Turns out, we don't! We used to leak privacy by aggressively
    //   broadcasting our own transactions, this was removed in #3115 (https://github.com/bitcoin/bitcoin/pull/3115/commits/fe5234645036178a540fdd4166b26493b0b40529)
    //   Attempted to be removed in #9351, but author closed, I've reopened: https://github.com/bitcoin/bitcoin/pull/32502
    // ]
    /**
     * From me flag is set to 1 for transactions that were created by the wallet
     * on this bitcoin node, and set to 0 for transactions that were created
     * externally and came in through the network or sendrawtransaction RPC.
     */
    bool fFromMe;
    int64_t nOrderPos; //!< position in ordered transaction list
    std::multimap<int64_t, CWalletTx*>::const_iterator m_it_wtxOrdered;

    // memory only
    enum AmountType { DEBIT, CREDIT, IMMATURE_CREDIT, AVAILABLE_CREDIT, AMOUNTTYPE_ENUM_ELEMENTS };
    mutable CachableAmount m_amounts[AMOUNTTYPE_ENUM_ELEMENTS];
    /**
     * This flag is true if all m_amounts caches are empty. This is particularly
     * useful in places where MarkDirty is conditionally called and the
     * condition can be expensive and thus can be skipped if the flag is true.
     * See MarkDestinationsDirty.
     */
    mutable bool m_is_cache_empty{true};
    mutable bool fChangeCached;
    mutable CAmount nChangeCached;

    CWalletTx(CTransactionRef tx, const TxState& state) : tx(std::move(tx)), m_state(state)
    {
        Init();
    }

    void Init()
    {
        mapValue.clear();
        vOrderForm.clear();
        fTimeReceivedIsTxTime = false;
        nTimeReceived = 0;
        nTimeSmart = 0;
        fFromMe = false;
        fChangeCached = false;
        nChangeCached = 0;
        nOrderPos = -1;
    }

    CTransactionRef tx;
    TxState m_state;

    // [ Why do we care? https://github.com/bitcoin/bitcoin/pull/27307 ]
    // Set of mempool transactions that conflict
    // directly with the transaction, or that conflict
    // with an ancestor transaction. This set will be
    // empty if state is InMempool or Confirmed, but
    // can be nonempty if state is Inactive or
    // BlockConflicted.
    std::set<Txid> mempool_conflicts;
```

</details>

## Problem

The only way we track block data that's interesting to `CWallet`'s is at the
transaction level with `mapWallet`, which tracks the transactions that are of
interest to the wallet. (Those that spend from or send to a script or key that
the wallet cares about) But, when computing balance
([`GetBalance`](https://github.com/bitcoin/bitcoin/blob/f1d78a3087fb743a61f0fb3cb9d89e0ad7c848ff/src/wallet/receive.cpp#L293-L320))
or retrieving available outputs for coin selection
([`AvailableCoins`](https://github.com/bitcoin/bitcoin/blob/f1d78a3087fb743a61f0fb3cb9d89e0ad7c848ff/src/wallet/spend.cpp#L314-L476)),
we don't care about the transactions this wallet is involved in, we care about
the transaction *outputs* this wallet is involved in.

Because of this, when we do either of these presently, we iterate through every
output in the relevant transactions to find the output(s) of interest.

## Solution

Keep track of the transaction outputs of interest to a wallet, this is done by
checking which outputs, `IsMine()` on wallet load.

### [walletdb: Load Txs last](https://github.com/bitcoin/bitcoin/pull/27286/commits/101899b1164716c1ebdf15554ce0eaed7dfc6fbc)

	Need to load txs last so that IsMine works.

This gives a good premonition of the change to come, by the time we get to
`LoadTxRecords()`, we will want to know about everything the wallet cares about.

I do have a small complaint about this though, this PR introduces a constraint
to the order in which records are loaded, but this constraint doesn't appear to
be documented (meh) or enforced (what we really want) in any way. Is there a way
to have this restriction be enforced either by the compiler or by tests?

```diff
diff --git a/src/wallet/walletdb.cpp b/src/wallet/walletdb.cpp
index b06787a5b36d0..834aedcc6bf74 100644
--- a/src/wallet/walletdb.cpp
+++ b/src/wallet/walletdb.cpp
@@ -1184,14 +1184,14 @@ DBErrors WalletBatch::LoadWallet(CWallet* pwallet)
         // Load address book
         result = std::max(LoadAddressBookRecords(pwallet, *m_batch), result);
 
-        // Load tx records
-        result = std::max(LoadTxRecords(pwallet, *m_batch, upgraded_txs, any_unordered), result);
-
         // Load SPKMs
         result = std::max(LoadActiveSPKMs(pwallet, *m_batch), result);
 
         // Load decryption keys
         result = std::max(LoadDecryptionKeys(pwallet, *m_batch), result);
+
+        // Load tx records
+        result = std::max(LoadTxRecords(pwallet, *m_batch, upgraded_txs, any_unordered), result);
```

```diff
diff --git a/src/wallet/wallet.cpp b/src/wallet/wallet.cpp
index 86d1cbdf306b6..7624468004786 100644
--- a/src/wallet/wallet.cpp
+++ b/src/wallet/wallet.cpp
@@ -1117,6 +1117,9 @@ CWalletTx* CWallet::AddToWallet(CTransactionRef tx, const TxState& state, const
     // Break debit/credit balance caches:
     wtx.MarkDirty();
 
+    // Cache the outputs that belong to the wallet
+    RefreshSingleTxTXOs(wtx);
+
     // Notify UI of new or updated transaction
     NotifyTransactionChanged(hash, fInsertedNew ? CT_NEW : CT_UPDATED);
 
@@ -1180,6 +1183,8 @@ bool CWallet::LoadToWallet(const uint256& hash, const UpdateWalletTxFn& fill_wtx
     // Update birth time when tx time is older than it.
     MaybeUpdateBirthTime(wtx.GetTxTime());
 
+    // Make sure the tx outputs are known by the wallet
+    RefreshSingleTxTXOs(wtx);
     return true;
 }
 
@@ -2337,6 +2342,9 @@ util::Result<void> CWallet::RemoveTxs(WalletBatch& batch, std::vector<uint256>&
             wtxOrdered.erase(it->second.m_it_wtxOrdered);
             for (const auto& txin : it->second.tx->vin)
                 mapTxSpends.erase(txin.prevout);
+            for (unsigned int i = 0; i < it->second.tx->vout.size(); ++i) {
+                m_txos.erase(COutPoint(Txid::FromUint256(hash), i));
+            }
             mapWallet.erase(it);
             NotifyTransactionChanged(hash, CT_DELETED);
         }
@@ -4454,4 +4462,22 @@ std::optional<CKey> CWallet::GetKey(const CKeyID& keyid) const
     }
     return std::nullopt;
 }
+
+void CWallet::RefreshSingleTxTXOs(const CWalletTx& wtx)
+{
+    AssertLockHeld(cs_wallet);
+    for (uint32_t i = 0; i < wtx.tx->vout.size(); ++i) {
+        const CTxOut& txout = wtx.tx->vout.at(i);
+        isminetype ismine = IsMine(txout);
+        if (ismine == ISMINE_NO) {
+            continue;
+        }
+        COutPoint outpoint(wtx.GetHash(), i);
+        if (m_txos.contains(outpoint)) {
+            m_txos.at(outpoint).SetIsMine(ismine);
+        } else {
+            m_txos.emplace(outpoint, WalletTXO{wtx, txout, ismine});
+        }
+    }
+}
 } // namespace wallet
diff --git a/src/wallet/wallet.h b/src/wallet/wallet.h
index a3800e7290196..1c5e0e5e4476f 100644
--- a/src/wallet/wallet.h
+++ b/src/wallet/wallet.h
@@ -428,6 +428,9 @@ class CWallet final : public WalletStorage, public interfaces::Chain::Notificati
     //! Cache of descriptor ScriptPubKeys used for IsMine. Maps ScriptPubKey to set of spkms
     std::unordered_map<CScript, std::vector<ScriptPubKeyMan*>, SaltedSipHasher> m_cached_spks;
 
+    //! Set of both spent and unspent transaction outputs owned by this wallet
+    std::unordered_map<COutPoint, WalletTXO, SaltedOutpointHasher> m_txos GUARDED_BY(cs_wallet);
+
     /**
      * Catch wallet up to current chain, scanning new blocks, updating the best
      * block locator and m_last_block_processed, and registering for
@@ -507,6 +510,9 @@ class CWallet final : public WalletStorage, public interfaces::Chain::Notificati
 
     std::set<uint256> GetTxConflicts(const CWalletTx& wtx) const EXCLUSIVE_LOCKS_REQUIRED(cs_wallet);
 
+    /** Cache outputs that belong to the wallet from a single transaction */
+    void RefreshSingleTxTXOs(const CWalletTx& wtx) EXCLUSIVE_LOCKS_REQUIRED(cs_wallet);
+
     /**
      * Return depth of transaction in blockchain:
      * <0  : conflicts with a transaction this deep in the blockchain
```
</details>

### [wallet: Exit IsTrustedTx early if wtx is already in trusted_parents](https://github.com/bitcoin/bitcoin/pull/27286/commits/fe545f997d77c0f8bd289b7ae1760327cb6e3a2d)


<details>

<summary>

Commit diff

</summary>

```diff
diff --git a/src/wallet/receive.cpp b/src/wallet/receive.cpp
index c164266f80bfd..4ff2451301fc9 100644
--- a/src/wallet/receive.cpp
+++ b/src/wallet/receive.cpp
@@ -257,6 +257,10 @@ bool CachedTxIsFromMe(const CWallet& wallet, const CWalletTx& wtx, const isminef
 bool CachedTxIsTrusted(const CWallet& wallet, const CWalletTx& wtx, std::set<uint256>& trusted_parents)
 {
     AssertLockHeld(wallet.cs_wallet);
+
+    // This wtx is already trusted
+    if (trusted_parents.contains(wtx.GetHash())) return true;
+
     if (wtx.isConfirmed()) return true;
     if (wtx.isBlockConflicted()) return false;
     // using wtx's cached debit
```
</details>

### [wallet: Change balance calculation to use m_txos](https://github.com/bitcoin/bitcoin/pull/27286/commits/ff73562fb5df406da95d6a6327e3d22b8d3e12f2)

	Since we track the outputs owned by the wallet with m_txos, we can now
	calculate the balance of the wallet by iterating m_txos and summing up
	the amounts of the unspent txos.

<details>

<summary>

Commit diff

</summary>

```diff
diff --git a/src/wallet/receive.cpp b/src/wallet/receive.cpp
index 4ff2451301fc9..5ff3b9110a2ff 100644
--- a/src/wallet/receive.cpp
+++ b/src/wallet/receive.cpp
@@ -4,6 +4,7 @@
 
 #include <consensus/amount.h>
 #include <consensus/consensus.h>
+#include <util/check.h>
 #include <wallet/receive.h>
 #include <wallet/transaction.h>
 #include <wallet/wallet.h>
@@ -297,27 +298,40 @@ bool CachedTxIsTrusted(const CWallet& wallet, const CWalletTx& wtx)
 Balance GetBalance(const CWallet& wallet, const int min_depth, bool avoid_reuse)
 {
     Balance ret;
-    isminefilter reuse_filter = avoid_reuse ? ISMINE_NO : ISMINE_USED;
+    bool allow_used_addresses = !avoid_reuse || !wallet.IsWalletFlagSet(WALLET_FLAG_AVOID_REUSE);
     {
         LOCK(wallet.cs_wallet);
-        std::set<uint256> trusted_parents;
-        for (const auto& entry : wallet.mapWallet)
-        {
-            const CWalletTx& wtx = entry.second;
-            const bool is_trusted{CachedTxIsTrusted(wallet, wtx, trusted_parents)};
-            const int tx_depth{wallet.GetTxDepthInMainChain(wtx)};
-            const CAmount tx_credit_mine{CachedTxGetAvailableCredit(wallet, wtx, ISMINE_SPENDABLE | reuse_filter)};
-            const CAmount tx_credit_watchonly{CachedTxGetAvailableCredit(wallet, wtx, ISMINE_WATCH_ONLY | reuse_filter)};
-            if (is_trusted && tx_depth >= min_depth) {
-                ret.m_mine_trusted += tx_credit_mine;
-                ret.m_watchonly_trusted += tx_credit_watchonly;
-            }
-            if (!is_trusted && tx_depth == 0 && wtx.InMempool()) {
-                ret.m_mine_untrusted_pending += tx_credit_mine;
-                ret.m_watchonly_untrusted_pending += tx_credit_watchonly;
+        for (const auto& [outpoint, txo] : wallet.GetTXOs()) {
+            Assert(MoneyRange(txo.GetTxOut().nValue));
+
+            const bool is_trusted{CachedTxIsTrusted(wallet, txo.GetWalletTx())};
+            const int tx_depth{wallet.GetTxDepthInMainChain(txo.GetWalletTx())};
+
+            if (!wallet.IsSpent(outpoint) && (allow_used_addresses || !wallet.IsSpentKey(txo.GetTxOut().scriptPubKey))) {
+                // Get the amounts for mine and watchonly
+                CAmount credit_mine = 0;
+                CAmount credit_watchonly = 0;
+                if (txo.GetIsMine() == ISMINE_SPENDABLE) {
+                    credit_mine = txo.GetTxOut().nValue;
+                } else if (txo.GetIsMine() == ISMINE_WATCH_ONLY) {
+                    credit_watchonly = txo.GetTxOut().nValue;
+                } else {
+                    // We shouldn't see any other isminetypes
+                    Assume(false);
+                }
+
+                // Set the amounts in the return object
+                if (wallet.IsTxImmatureCoinBase(txo.GetWalletTx()) && txo.GetWalletTx().isConfirmed()) {
+                    ret.m_mine_immature += credit_mine;
+                    ret.m_watchonly_immature += credit_watchonly;
+                } else if (is_trusted && tx_depth >= min_depth) {
+                    ret.m_mine_trusted += credit_mine;
+                    ret.m_watchonly_trusted += credit_watchonly;
+                } else if (!is_trusted && txo.GetWalletTx().InMempool()) {
+                    ret.m_mine_untrusted_pending += credit_mine;
+                    ret.m_watchonly_untrusted_pending += credit_watchonly;
+                }
             }
-            ret.m_mine_immature += CachedTxGetImmatureCredit(wallet, wtx, ISMINE_SPENDABLE);
-            ret.m_watchonly_immature += CachedTxGetImmatureCredit(wallet, wtx, ISMINE_WATCH_ONLY);
         }
     }
     return ret;
@@ -329,32 +343,19 @@ std::map<CTxDestination, CAmount> GetAddressBalances(const CWallet& wallet)
 
     {
         LOCK(wallet.cs_wallet);
-        std::set<uint256> trusted_parents;
-        for (const auto& walletEntry : wallet.mapWallet)
-        {
-            const CWalletTx& wtx = walletEntry.second;
+        for (const auto& [outpoint, txo] : wallet.GetTXOs()) {
+            if (!CachedTxIsTrusted(wallet, txo.GetWalletTx())) continue;
+            if (wallet.IsTxImmatureCoinBase(txo.GetWalletTx())) continue;
 
-            if (!CachedTxIsTrusted(wallet, wtx, trusted_parents))
-                continue;
+            int nDepth = wallet.GetTxDepthInMainChain(txo.GetWalletTx());
+            if (nDepth < (CachedTxIsFromMe(wallet, txo.GetWalletTx(), ISMINE_ALL) ? 0 : 1)) continue;
 
-            if (wallet.IsTxImmatureCoinBase(wtx))
-                continue;
+            CTxDestination addr;
+            Assume(wallet.IsMine(txo.GetTxOut()));
+            if(!ExtractDestination(txo.GetTxOut().scriptPubKey, addr)) continue;
 
-            int nDepth = wallet.GetTxDepthInMainChain(wtx);
-            if (nDepth < (CachedTxIsFromMe(wallet, wtx, ISMINE_ALL) ? 0 : 1))
-                continue;
-
-            for (unsigned int i = 0; i < wtx.tx->vout.size(); i++) {
-                const auto& output = wtx.tx->vout[i];
-                CTxDestination addr;
-                if (!wallet.IsMine(output))
-                    continue;
-                if(!ExtractDestination(output.scriptPubKey, addr))
-                    continue;
-
-                CAmount n = wallet.IsSpent(COutPoint(Txid::FromUint256(walletEntry.first), i)) ? 0 : output.nValue;
-                balances[addr] += n;
-            }
+            CAmount n = wallet.IsSpent(outpoint) ? 0 : txo.GetTxOut().nValue;
+            balances[addr] += n;
         }
     }
 
diff --git a/src/wallet/wallet.h b/src/wallet/wallet.h
index 1c5e0e5e4476f..dfe8196f81807 100644
--- a/src/wallet/wallet.h
+++ b/src/wallet/wallet.h
@@ -510,6 +510,8 @@ class CWallet final : public WalletStorage, public interfaces::Chain::Notificati
 
     std::set<uint256> GetTxConflicts(const CWalletTx& wtx) const EXCLUSIVE_LOCKS_REQUIRED(cs_wallet);
 
+    const std::unordered_map<COutPoint, WalletTXO, SaltedOutpointHasher>& GetTXOs() const EXCLUSIVE_LOCKS_REQUIRED(cs_wallet) { AssertLockHeld(cs_wallet); return m_txos; };
+
     /** Cache outputs that belong to the wallet from a single transaction */
     void RefreshSingleTxTXOs(const CWalletTx& wtx) EXCLUSIVE_LOCKS_REQUIRED(cs_wallet);
 
```
</details>

### [wallet: Recalculate the wallet's txos after any imports](https://github.com/bitcoin/bitcoin/pull/27286/commits/850de8343e36a17a5c875b1be974153bf06efaca)


<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [test: Test for balance update due to watchonly becoming spendable](https://github.com/bitcoin/bitcoin/pull/27286/commits/fb8644ca5f4380b1ae492a1c6ad19d531e8726a0)


<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [wallet: Use wallet's TXO set in AvailableCoins](https://github.com/bitcoin/bitcoin/pull/27286/commits/5fe938b4624f0df466fd1184f6761678046f39f1)

	Instead of iterating every transaction and every output stored in wallet
	when trying to figure out what outputs can be spent, iterate the TXO set
	which should be a lot smaller.

<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [wallet: Retrieve TXO directly in FetchSelectedInputs](https://github.com/bitcoin/bitcoin/pull/27286/commits/a8331c2c417129bb438fe8d467a7e63180b2392e)

	Instead of searching mapWallet for the preselected inputs, search
	m_txos.

<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [wallet: Recompute wallet TXOs after descriptor migration](https://github.com/bitcoin/bitcoin/pull/27286/commits/f627c4b37fb724a7bbbaf6678d1fd73859ba6637)

	When a legacy wallet has been migrated to contain descriptors, but
	before the transactions have been updated to match, we need to recompute
	the wallet TXOs so that the transaction update will work correctly.

<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [wallet: Have GetDebit use the wallet's TXO set](https://github.com/bitcoin/bitcoin/pull/27286/commits/5c346f3fa3b9045f18d51ed63d940ffb8f06ceac)

	Instead of looking up the previous tx in mapWallet, and then calling
	IsMine on the specified output, use the TXO set and its cached IsMine
	value.

<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [wallet: Remove unused CachedTxGet{Available,Immature}Credit](https://github.com/bitcoin/bitcoin/pull/27286/commits/4ec762e9497ccfc2c9e017139ad66154dbcb6964)

	These two functions are no longer used as GetBalances now uses the TXO
	set rather than per-tx cached balances

<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

### [bench: Have AvailableCoins benchmark include a lot of unrelated utxos](https://github.com/bitcoin/bitcoin/pull/27286/commits/26a51e8863992c54025ed48645ba6f6a762d13ef)

	One of the main issues with AvailableCoins is its performance when txs
	have unrelated outputs, so update the benchmark to check the performance
	of that.

<details>

<summary>

Commit diff

</summary>

```diff
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="Content-type" content="text/html; charset=utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'self'; connect-src 'self'; form-action 'self'; img-src 'self' data:; script-src 'self'; style-src 'unsafe-inline'">
    <meta content="origin" name="referrer">
    <title>Rate limit &middot; GitHub</title>
    <meta name="viewport" content="width=device-width">
    <style type="text/css" media="screen">
      body {
        background-color: #f6f8fa;
        color: #24292e;
        font-family: -apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol;
        font-size: 14px;
        line-height: 1.5;
        margin: 0;
      }

      .container { margin: 50px auto; max-width: 600px; text-align: center; padding: 0 24px; }

      a { color: #0366d6; text-decoration: none; }
      a:hover { text-decoration: underline; }

      h1 { line-height: 60px; font-size: 48px; font-weight: 300; margin: 0px; text-shadow: 0 1px 0 #fff; }
      p { color: rgba(0, 0, 0, 0.5); margin: 20px 0 40px; }

      ul { list-style: none; margin: 25px 0; padding: 0; }
      li { display: table-cell; font-weight: bold; width: 1%; }

      .logo { display: inline-block; margin-top: 35px; }
      .logo-img-2x { display: none; }
      @media
      only screen and (-webkit-min-device-pixel-ratio: 2),
      only screen and (   min--moz-device-pixel-ratio: 2),
      only screen and (     -o-min-device-pixel-ratio: 2/1),
      only screen and (        min-device-pixel-ratio: 2),
      only screen and (                min-resolution: 192dpi),
      only screen and (                min-resolution: 2dppx) {
        .logo-img-1x { display: none; }
        .logo-img-2x { display: inline-block; }
      }

      #suggestions {
        margin-top: 35px;
        color: #ccc;
      }
      #suggestions a {
        color: #666666;
        font-weight: 200;
        font-size: 14px;
        margin: 0 10px;
      }

    </style>
  </head>
  <body>

    <div class="container">

      <h1>Whoa there!</h1>
      <p>You have exceeded a secondary rate limit.<br><br>
        Please wait a few minutes before you try again;<br>
        in some cases this may take up to an hour.
      </p>
      <div id="suggestions">
        <a href="https://support.github.com/contact">Contact Support</a> &mdash;
        <a href="https://githubstatus.com">GitHub Status</a> &mdash;
        <a href="https://twitter.com/githubstatus">@githubstatus</a>
      </div>

      <a href="/" class="logo logo-img-1x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpFMTZCRDY3REIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpFMTZCRDY3RUIzRjAxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdCQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjdDQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+SM9MCAAAA+5JREFUeNrEV11Ik1EY3s4+ddOp29Q5b0opCgKFsoKoi5Kg6CIhuwi6zLJLoYLopq4qsKKgi4i6CYIoU/q5iDAKs6syoS76IRWtyJ+p7cdt7sf1PGOD+e0c3dygAx/67ZzzPM95/877GYdHRg3ZjMXFxepQKNS6sLCwJxqNNuFpiMfjVs4ZjUa/pmmjeD6VlJS8NpvNT4QQ7mxwjSsJiEQim/1+/9lgMHgIr5ohuxG1WCw9Vqv1clFR0dCqBODElV6v90ogEDjGdYbVjXhpaendioqK07CIR7ZAqE49PT09BPL2PMgTByQGsYiZlQD4uMXtdr+JxWINhgINYhGT2MsKgMrm2dnZXgRXhaHAg5jEJodUAHxux4LudHJE9RdEdA+i3Juz7bGHe4mhE9FNrgwBCLirMFV9Okh5eflFh8PR5nK5nDabrR2BNJlKO0T35+Li4n4+/J+/JQCxhmu5h3uJoXNHPbmWZAHMshWB8l5/ipqammaAf0zPDDx1ONV3vurdidqwAQL+pEc8sLcAe1CCvQ3YHxIW8Pl85xSWNC1hADDIv0rIE/o4J0k3kww4xSlwIhcq3EFFOm7KN/hUGOQkt0CFa5WpNJlMvxBEz/IVQAxg/ZRZl9wiHA63yDYieM7DnLP5CiAGsC7I5sgtYKJGWe2A8seFqgFJrJjEPY1Cn3pJ8/9W1e5VWsFDTEmFrBcoDhZJEQkXuhICMyKpjhahqN21hRYATKfUOlDmkygrR4o4C0VOLGJKrOITKB4jijzdXygBKixyC5TDQdnk/Pz8qRw6oOWGlsTKGOQW6OH6FBWsyePxdOXLTgxiyebILZCjz+GLgMIKnXNzc49YMlcRdHXcSwxFVgTInQhC9G33UhNoJLuqq6t345p9y3eUy8OTk5PjAHuI9uo4b07FBaOhsu0A4Unc+T1TU1Nj3KsSSE5yJ65jqF2DDd8QqWYmAZrIM2VlZTdnZmb6AbpdV9V6ec9znf5Q7HjYumdRE0JOp3MjitO4SFa+cZz8Umqe3TCbSLvdfkR/kWDdNQl5InuTcysOcpFT35ZrbBxx4p3JAHlZVVW1D/634VRt+FvLBgK/v5LV9WS+10xMTEwtRw7XvqOL+e2Q8V3AYIOIAXQ26/heWVnZCVfcyKHg2CBgTpmPmjYM8l24GyaUHyaIh7XwfR9ErE8qHoDfn2LTNAVC0HX6MFcBIP8Bi+6F6cdW/DICkANRfx99fEYFQ7Nph5i/uQiA214gno7K+guhaiKg9gC62+M8eR7XsBsYJ4ilam60Fb7r7uAj8wFyuwM1oIOWgfmDy6RXEEQzJMPe23DXrVS7rtyD3Df8z/FPgAEAzWU5Ku59ZAUAAAAASUVORK5CYII=">
      </a>

      <a href="/" class="logo logo-img-2x">
        <img width="32" height="32" title="" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJbWFnZVJlYWR5ccllPAAAAyRpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+IDx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IkFkb2JlIFhNUCBDb3JlIDUuMy1jMDExIDY2LjE0NTY2MSwgMjAxMi8wMi8wNi0xNDo1NjoyNyAgICAgICAgIj4gPHJkZjpSREYgeG1sbnM6cmRmPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5LzAyLzIyLXJkZi1zeW50YXgtbnMjIj4gPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIiB4bWxuczp4bXBNTT0iaHR0cDovL25zLmFkb2JlLmNvbS94YXAvMS4wL21tLyIgeG1sbnM6c3RSZWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZVJlZiMiIHhtcDpDcmVhdG9yVG9vbD0iQWRvYmUgUGhvdG9zaG9wIENTNiAoTWFjaW50b3NoKSIgeG1wTU06SW5zdGFuY2VJRD0ieG1wLmlpZDpEQUM1QkUxRUI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiIgeG1wTU06RG9jdW1lbnRJRD0ieG1wLmRpZDpEQUM1QkUxRkI0MUMxMUUyQUQzREIxQzRENUFFNUM5NiI+IDx4bXBNTTpEZXJpdmVkRnJvbSBzdFJlZjppbnN0YW5jZUlEPSJ4bXAuaWlkOkUxNkJENjdGQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2IiBzdFJlZjpkb2N1bWVudElEPSJ4bXAuZGlkOkUxNkJENjgwQjNGMDExRTJBRDNEQjFDNEQ1QUU1Qzk2Ii8+IDwvcmRmOkRlc2NyaXB0aW9uPiA8L3JkZjpSREY+IDwveDp4bXBtZXRhPiA8P3hwYWNrZXQgZW5kPSJyIj8+hfPRaQAAB6lJREFUeNrsW2mM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">
      </a>
    </div>
  </body>
</html>
```
</details>

