# Block Connection 

## `Chainstate::ConnectTip`

<details>


<summary>

`Chainstate:ConnectTip()` annotated

</summary>


```cpp
/**
 * Connect a new block to m_chain. pblock is either nullptr or a pointer to a CBlock
 * corresponding to pindexNew, to bypass loading it again from disk.
 *
 * The block is added to connectTrace if connection succeeds.
 */
bool Chainstate::ConnectTip(BlockValidationState& state, CBlockIndex* pindexNew, const std::shared_ptr<const CBlock>& pblock, ConnectTrace& connectTrace, DisconnectedBlockTransactions& disconnectpool)
{
    AssertLockHeld(cs_main);
    if (m_mempool) AssertLockHeld(m_mempool->cs);

    assert(pindexNew->pprev == m_chain.Tip());
    // Read block from disk.
    const auto time_1{SteadyClock::now()};
    std::shared_ptr<const CBlock> pthisBlock;
    if (!pblock) {
        std::shared_ptr<CBlock> pblockNew = std::make_shared<CBlock>();
        if (!m_blockman.ReadBlockFromDisk(*pblockNew, *pindexNew)) {
            return FatalError(m_chainman.GetNotifications(), state, _("Failed to read block."));
        }
        pthisBlock = pblockNew;
    } else {
        LogPrint(BCLog::BENCH, "  - Using cached block\n");
        pthisBlock = pblock;
    }
    const CBlock& blockConnecting = *pthisBlock;
    // Apply the block atomically to the chain state.
    const auto time_2{SteadyClock::now()};
    SteadyClock::time_point time_3;
    // When adding aggregate statistics in the future, keep in mind that
    // num_blocks_total may be zero until the ConnectBlock() call below.
    LogPrint(BCLog::BENCH, "  - Load block from disk: %.2fms\n",
             Ticks<MillisecondsDouble>(time_2 - time_1));
    {
        CCoinsViewCache view(&CoinsTip());
        bool rv = ConnectBlock(blockConnecting, state, pindexNew, view);
        if (m_chainman.m_options.signals) {
            m_chainman.m_options.signals->BlockChecked(blockConnecting, state);
        }
        if (!rv) {
            if (state.IsInvalid())
                InvalidBlockFound(pindexNew, state);
            LogError("%s: ConnectBlock %s failed, %s\n", __func__, pindexNew->GetBlockHash().ToString(), state.ToString());
            return false;
        }
        time_3 = SteadyClock::now();
        m_chainman.time_connect_total += time_3 - time_2;
        assert(m_chainman.num_blocks_total > 0);
        LogPrint(BCLog::BENCH, "  - Connect total: %.2fms [%.2fs (%.2fms/blk)]\n",
                 Ticks<MillisecondsDouble>(time_3 - time_2),
                 Ticks<SecondsDouble>(m_chainman.time_connect_total),
                 Ticks<MillisecondsDouble>(m_chainman.time_connect_total) / m_chainman.num_blocks_total);
        bool flushed = view.Flush();
        assert(flushed);
    }
    const auto time_4{SteadyClock::now()};
    m_chainman.time_flush += time_4 - time_3;
    LogPrint(BCLog::BENCH, "  - Flush: %.2fms [%.2fs (%.2fms/blk)]\n",
             Ticks<MillisecondsDouble>(time_4 - time_3),
             Ticks<SecondsDouble>(m_chainman.time_flush),
             Ticks<MillisecondsDouble>(m_chainman.time_flush) / m_chainman.num_blocks_total);
    // Write the chain state to disk, if necessary.
    if (!FlushStateToDisk(state, FlushStateMode::IF_NEEDED)) {
        return false;
    }
    const auto time_5{SteadyClock::now()};
    m_chainman.time_chainstate += time_5 - time_4;
    LogPrint(BCLog::BENCH, "  - Writing chainstate: %.2fms [%.2fs (%.2fms/blk)]\n",
             Ticks<MillisecondsDouble>(time_5 - time_4),
             Ticks<SecondsDouble>(m_chainman.time_chainstate),
             Ticks<MillisecondsDouble>(m_chainman.time_chainstate) / m_chainman.num_blocks_total);
    // Remove conflicting transactions from the mempool.;
    if (m_mempool) {
        m_mempool->removeForBlock(blockConnecting.vtx, pindexNew->nHeight);
        disconnectpool.removeForBlock(blockConnecting.vtx);
    }
    // Update m_chain & related variables.
    m_chain.SetTip(*pindexNew);
    UpdateTip(pindexNew);

    const auto time_6{SteadyClock::now()};
    m_chainman.time_post_connect += time_6 - time_5;
    m_chainman.time_total += time_6 - time_1;
    LogPrint(BCLog::BENCH, "  - Connect postprocess: %.2fms [%.2fs (%.2fms/blk)]\n",
             Ticks<MillisecondsDouble>(time_6 - time_5),
             Ticks<SecondsDouble>(m_chainman.time_post_connect),
             Ticks<MillisecondsDouble>(m_chainman.time_post_connect) / m_chainman.num_blocks_total);
    LogPrint(BCLog::BENCH, "- Connect block: %.2fms [%.2fs (%.2fms/blk)]\n",
             Ticks<MillisecondsDouble>(time_6 - time_1),
             Ticks<SecondsDouble>(m_chainman.time_total),
             Ticks<MillisecondsDouble>(m_chainman.time_total) / m_chainman.num_blocks_total);

    // If we are the background validation chainstate, check to see if we are done
    // validating the snapshot (i.e. our tip has reached the snapshot's base block).
    if (this != &m_chainman.ActiveChainstate()) {
        // This call may set `m_disabled`, which is referenced immediately afterwards in
        // ActivateBestChain, so that we stop connecting blocks past the snapshot base.
        m_chainman.MaybeCompleteSnapshotValidation();
    }

    connectTrace.BlockConnected(pindexNew, std::move(pthisBlock));
    return true;
}
```


</details>


## `Chainstate::ConnectBlock`

<details>


<summary>

`Chainstate::ConnectBlock()` annotated

</summary>


```cpp

```


</details>


