# `CWallet::blockConnected(ChainstateRole role, const interfaces::BlockInfo& block)`

Whenever a block gets connected (`Chainstate::ActivateBestChain()`) the block
connected signal (`ValidationSignals::BlockConnected()`) is emitted. Subscribers
to validation and mempool signals like BlockConnected implement a
`CValidationInterface`[^1]. It once was the case
([9a1675ee5b2](https://github.com/bitcoin/bitcoin/blob/9a1675ee5b27f8634f9917a1f80904c9319739d3/src/wallet/wallet.h#L651))
that `CWallet` itself implemented `CValidationInterface`:

```cpp
class CWallet final : public CCryptoKeyStore, public CValidationInterface
{
    void BlockConnected(const std::shared_ptr<const CBlock>& pblock, const CBlockIndex *pindex, const std::vector<CTransactionRef>& vtxConflicted) override;
    void BlockDisconnected(const std::shared_ptr<const CBlock>& pblock) override;
    // [...]
};
```

But as part of refactoring to make the wallet more independent and less reliant
on global state, this was changed in
[#10973](https://github.com/bitcoin/bitcoin/pull/10973) to make the wallet use
`class node::Chain::Notifications` which describes a minimal interface that one
can pass to `node::Chain::handleNotifications()` which will take care of
constructing and registering a a `NotificationsHandlerImpl` with a
`NotificationsProxy` object `NotificationsHandlerImpl::m_proxy` that contains
the callback functions that will be invoked when signals are emmitted.

`class NotificationsProxy : public CValidationInterface` holds onto a
`node::Chain::Notifications` pointer and wraps calls, sometimes simplifying the
`ValidationSignals`/`CValidationInterface` interface to the `node::Chain::Notifications`
one, e.g.:

```cpp
// [ src/validationinterface.h ]
class CValidationInterface {
protected:
    /**
     * Notifies listeners of a block being connected.
     * Provides a vector of transactions evicted from the mempool as a result.
     *
     * Called on a background thread.
     */
    virtual void BlockConnected(ChainstateRole role, const std::shared_ptr<const CBlock> &block, const CBlockIndex *pindex) {}
};

// [ interfaces/chain.h ]
namespace interfaces {
class Chain
{
public:
    class Notifications
    {
    public:
        virtual void blockConnected(ChainstateRole role, const BlockInfo& block) {}
    };
};
} // namespace interfaces

// [ src/node/interfaces.cpp ]
class NotificationsProxy : public CValidationInterface
{
public:
    explicit NotificationsProxy(std::shared_ptr<Chain::Notifications> notifications)
        : m_notifications(std::move(notifications)) {}

    // [ BlockConnected takes a ChainstateRole (normal/assumedvalid/background),
    //   CBlock, and CBlockIndex*, and translates that to
    //   Notifications::blockConnected() which takes a BlockInfo ]
    void BlockConnected(ChainstateRole role, const std::shared_ptr<const CBlock>& block, const CBlockIndex* index) override
    {
        m_notifications->blockConnected(role, kernel::MakeBlockInfo(index, block.get()));
    }
};
```

<details>


<summary>

`CWallet::blockConnected()` annotated

</summary>


```cpp
void CWallet::blockConnected(ChainstateRole role, const interfaces::BlockInfo& block)
{
    if (role == ChainstateRole::BACKGROUND) {
        return;
    }
    assert(block.data);
    LOCK(cs_wallet);

    // Update the best block first. This will set the best block's height, which is
    // needed by MarkConflicted.
    // Although this also writes the best block to disk, this is okay even if there is an unclean
    // shutdown since reloading the wallet will still rescan this block.
    SetBestBlock(block.height, block.hash);

    // No need to scan block if it was created before the wallet birthday.
    // Uses chain max time and twice the grace period to adjust time for block time variability.
    if (block.chain_time_max < m_birth_time.load() - (TIMESTAMP_WINDOW * 2)) return;

    // Scan block
    for (size_t index = 0; index < block.data->vtx.size(); index++) {
        SyncTransaction(block.data->vtx[index], TxStateConfirmed{block.hash, block.height, static_cast<int>(index)});
        transactionRemovedFromMempool(block.data->vtx[index], MemPoolRemovalReason::BLOCK);
    }
}
```

</details>

[^1]: Notably once named `CWalletInterface` ([#5105](https://github.com/bitcoin/bitcoin/pull/5105)
