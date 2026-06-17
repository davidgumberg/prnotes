LLM Disclosure: LLM's were used frequently as a research tool while
investigating this topic, but no code or text in this PR were generated with an
LLM.

*'We' refers to the Royal Node.*

This is an implementation of 0xB10C's [proposal][proposal] to prefill CMPCTBLOCK
messages based on what we needed during CMPCTBLOCK reconstruction in order to
avoid a `GETBLOCKTXN` roundtrip for reconstruction to succeed. The goal is to
reduce the number of roundtrips needed to reconstruct blocks in order to speed
up block propagation, at the cost of a small amount of additional bandwidth.

In measurements I took from 2026-02-15 to 2026-03-16, a node receiving prefilled
`CMPCTBLOCK`s limited to the TCP window size was able to reconstruct 89.7% of
compact blocks received without a GETBLOCKTXN roundtrip, and a node receiving
typical `CMPCTBLOCK`s was only able to reconstruct 56.9% of blocks received
without a GETBLOCKTXN roundtrip.[^3]

Note that there are larger improvements to the `CMPCTBLOCK` protocol or to node
software that can improve propagation times even more, for example:
- [Using a sketch instead of shortid's][sketch-shortid]
- Using a UDP connection with FEC as [the FIBRE project
does][the-fibre-project-does],
- Sharing [block templates][block-templates]

The advantage of this approach is that it requires no protocol changes and is
entirely backwards compatible with existing nodes that have implemented the
`CMPCTBLOCK` protocol. Concretely: An old version of Bitcoin Core that knows
nothing about this PR might enjoy faster block reconstructions if it connects to
a peer that prefills blocks. I think these benefits are worth the tradeoff of
violating the transport layer and taking matters into our own hands.

This work is largely derived from 0xB10C's implementation:
https://github.com/0xB10C/bitcoin/tree/2025-03-prefill-cmpctblocks

My primary contribution is limiting the prefill to the boundary of the next TCP
window. Exceeding the boundary of the current TCP window will always result in a
[roundtrip][roundtrip] at the network layer,[^1] and any time a roundtrip is
going to be incurred, it would be [better][better] to let our peer tell us
exactly what they are missing in a roundtrip than to try to guess by stuffing in
more data.

## Prefill what

- The transactions which we were missing during reconstruction and received in a
  `GETBLOCKTXN->BLOCKTXN` round trip with our peer.
- The transactions which were pulled from our extrapool during
reconstruction.[^2]
- Any transactions that were prefilled to us that we didn't already have in our
  mempool.

## Prefill when

To avoid having to generate unique CMPCTBLOCK messages for each of our peers,
which might be costly[^4], we (lazily) build and cache 2 CMPCTBLOCK messages:
prefilled and not prefilled. At sending time we check the available bytes in our
peer's TCP window, and if the total number of TCP windows occupied by the prefilled
block is equal to the total number of windows occupied by the nonprefilled
block, then we send the prefilled block.

## TCP Windows

Discussed in greater detail [elsewhere][elsewhere], I'll try to summarize here:

In [RFC 793][rfc-793] TCP was specified with receiver advertised window sizes
because receivers allocate some buffer size to a given TCP connection, and this
receiver advertised window represents the most **unacknowledged** data a
receiver will process before dropping bytes on the ground or something awful
like that. So the sender of a message over a TCP connection will only send up to
the last acknowledged byte + the receiver's advertised window size in order to
avoid filling up their peer's receive buffer.

It was later discovered that TCP was susceptible to ["congestion
collapse"][congestion-collapse], which can probably describe any congestion
feedback loop but in TCP is where packets being dropped due to congestion
results in retransmissions that cause even more congestion. This resulted in
implementations of TCP using "congestion control" algorithms which decide on the
sending side to limit the number of bytes to send dynamically, based on how
frequently packets are dropped on a TCP connection. For a more concrete account
of various congestion control algorithms see [RFC 5681][rfc-5681]. A user's TCP
implementation (typically in their OS kernel) will compute a window size
dynamically for each TCP connection usually increasing as packets sent are
ACKnowledged and decreasing when packets sent are dropped.

Because congestion control window sizes are computed per-connection, change over
connection lifetime, and there are a number of congestion control algorithms for
TCP implementations to choose from freely, and many systems allow user
configuration of congestion control parameters, there is not likely to be any
way to guess or predict what the TCP window will be very effectively, and we
must query the TCP implementation in order to learn what these window sizes are.

The usable window size is the smaller of the receiver advertised window and the
sender computed congestion control window, but in practice the congestion
control window is far smaller.

I fear that this description might be insufficient, have much much more to say,
but I stopped myself here in order to solicit questions from others which are
certainly better than the ones I can preempt myself.


[^1]: A network layer roundtrip will be faster than an application layer
    roundtrip, although probably not by much for most connections. Since at
    the application layer there will be some time your message spends waiting to
    be processed by your peer, at leasstwill mean having to wait for the time it
    for peers that use single-threaded message processing like Bitcoin
    Core does presently.
[^2]: The reason to pluck from the extrapool is because it is very likely to
    differ between nodes.
[^3]: I will share a write up with my full experimental set up and data soon, but it is
    mostly identical to the set up described here: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/34
[^4]: But maybe there is some cost here that is worth trading off, it's not
    something I've explored.


[proposal]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/24
[sketch-shortid]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/30
[the-fibre-project-does]: https://github.com/bitcoinfibre/bitcoinfibre/blob/master/src/udprelay.cpp

[roundtrip]: https://en.wikipedia.ohttps://en.wikipedia.org/wiki/TCP_window_scale_option#TCP_windows
[better]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/34


[rfc-793]: https://www.rfc-editor.org/rfc/rfc793.html#section-2.6

[elsewhere]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/34
[congestion-collapse]: https://dl.acm.org/doi/epdf/10.1145/52325.52356

[rfc-5681]: https://datatracker.ietf.org/doc/html/rfc5681

[block-templates]: https://delvingbitcoin.org/t/sharing-block-templates/1906
