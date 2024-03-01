# PeerManagerImpl::ConsiderEviction

## Description
1. Acquire the peer's `CNodeState`
2. If it is not one of the four peers protected from eviction, and it is a full outbound or blockrelay connection (no inbound, manual or feelers)
    <details>
        <summary>Protected Peers</summary>
        - What qualifies a protected peer?
            - Not queued for eviction.
                - `!pfrom.fDisconnect`
            - Is a full outbound connection (no block only peers)
                - `m_conn_type == ConnectionType::OUTBOUND_FULL_RELAY`
            - Has a chain tip with at least as much work as ours
                - `nodestate->pindexBestKnownBlock->nChainWork >= m_chainman.ActiveChain().Tip()->nChainWork`
            - Nominated when we had fewer than four protected peers 
                ```cpp
                static constexpr int32_t MAX_OUTBOUND_PEERS_TO_PROTECT_FROM_DISCONNECT = 4;
                m_outbound_peers_with_protect_from_disconnect < MAX_OUTBOUND_PEERS_TO_PROTECT_FROM_DISCONNECT`
                ```
            - Nominated by sending us a valid header that triggered an `UpdatePeerStateForReceivedHeaders`
                ```cpp
                if (!pfrom.fDisconnect && pfrom.IsFullOutboundConn() && nodestate->pindexBestKnownBlock != nullptr) {
                    if (m_outbound_peers_with_protect_from_disconnect < MAX_OUTBOUND_PEERS_TO_PROTECT_FROM_DISCONNECT && nodestate->pindexBestKnownBlock->nChainWork >= m_chainman.ActiveChain().Tip()->nChainWork && !nodestate->m_chain_sync.m_protect) {
                        LogPrint(BCLog::NET, "Protecting outbound peer=%d from eviction\n", pfrom.GetId());
                        nodestate->m_chain_sync.m_protect = true;
                        ++m_outbound_peers_with_protect_from_disconnect;
                    }
                }
                ```
        - *Why* do we protect 4 peers from eviction?
            - The motivation is a bit unclear: outbound peer eviction was introduced in [#11490](https://github.com/bitcoin/bitcoin/pull/11490)
            - "We protect 4 of our outbound peers (who provide some "good" headers chains, ie a chain with at least as much work as our tip at some point)
              from being subject to this logic, to prevent excessive network topology changes as a result of this algorithm, while still ensuring that we
              have a reasonable number of nodes not known to be on bogus chains.
    </details>

3. If the peer has sent us a block with at least much work as our current tip, reset their `m_chain_sync.timeout`
4. Otherwise, they have not sent us a tip with at least as much work as ours, **now** if
    - we are noticing for the first time (`m_timeout ==  0`)
    - OR
    - they have caught up to the tip we were at when we set the timer
        - `state.pindexBestKnownBlock->nChainWork >= state.m_chain_sync.m_work_header->nChainWork)`
    - **THEN**
        - Set a timeout for `time.now() + CHAIN_SYNC_TIMEOUT` (20 minutes at present)
        - Record our tip at the time we set this timer
5. Otherwise, if they have a timeout set and we have passed the timeout deadline
    - If we have already given them **one last chance** (`if (state.m_chain_sync.m_sent_getheaders)`)
        - `pto.fDisconnect = true;`
    - Otherwise, as a last-ditch effort, send them a `getheaders` message
        - Set `state.m_chain_sync.m_sent_getheaders = true` to flag that we've given them one last chance
        - Set `state.m_chain_sync.m_timeout` equal to `time.now() + HEADERS_RESPONSE_TIME` (2 minutes)

## Annotated `PeerManagerImpl::ConsiderEviction`
[] in comments indicate my notes
```cpp
/* [CNode and Peer both describe our peer that we are considering for eviction.
 * The distinction was added in (#19607)[https://github.com/bitcoin/bitcoin/pull/19607]
 * jnewbery says: 
 *      CNode in net.h, which should just contain connection layer data (eg socket, send/recv buffers, etc), but currently also contains some application layer data (eg tx/block inventory).
        Peer, which is for p2p application layer data, and doesn't require cs_main.
        CNodeState in net processing, which contains p2p application layer data, but requires cs_main to be locked for access
 * it seems the main bit of application layer data still managed by CNode is eviction!]
 */

        

void PeerManagerImpl::ConsiderEviction(CNode& pto, Peer& peer, std::chrono::seconds time_in_seconds)
{
    AssertLockHeld(cs_main);

    // [Get the CNodeState of our peer, validation critical so protected by cs_main ]
    CNodeState &state = *State(pto.GetId());

    /* [From struct CNodeState:
     * "Any peer protected (m_protect = true) is not chosen for eviction. A peer is
     * marked as protected if all of these are true:
     *   - its connection type is IsBlockOnlyConn() == false
     *   - it gave us a valid connecting header
     *   - we haven't reached MAX_OUTBOUND_PEERS_TO_PROTECT_FROM_DISCONNECT yet
     *   - its chain tip has at least as much work as ours"]
     */

    // [If not protected, if full outbound or block relay connection]
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
            // [ if we've already given the peer a last chance ]
            if (state.m_chain_sync.m_sent_getheaders) {
                // They've run out of time to catch up!
                LogPrintf("Disconnecting outbound peer %d for old chain, best known block = %s\n", pto.GetId(), state.pindexBestKnownBlock != nullptr ? state.pindexBestKnownBlock->GetBlockHash().ToString() : "<none>");
                // [ eviction! ]
                pto.fDisconnect = true;
            } else {
                assert(state.m_chain_sync.m_work_header);
                // Here, we assume that the getheaders message goes out,
                // because it'll either go out or be skipped because of a
                // getheaders in-flight already, in which case the peer should
                // still respond to us with a sufficiently high work chain tip.
                MaybeSendGetHeaders(pto,
                        // [ We send getheader with the locator set to one before the best known tip
                        //   when we set the timeout so they will send us that best known tip if they
                        //   have it:
                        //     "getheaders
                        //      Return a headers packet containing the headers of blocks starting right after the last known hash in the block locator object"
                        //      from btc wiki
                        // ]
                        GetLocator(state.m_chain_sync.m_work_header->pprev),
                        peer);
                LogPrint(BCLog::NET, "sending getheaders to outbound peer=%d to verify chain work (current best known block:%s, benchmark blockhash: %s)\n", pto.GetId(), state.pindexBestKnownBlock != nullptr ? state.pindexBestKnownBlock->GetBlockHash().ToString() : "<none>", state.m_chain_sync.m_work_header->GetBlockHash().ToString());
                state.m_chain_sync.m_sent_getheaders = true;
                // Bump the timeout to allow a response, which could clear the timeout
                // (if the response shows the peer has synced), reset the timeout (if
                // the peer syncs to the required work but not to our tip), or result
                // in disconnect (if we advance to the timeout and pindexBestKnownBlock
                // has not sufficiently progressed)
                // [ Give 'em 2 minutes to respond to our getheaders ]
                state.m_chain_sync.m_timeout = time_in_seconds + HEADERS_RESPONSE_TIME;
            }
        }
    }
}
```
