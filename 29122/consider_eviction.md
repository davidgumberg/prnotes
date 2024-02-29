## Annotated `PeerManagerImpl::ConsiderEviction`
- Acquire peer node State

```cpp
void PeerManagerImpl::ConsiderEviction(CNode& pto, Peer& peer, std::chrono::seconds time_in_seconds)
{
    AssertLockHeld(cs_main);

    // Get the CNodeState of our node.
    CNodeState &state = *State(pto.GetId());

    /* From struct CNodeState 
     * Any peer protected (m_protect = true) is not chosen for eviction. A peer is
     * marked as protected if all of these are true:
     *   - its connection type is IsBlockOnlyConn() == false
     *   - it gave us a valid connecting header
     *   - we haven't reached MAX_OUTBOUND_PEERS_TO_PROTECT_FROM_DISCONNECT yet
     *   - its chain tip has at least as much work as ours
     */
    if (!state.m_chain_sync.m_protect && pto.IsOutboundOrBlockRelayConn() && state.fSyncStarted) {
        // This is an outbound peer subject to disconnection if they don't
        // announce a block with as much work as the current tip within
        // CHAIN_SYNC_TIMEOUT + HEADERS_RESPONSE_TIME seconds (note: if
        // their chain has more work than ours, we should sync to it,
        // unless it's invalid, in which case we should find that out and
        // disconnect from them elsewhere).
        if (state.pindexBestKnownBlock != nullptr && state.pindexBestKnownBlock->nChainWork >= m_chainman.ActiveChain().Tip()->nChainWork) {
            // The outbound peer has sent us a block with at least as much work as our current tip, so reset the timeout if it was set
            if (state.m_chain_sync.m_timeout != 0s) {
                state.m_chain_sync.m_timeout = 0s;
                state.m_chain_sync.m_work_header = nullptr;
                state.m_chain_sync.m_sent_getheaders = false;
            }
        } else if (state.m_chain_sync.m_timeout == 0s || (state.m_chain_sync.m_work_header != nullptr && state.pindexBestKnownBlock != nullptr && state.pindexBestKnownBlock->nChainWork >= state.m_chain_sync.m_work_header->nChainWork)) {
            // At this point we know that the outbound peer has either never sent us a block/header or they have, but its tip is behind ours
            // AND
            // we are noticing this for the first time (m_timeout is 0)
            // OR we noticed this at some point within the last CHAIN_SYNC_TIMEOUT + HEADERS_RESPONSE_TIME seconds and set a timeout
            // for them, they caught up to our tip at the time of setting the timer but not to our current one (we've also advanced).
            // Either way, set a new timeout based on our current tip.
            state.m_chain_sync.m_timeout = time_in_seconds + CHAIN_SYNC_TIMEOUT;
            state.m_chain_sync.m_work_header = m_chainman.ActiveChain().Tip();
            state.m_chain_sync.m_sent_getheaders = false;
        } else if (state.m_chain_sync.m_timeout > 0s && time_in_seconds > state.m_chain_sync.m_timeout) {
            // No evidence yet that our peer has synced to a chain with work equal to that
            // of our tip, when we first detected it was behind. Send a single getheaders
            // message to give the peer a chance to update us.
            if (state.m_chain_sync.m_sent_getheaders) {
                // They've run out of time to catch up!
                LogPrintf("Disconnecting outbound peer %d for old chain, best known block = %s\n", pto.GetId(), state.pindexBestKnownBlock != nullptr ? state.pindexBestKnownBlock->GetBlockHash().ToString() : "<none>");
                pto.fDisconnect = true;
            } else {
                assert(state.m_chain_sync.m_work_header);
                // Here, we assume that the getheaders message goes out,
                // because it'll either go out or be skipped because of a
                // getheaders in-flight already, in which case the peer should
                // still respond to us with a sufficiently high work chain tip.
                MaybeSendGetHeaders(pto,
                        GetLocator(state.m_chain_sync.m_work_header->pprev),
                        peer);
                LogPrint(BCLog::NET, "sending getheaders to outbound peer=%d to verify chain work (current best known block:%s, benchmark blockhash: %s)\n", pto.GetId(), state.pindexBestKnownBlock != nullptr ? state.pindexBestKnownBlock->GetBlockHash().ToString() : "<none>", state.m_chain_sync.m_work_header->GetBlockHash().ToString());
                state.m_chain_sync.m_sent_getheaders = true;
                // Bump the timeout to allow a response, which could clear the timeout
                // (if the response shows the peer has synced), reset the timeout (if
                // the peer syncs to the required work but not to our tip), or result
                // in disconnect (if we advance to the timeout and pindexBestKnownBlock
                // has not sufficiently progressed)
                state.m_chain_sync.m_timeout = time_in_seconds + HEADERS_RESPONSE_TIME;
            }
        }
    }
}
```
