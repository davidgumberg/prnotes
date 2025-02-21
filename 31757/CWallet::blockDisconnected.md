# CWallet::blockDisconnected

This is the wallet's callback for when a block is disconnected from the chain.

## Detour to see how chain notifications callbacks work

Classes can subscribe to chainstate notifications by inheriting from
`interfaces::Chain::Notifications`:

```cpp
class CWallet final : public WalletStorage, public interfaces::Chain::Notifications
```

and implementing the notification callbacks defined by this virtual interface
class:

```cpp
namespace interfaces { 

class Chain
{
public:
    //! Chain notifications.
    class Notifications
    {
    public:
        virtual ~Notifications() = default;
        virtual void transactionAddedToMempool(const CTransactionRef& tx) {}
        virtual void transactionRemovedFromMempool(const CTransactionRef& tx, MemPoolRemovalReason reason) {}
        virtual void blockConnected(ChainstateRole role, const BlockInfo& block) {}
        virtual void blockDisconnected(const BlockInfo& block) {}
        virtual void updatedBlockTip() {}
        virtual void chainStateFlushed(ChainstateRole role, const CBlockLocator& locator) {}
    };

    // [ virtual because class Chain uses the PIMPL pattern, implemented in
    //   ChainImpl ]
    //! Register handler for notifications.
    virtual std::unique_ptr<Handler> handleNotifications(std::shared_ptr<Notifications> notifications) = 0;
}

} // namespace interfaces
```

<details>

<summary>handleNotifications rabbit hole</summary>

```cpp
class ChainImpl : public Chain
{
public:
    std::unique_ptr<Handler> handleNotifications(std::shared_ptr<Notifications> notifications) override
    {
        return std::make_unique<NotificationsHandlerImpl>(validation_signals(), std::move(notifications));
    }
```

Peeling back one more layer:

```cpp

namespace interfaces {

//! Generic interface for managing an event handler or callback function
//! registered with another interface. Has a single disconnect method to cancel
//! the registration and prevent any future notifications.
class Handler
{
public:
    virtual ~Handler() = default;

    //! Disconnect the handler.
    virtual void disconnect() = 0;
};

class NotificationsHandlerImpl : public Handler
{
public:
    explicit NotificationsHandlerImpl(ValidationSignals& signals, std::shared_ptr<Chain::Notifications> notifications)
        : m_signals{signals}, m_proxy{std::make_shared<NotificationsProxy>(std::move(notifications))}
    {
        m_signals.RegisterSharedValidationInterface(m_proxy);
    }
    ~NotificationsHandlerImpl() override { disconnect(); }
    void disconnect() override
    {
        if (m_proxy) {
            m_signals.UnregisterSharedValidationInterface(m_proxy);
            m_proxy.reset();
        }
    }
    ValidationSignals& m_signals;
    std::shared_ptr<NotificationsProxy> m_proxy;
};
```

Nah nevermind I won't keep digging here,



</details>

A class that implements the Chain::Notifications interface can register itself
with a chain by invoking `chain::handleNotifications()`, in `CWallet` this is
done in `CWallet::AttachChain()`. If you ignore the rescanning logic,
`CWalletAttachChain()` is very simple, it just sets the wallet's `m_chain`
pointer to the chain, and registers for notifications with the chain, all of the
rest of the function has to do with rescanning logic, which I won't mention
here.

```cpp
bool CWallet::AttachChain(const std::shared_ptr<CWallet>& walletInstance, interfaces::Chain& chain, const bool rescan_required, bilingual_str& error, std::vector<bilingual_str>& warnings)
{
    LOCK(walletInstance->cs_wallet);
    // allow setting the chain if it hasn't been set already but prevent changing it
    assert(!walletInstance->m_chain || walletInstance->m_chain == &chain);
    walletInstance->m_chain = &chain;

    // [ Some logic to ensure a wallet is not used across chains unless the
    //   esoteric -walletcrosschain is set, can skip reading this.. ]
    // Unless allowed, ensure wallet files are not reused across chains:
    if (!gArgs.GetBoolArg("-walletcrosschain", DEFAULT_WALLETCROSSCHAIN)) {
        WalletBatch batch(walletInstance->GetDatabase());
        CBlockLocator locator;
        // [ These checks seem to be enforcing that the wallet has some block
        //   associated with it because it has a best block locator recorded.
        //   I am not sure why we check chain.getHeight(), seems at first like
        //   it would make this cross-chain check fail to stop a user from using
        //   a wallet with another chain in the condition that they haven't
        //   synced any blocks from the other chain yet. ]
        if (batch.ReadBestBlock(locator) && locator.vHave.size() > 0 && chain.getHeight()) {
            // Wallet is assumed to be from another chain, if genesis block in the active
            // chain differs from the genesis block known to the wallet.
            if (chain.getBlockHash(0) != locator.vHave.back()) {
                error = Untranslated("Wallet files should not be reused across chains. Restart bitcoind with -walletcrosschain to override.");
                return false;
            }
        }
    }
    
    // [ This is what we're interested in, chain handles the rest, we just hold
    //   onto the notification handler pointer so that we can destroy it
    //   properly when we need to by invoking m_chain_notifications_handler.reset()]
    walletInstance->m_chain_notifications_handler = walletInstance->chain().handleNotifications(walletInstance); ]
    return true;
}
```

