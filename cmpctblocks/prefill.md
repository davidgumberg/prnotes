Draft pr description for prefilling compactblocks

*'We' refers to the Royal Node.*

This is an implementation of 0xB10C's [proposal][proposal] to prefill CMPCTBLOCK
messages based on what we needed during CMPCTBLOCK reconstruction in order to
avoid a `GETBLOCKTXN` roundtrip for reconstruction to succeed. It is important
to note that while there are larger improvements to the `CMPCTBLOCK` protocol
that are desirable, e.g. [using a sketch instead of shortid's][sketch-shortid],
or using a UDP connection with FEC as [the FIBRE project
does][the-fibre-project-does], the advantage of improving reconstruction rates
by prefilling is that it requires no protocol changes and is entirely backwards
compatible with existing nodes that have implemented the `CMPCTBLOCK` protocol.

This work is largely derived from 0xB10C's implementation:
https://github.com/0xB10C/bitcoin/tree/2025-03-prefill-cmpctblocks

My primary contribution, that in my view addresses the concerns that previously
prevented the use of any prefilling 

The transactions that are prefilled:
- The transactions which were pulled from our extrapool during reconstruction.
- The transactions which we were missing during reconstruction and received in a
  `GETBLOCKTXN->BLOCKTXN` round trip with our peer.




[proposal]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/24
[sketch-shortid]: https://delvingbitcoin.org/t/stats-on-compact-block-reconstructions/1052/30
[the-fibre-project-does]: https://github.com/bitcoinfibre/bitcoinfibre/blob/master/src/udprelay.cpp
