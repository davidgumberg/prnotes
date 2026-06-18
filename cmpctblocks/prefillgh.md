> LLM Disclosure: LLMs were used frequently as a research tool while investigating this topic, but no code or text in this PR was generated with an LLM.

This is an implementation based on 0xB10C's [proposal][proposal] and [implementation][implementation] of prefilling CMPCTBLOCK messages with what we[^1] needed during CMPCTBLOCK reconstruction in the hopes of providing everything our peers will need to reconstruct without having to ask us for transactions.

Although full support for receiving prefills is [implemented][cb-og-pr] in Bitcoin Core, the only prefills sent presently are coinbases. The goal of prefilling is to improve compact block reconstruction rates, which reduces the number of roundtrips needed to propagate blocks per-hop, which reduces the amount of time needed for blocks to propagate on the network, which mitigates selfish mining attacks by lowering the stale rate and the ratio $γ$ of honest miners a selfish miner is able to recruit in a block race.[^2] The tradeoff of prefilling is that it uses a small amount of extra bandwidth and makes propagation slightly worse when the predictions are bad.

My primary contribution is limiting the prefill based on the connection's TCP window. Exceeding the boundary of the current TCP window will result in a ~[roundtrip][roundtrip] at the network layer,[^3] and any time a roundtrip is going to be incurred anyways, it would be [better][better] to let our peer tell us exactly what they are missing in a roundtrip instead of hazarding a guess, which risks sending redundant information.[^4]

## Prefill do

In measurements I took from 2026-02-15 to 2026-03-16, a node receiving prefilled `CMPCTBLOCK`s limited to the TCP window size was able to reconstruct 89.7% of compact blocks received without a GETBLOCKTXN roundtrip, and a node receiving typical `CMPCTBLOCK`s with only coinbases prefilled was able to reconstruct 56.9% of blocks received without a GETBLOCKTXN roundtrip.[^5]

The mean prefill sent was 1,694.64 bytes and the median was 897 bytes. If all the bytes of every prefill were redundant [^6], the cost of prefilling 1,694.64 bytes would be 1.39 MiB per node in wasted bandwidth per day (counting both the sending and the receiving bandwidth for all 3 HB peers).

## Prefill why

There are changes that are likely more effective at improving propagation times than prefilling, for example:
- [Using a sketch instead of shortids][sketch-shortid] in CMPCTBLOCK messages
- Using a UDP connection with FEC as [the FIBRE project does][the-fibre-project-does]
- Sharing [block templates][block-templates]

The advantage of this approach is that it requires no protocol changes and is entirely backwards compatible with existing node software that has implemented the `CMPCTBLOCK` [protocol][protocol]. Concretely: An old version of Bitcoin Core that knows nothing about this PR can enjoy faster block reconstructions if it connects to a peer that prefills blocks. I think these benefits are worth the tradeoff of violating the layer cake and taking transport matters into our own hands.

## Prefill what

- The transactions which we were missing during reconstruction and received in a `GETBLOCKTXN->BLOCKTXN` round trip with our peer.
- The transactions which were pulled from our extrapool during reconstruction.[^7]
- Any transactions that were prefilled to us that we didn't already have in our mempool.

The reasons to like this heuristic are that it's simple, per-block rather than per-peer, makes sense on paper, and seems to be effective in practice.

## Prefill when

To avoid having to generate unique CMPCTBLOCK messages for each of our peers, which might be costly[^8], we (lazily[^9]) build and cache 2 CMPCTBLOCK messages: one prefilled and one not prefilled.

At sending time we check the available bytes in our peer's TCP window, and if the total number of TCP windows occupied by the prefilled block is equal to the total number of windows occupied by the nonprefilled block, then we send the prefilled block.

----

## TCP Windows

Discussed in greater detail [elsewhere][elsewhere], I'll try to summarize here:

In [RFC 793][rfc-793], TCP was specified with receiver advertised window sizes because receivers allocate some buffer size to a given TCP connection, and this receiver advertised window represents the most **unacknowledged** data a receiver will process before dropping bytes on the ground or something awful like that. So the sender of a message over a TCP connection will only send up to the last acknowledged byte + the receiver's advertised window size in order to avoid filling up their peer's receive buffer.