----

```cpp
namespace interfaces {
//! Block data sent with blockConnected, blockDisconnected notifications.
struct BlockInfo {
    const uint256& hash;
    const uint256* prev_hash = nullptr;
    int height = -1;
    int file_number = -1;
    unsigned data_pos = 0;
    const CBlock* data = nullptr;
    const CBlockUndo* undo_data = nullptr;
    // The maximum time in the chain up to and including this block.
    // A timestamp that can only move forward.
    unsigned int chain_time_max{0};

    BlockInfo(const uint256& hash LIFETIMEBOUND) : hash(hash) {}
};
} // namespace interfaces

class Wallet {
    /** Map from txid to CWalletTx for all transactions this wallet is
     * interested in, including received and sent transactions. */
    std::unordered_map<uint256, CWalletTx, SaltedTxidHasher> mapWallet GUARDED_BY(cs_wallet);

    // [ multimap so that we can have multiple entries per key, the value is the
    //   wtxid.. ]
    /**
     * Used to keep track of spent outpoints, and
     * detect and report conflicts (double-spends or
     * mutated transactions where the mutant gets mined).
     */
    typedef std::unordered_multimap<COutPoint, uint256, SaltedOutpointHasher> TxSpends;
    TxSpends mapTxSpends GUARDED_BY(cs_wallet);
    void AddToSpends(const CWalletTx& wtx, WalletBatch* batch = nullptr);
}



void CWallet::blockDisconnected(const interfaces::BlockInfo& block)
{
    // [ There is a CBlock ]
    assert(block.data);
    LOCK(cs_wallet);

    // At block disconnection, this will change an abandoned transaction to
    // be unconfirmed, whether or not the transaction is added back to the mempool.
    // User may have to call abandontransaction again. It may be addressed in the
    // future with a stickier abandoned state or even removing abandontransaction call.
    m_last_block_processed_height = block.height - 1;
    m_last_block_processed = *Assert(block.prev_hash);

    int disconnect_height = block.height;

    // [ For each tx in the disconnected block. ]
    for (const CTransactionRef& ptx : Assert(block.data)->vtx) {
        // [ Big enchalada of the chainstate <--> wallet connection, used in
        //   the blockConnected notification callback as well. ]
        SyncTransaction(ptx, TxStateInactive{});

        // [ Question, why is the below necessary? In particular, why here and
        //   not in `SyncTransaction`, I'll look below. ]
        
        // [ For each vin in this disconnected tx. ] 
        for (const CTxIn& tx_in : ptx->vin) {
            // [ mapTxSpends is inserted into on
            //   `CWallet::AddToSpends(transaction)`, which is done when adding or
            //    loading a transaction into the wallet, the prevout of a CTxIn
            //    is the COutPoint which it spends. ]
            // No other wallet transactions conflicted with this transaction
            if (mapTxSpends.count(tx_in.prevout) < 1) continue;

            // [ I'm still not 100% sure what this logic is dealing with, but it
            //   seems like conflicting transactions involving us (this wallet)?]
            
            // [ Get a range consisting of all transactions in mapTxSpends that
            //   spend the same prevout. ]
            std::pair<TxSpends::const_iterator, TxSpends::const_iterator> range = mapTxSpends.equal_range(tx_in.prevout);

            // For all of the spends that conflict with this transaction
            for (TxSpends::const_iterator _it = range.first; _it != range.second; ++_it) {
                // [ the one true tx lives in mapWallet, the rest live in
                //   mapTxSpends. ]
                CWalletTx& wtx = mapWallet.find(_it->second)->second;

                
                // [ wtx is marked conflicted if there's anything conflicting in
                //   mapTxSpends during AddToWalletIfInvolvingMe, using
                //   CWallet::MarkConflicted(), so in what circumstance could
                //   this ever be true?
                //   Put an asssert here to check that this is sometimes true,
                //   and functional tests caught it, I believe this will be true
                //   one time, when we look at the formerly included tx. ]
                if (!wtx.isBlockConflicted()) continue;

                auto try_updating_state = [&](CWalletTx& tx) {
                    // [ This seems the case if a transaction was the child
                    //   of a transaction which does have a conflict. ]
                    if (!tx.isBlockConflicted()) return TxUpdate::UNCHANGED;
                    // [ We are cutting at or below the height where the
                    //   conflicting tx appears. ]
                    if (tx.state<TxStateBlockConflicted>()->conflicting_block_height >= disconnect_height) {
                        tx.m_state = TxStateInactive{};
                        return TxUpdate::CHANGED;
                    }
                    // [ It is conflicted, but the block with the conflict is
                    //   still connected. ]
                    return TxUpdate::UNCHANGED;
                };

                // [ Do it to a tx and all it's children. ]
                RecursiveUpdateTxState(wtx.tx->GetHash(), try_updating_state);
            }
        }
    }
}
```

