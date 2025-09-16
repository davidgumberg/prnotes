In order to fill messages to capacity, we want to know how many bytes are
available in the TCP window, getting the size of the window is easy: just ask
the OS, it's the smaller of the receiver's advertised window size and the
sender's computed congestion window size.

The tricky part is deciding how many bytes in the window are already occupied,
we want to know this in order to only try to send as many bytes as we can fit in
the window. The sources of occupied window space depend on who's asking and why
they're asking, but for an application that has a message to send:

1. In-flight data, or unACK'ed data, data that's been handed to the OS by the
   application and is either sitting in an OS buffer, or out on the wire flying
   to the receiver.
2. Data still in the application's send queue.
3. The overhead of the application's protocol on the message.

The first is trivial, just ask the OS and it'll tell you, but 2 and 3 are a
little bit more difficult.

For 2, there is an ambiguity, if data is sitting in the application's send
queue, then this message is also likely to end up sitting in the send queue, and
so even though we could figure out how much data is queued, what we ultimately
care about is how much data is in-flight at sending time, and that will probably
change between now and when this message is ready to be sent. 

For 3, there is also an ambiguity, but an easier one to resolve, which is that
in Bitcoin Core, the transport overhead is variable depending on the whether V1
transport or V2 transport is used, and in the future might become variable again
if traffic shaping is implemented as described in
[BIP-0324](https://github.com/bitcoin/bips/blob/master/bip-0324.mediawiki#goals).

The solution to #2 and #3 seems to be to make message filling a concern of the
transport layer rather than the application layer, we want to know how much data
is in flight right before we hand the data to the OS to decide how much to
prefill, the problem with this is how much complexity/application-level logic it
pushes into the transport layer.

Alternatively, if the above is too challenging, we can just check at message
time how big the application queue is and use this figure, since it sets an
upper bound.