It was later discovered that TCP was susceptible to ["congestion collapse"][congestion-collapse], which can probably describe any congestion feedback loop but in TCP is where packets being dropped due to congestion results in retransmissions that cause even more congestion. TCP implementers addressed this with "congestion control" algorithms which decide on the sending side to limit the number of bytes to send dynamically, based on how frequently packets are dropped on a TCP connection. For a more concrete account of various congestion control algorithms see [RFC 5681][rfc-5681]. A user's TCP implementation (typically in their OS kernel) will compute a window size dynamically for each TCP connection usually increasing as packets sent are ACKnowledged and decreasing when packets sent are dropped.

Computed congestion control window sizes vary:
- per-connection
- over connection lifetime
- with the congestion control algorithm used by the system TCP implementation
- with user configuration of the TCP implementation.

There is not likely to be any way to guess or predict what the TCP window will be very effectively, and we must query the TCP implementation in order to learn what our connection window sizes are.

The usable window size is the smaller of the receiver advertised window and the sender computed congestion control window, but in practice the congestion control window is far smaller. In my observation node, the mean Bitcoin P2P congestion window observed was 17,360.52 bytes and the median was 14,480 bytes.

[^1]: 'We' refers to the Royal Node.
[^2]: (2013) Eyal and Sirer *Majority is not Enough* (pg. 8) https://arxiv.org/pdf/1311.0243 The claim that lowering block propagation times lowers γ probably needs serious analysis, but my hand-waving argument is that the faster public network-wide block propagation is, the more expensive any proportional propagation time advantage over the public network becomes, and γ is a function of propagation time advantage.
[^3]: A network layer roundtrip will be faster than an application layer roundtrip, although probably not by much for most connections. Since at the application layer there will be some time your message spends waiting to be processed by your peer, at least for peers that use single-threaded message processing like Bitcoin Core does presently.
[^4]: In practice exceeding the TCP window is ~not quite as bad as I've implied here and in the delving post: because the window is sliding, once the first 1.5 round-trips are completed there is a continuous stream as ACKnowledgements for the oldest segments arrive and the newest segments are fired out. The effect of this more precisely is that if a message exceeds a window boundary, the minimum travel time of the message becomes 1.5 round-trip-time (RTT) instead of 0.5 RTT and the throughput limit of the connection becomes $\text{window size} / \text{RTT}$. I am working on a more complete write-up that takes this more precise cost into consideration, but I think approximating it as a ~round trip is reasonable.
[^5]: In reality, not all of the prefill is redundant otherwise prefilling would not be very useful. In my observation node that received prefilled compact blocks, the mean redundant prefill bytes was 865.62 bytes/block. 2 HB announcements will always be redundant so: 1.17 MiB per node in wasted bandwidth per day if one CMPCTBLOCK announcement only has 865.62 redundant bytes.
[^6]: I will share a write-up describing my full experimental setup and data soon. It was mostly identical to the set up described here: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/34 I had one node running a prefilling branch, and another node set up to only receive CMPCTBLOCK messages from the prefilling node. My infrastructure as code observation set up: https://github.com/davidgumberg/prefill-research and the script I used to analyze the results: https://radicle.network/nodes/iris.radicle.network/rad:z37pH1UAxFvazXnfAMS5qbcUjQaP6/tree/leave/scripts/prefill.py
[^7]: The reason to pluck from the extrapool is because it is very likely to differ between nodes.
[^8]: But maybe there is some cost here that is worth trading off, it's not something I've explored.
[^9]: This is based on andrewtoth's #26755.

[proposal]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/24
[cb-og-pr]: https://github.com/bitcoin/bitcoin/pull/8068
[sketch-shortid]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/30
[the-fibre-project-does]: https://github.com/bitcoinfibre/bitcoinfibre/blob/master/src/udprelay.cpp
[roundtrip]: https://en.wikipedia.org/wiki/TCP_window_scale_option#TCP_windows
[better]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/34
[rfc-793]: https://www.rfc-editor.org/rfc/rfc793.html#section-2.6
[elsewhere]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/34
[congestion-collapse]: https://dl.acm.org/doi/epdf/10.1145/52325.52356
[rfc-5681]: https://datatracker.ietf.org/doc/html/rfc5681
[block-templates]: https://delvingbitcoin.org/t/sharing-block-templates/1906
[implementation]: https://github.com/0xB10C/bitcoin/tree/2025-03-prefill-cmpctblocks
[protocol]: https://github.com/bitcoin/bips/blob/master/bip-0152.mediawiki