### Transaction syncing

```cpp
namespace wallet {
// [ First let's look at the various tx states possible. ]
//! State of transaction confirmed in a block.
struct TxStateConfirmed {
    // [ j
    uint256 confirmed_block_hash;
    int confirmed_block_height;
    int position_in_block;

    explicit TxStateConfirmed(const uint256& block_hash, int height, int index) : confirmed_block_hash(block_hash), confirmed_block_height(height), position_in_block(index) {}
    std::string toString() const { return strprintf("Confirmed (block=%s, height=%i, index=%i)", confirmed_block_hash.ToString(), confirmed_block_height, position_in_block); }
};

//! State of transaction added to mempool.
struct TxStateInMempool {
    std::string toString() const { return strprintf("InMempool"); }
};

//! State of rejected transaction that conflicts with a confirmed block.
struct TxStateBlockConflicted {
    uint256 conflicting_block_hash;
    int conflicting_block_height;

    explicit TxStateBlockConflicted(const uint256& block_hash, int height) : conflicting_block_hash(block_hash), conflicting_block_height(height) {}
    std::string toString() const { return strprintf("BlockConflicted (block=%s, height=%i)", conflicting_block_hash.ToString(), conflicting_block_height); }
};

//! State of transaction not confirmed or conflicting with a known block and
//! not in the mempool. May conflict with the mempool, or with an unknown block,
//! or be abandoned, never broadcast, or rejected from the mempool for another
//! reason.
// [ This has something to do with the crash, I can tell from the description,
//   re: abandoned. ]
struct TxStateInactive {
    bool abandoned;

    explicit TxStateInactive(bool abandoned = false) : abandoned(abandoned) {}
    std::string toString() const { return strprintf("Inactive (abandoned=%i)", abandoned); }
};

//! State of transaction loaded in an unrecognized state with unexpected hash or
//! index values. Treated as inactive (with serialized hash and index values
//! preserved) by default, but may enter another state if transaction is added
//! to the mempool, or confirmed, or abandoned, or found conflicting.
struct TxStateUnrecognized {
    uint256 block_hash;
    int index;

    TxStateUnrecognized(const uint256& block_hash, int index) : block_hash(block_hash), index(index) {}
    std::string toString() const { return strprintf("Unrecognized (block=%s, index=%i)", block_hash.ToString(), index); }
};


//! All possible CWalletTx states
using TxState = std::variant<TxStateConfirmed, TxStateInMempool, TxStateBlockConflicted, TxStateInactive, TxStateUnrecognized>;

//! Subset of states transaction sync logic is implemented to handle.
using SyncTxState = std::variant<TxStateConfirmed, TxStateInMempool, TxStateInactive>;

// [ Really just a wrapper for `AddToWalletIfInvolvingMe()` ]
void CWallet::SyncTransaction(const CTransactionRef& ptx, const SyncTxState& state, bool update_tx, bool rescanning_old_block)
{
    if (!AddToWalletIfInvolvingMe(ptx, state, update_tx, rescanning_old_block))
        return; // Not one of ours

    // If a transaction changes 'conflicted' state, that changes the balance
    // available of the outputs it spends. So force those to be
    // recomputed, also:
    MarkInputsDirty(ptx);
}

bool CWallet::AddToWalletIfInvolvingMe(const CTransactionRef& ptx, const SyncTxState& state, bool fUpdate, bool rescanning_old_block)
{
    const CTransaction& tx = *ptx;
    {
        AssertLockHeld(cs_wallet);

        // [ If we're adding a confirmed tx to the wallet... ]
        if (auto* conf = std::get_if<TxStateConfirmed>(&state)) {
            // [ iterate each vin ]
            for (const CTxIn& txin : tx.vin) {
                // [ Get all tx'es in our wallet that spend this vout. as a
                //   reminder, TxSpends multimaps COutpoints to uint256 wtxid's, as
                //   conflicting transactions might spend the same coutpoint,
                //   but if they are different, will have different wtxid's. ]
                std::pair<TxSpends::const_iterator, TxSpends::const_iterator> range = mapTxSpends.equal_range(txin.prevout);
                // [ range.first == range.second if there are no conflicts, only
                //   zero or one tx that spends this vin. ]
                while (range.first != range.second) {
                    // [ if the wtxid of the matching coutpoint is not equal to
                    //   the transaction we're adding to the wallet... (there's
                    //   a conflict... ]
                    if (range.first->second != tx.GetHash()) {
                        // [ not a warning, just informative, reasonably
                        //   expected when e.g. rbf'ing. ]
                        WalletLogPrintf("Transaction %s (in block %s) conflicts with wallet transaction %s (both spend %s:%i)\n", tx.GetHash().ToString(), conf->confirmed_block_hash.ToString(), range.first->second.ToString(), range.first->first.hash.ToString(), range.first->first.n);
                        // [ mark the block where the conflicting tx appears,
                        //   hash height, he
                        MarkConflicted(conf->confirmed_block_hash, conf->confirmed_block_height, range.first->second);
                    }
                    range.first++;
                }
            }
        }

        bool fExisted = mapWallet.count(tx.GetHash()) != 0;
        if (fExisted && !fUpdate) return false;
        if (fExisted || IsMine(tx) || IsFromMe(tx))
        {
            /* Check if any keys in the wallet keypool that were supposed to be unused
             * have appeared in a new transaction. If so, remove those keys from the keypool.
             * This can happen when restoring an old wallet backup that does not contain
             * the mostly recently created transactions from newer versions of the wallet.
             */

            // loop though all outputs
            for (const CTxOut& txout: tx.vout) {
                for (const auto& spk_man : GetScriptPubKeyMans(txout.scriptPubKey)) {
                    for (auto &dest : spk_man->MarkUnusedAddresses(txout.scriptPubKey)) {
                        // If internal flag is not defined try to infer it from the ScriptPubKeyMan
                        if (!dest.internal.has_value()) {
                            dest.internal = IsInternalScriptPubKeyMan(spk_man);
                        }

                        // skip if can't determine whether it's a receiving address or not
                        if (!dest.internal.has_value()) continue;

                        // If this is a receiving address and it's not in the address book yet
                        // (e.g. it wasn't generated on this node or we're restoring from backup)
                        // add it to the address book for proper transaction accounting
                        if (!*dest.internal && !FindAddressBookEntry(dest.dest, /* allow_change= */ false)) {
                            SetAddressBook(dest.dest, "", AddressPurpose::RECEIVE);
                        }
                    }
                }
            }

            // Block disconnection override an abandoned tx as unconfirmed
            // which means user may have to call abandontransaction again
            TxState tx_state = std::visit([](auto&& s) -> TxState { return s; }, state);
            CWalletTx* wtx = AddToWallet(MakeTransactionRef(tx), tx_state, /*update_wtx=*/nullptr, /*fFlushOnClose=*/false, rescanning_old_block);
            if (!wtx) {
                // Can only be nullptr if there was a db write error (missing db, read-only db or a db engine internal writing error).
                // As we only store arriving transaction in this process, and we don't want an inconsistent state, let's throw an error.
                throw std::runtime_error("DB error adding transaction to wallet, write failed");
            }
            return true;
        }
    }
    return false;
}

```
