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

T

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

    for (const CTransactionRef& ptx : Assert(block.data)->vtx) {
        // [ Big enchalada of the chainstate <--> wallet connection, used in
        //   the blockConnected notification callback as well. ]
        SyncTransaction(ptx, TxStateInactive{});

        for (const CTxIn& tx_in : ptx->vin) {
            // No other wallet transactions conflicted with this transaction
            if (mapTxSpends.count(tx_in.prevout) < 1) continue;

            std::pair<TxSpends::const_iterator, TxSpends::const_iterator> range = mapTxSpends.equal_range(tx_in.prevout);

            // For all of the spends that conflict with this transaction
            for (TxSpends::const_iterator _it = range.first; _it != range.second; ++_it) {
                CWalletTx& wtx = mapWallet.find(_it->second)->second;

                if (!wtx.isBlockConflicted()) continue;

                auto try_updating_state = [&](CWalletTx& tx) {
                    if (!tx.isBlockConflicted()) return TxUpdate::UNCHANGED;
                    if (tx.state<TxStateBlockConflicted>()->conflicting_block_height >= disconnect_height) {
                        tx.m_state = TxStateInactive{};
                        return TxUpdate::CHANGED;
                    }
                    return TxUpdate::UNCHANGED;
                };

                RecursiveUpdateTxState(wtx.tx->GetHash(), try_updating_state);
            }
        }
    }
}


void CWallet::SyncTransaction(const CTransactionRef& ptx, const SyncTxState& state, bool update_tx, bool rescanning_old_block)
{
    if (!AddToWalletIfInvolvingMe(ptx, state, update_tx, rescanning_old_block))
        return; // Not one of ours

    // If a transaction changes 'conflicted' state, that changes the balance
    // available of the outputs it spends. So force those to be
    // recomputed, also:
    MarkInputsDirty(ptx);
}

```
