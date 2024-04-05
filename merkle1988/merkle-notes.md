# Lamport Signature Scheme

## Signing a one-bit message

Alice signs a one-bit message 'm' for Bob: 

_Alice randomly generates x: consisting of x_1 and x_2.

<pre>
    one-way hash function F(x)
[x_1, x_2] -> [y_1, y_2]
</pre>

x_1 and x_2 are made kept private, y_1 and y_2 are made public.

If the one-bit message is `1`, Alice signs it by giving x[1] to Bob.
If the one-bit message is `0`, Alice signs it by giving x[1] to Bob.

If the one-bit message was '1' Bob can prove that Alice signed it by presenting
x[1] and showing that F(x_1) = y_1.

## Signing a several bit message

If Alice generates many x's and many y's, they can sign a message with many
bits using the method above.

Since two x's and corresponding y's are required to
represent a single bit of data in the original message being signed, a message
that is `n` bits long would require `2 * n` x's and `2 * n` y's.

This signature scheme is the Lamport-Diffie one-time signature, or Lamport
Signature, and has the same security properties as cryptographic hash functions,
as opposed to signature schemes like RSA and ECDSA that depend on the discrete
log problem remaining unbroken.


## (1979) Merkle's improvement to the Lamport Signature

Merkle's improvement reduces the signature size from `2n` to `n + log_2(n)`:

Instead of generating two x's and two y's for each bit of the message, Alice
generates one x and one y for every bit of the message `m` to be signed. When
the `n`th message bit  `m[n]` is 1, Alice releases `x[n]`,  when `m[n]` is 0,
Alice releases nothing.

This allows Bob to pretend that he did not receive some of the `x`'s in the
message, and that some of the '1' bits in the signed message were '0', so we
introduce a 'count' field that represents the number of '0's in the message.

Since the only malleation that Bob can perform is pretending he has not received
a bit (or the private part x[n] of the signature indicating that the message bit
is 1, he can only ever increase the number of zeroes in the message portion of
the signature, and he can only ever decrease the number of zeroes in the 'count'
portion of the signature.

Question: Why couldn't Bob already just modify Alice's signature and pretend
that this is the message he received?

- He could, but that would not be a valid signature for the given message,
  Merkle's "compressed pubkey" improvement to the Lamport signature (without the
  added protection of a count field) allows Bob to modify Alice's message by
  ommitting x[n]'s and still have a valid signature. 

  As in, given a valid signature from Alice for the message: "I like cats, not
  dogs.", Bob could produce the message "I like dogs." with a valid signature
  from Alice by omitting: "cats, not".

## Winternitz improvement to the Lamport Signature

Winternitz' improvement[^1] reduces the signature length by repeated applications of
the one-way hash function e.g. $`F(F(x))`$ notated as $`F^2(x)`$. Note that $`F^0(x) = x`$

To sign a 2-bit message Alice can precompute and publish:

$$
y[1] = F^4(x[1])`
y[2] = F^4(x[2])
$$

If Alice wishes to sign a 2-bit ($`n = 2`$) message $`m`$ (0, 1, 2, or 3), then
Alice reveals $`F^m(x[1])`$ and $`F^{(2^n - 1) - m}(x[2])`$. So in this case, if
the two bit message was '2', then Alice would reveal $`F^2(x[1])`$ and
$`F^{3-2}(x[2])`$.

### Why complementary signatures?

If Alice only revealed $`F^m(x[1])`$ then given a signature for `m` Bob could
produce every message from $`m`$ (the actual message) to $`n^2 - 1`$ the highest
possible value the message could represent

### Question: How does Merkle's improvement generalize to the Winternitz one-time
signature?

Merkle states that his improvement to the one-time signature generalizes to the
Winternitz one-time signature, but doesn't describe how.


# Problem that remains

> "Thus, the original one-time signature system proposed by Lamport and Diffie,
> and improved by Winternitz and Merkle, can be used to sign arbitrary messages
> and has excellent security. The storage and computational requirements for
> signing a signle message are quite reasonable. Unfortunately, signing more
> messages requires many more x's and y's and therefore a very large entry in
> the public file (which holds the y's). To allow A[lice] to sign 1000 messages
> might require roughly 10,000 y's -- and if there were 1000 different users of
> the system, each of whom wanted to sign 1000 messages, this would increase the
> storage requirement for the public file to hundreds of megabytes -- which is
> unwieldy and has effectively prevented use of these systems.

# 𝙰𝙽 𝙸𝙽𝙵𝙸𝙽𝙸𝚃𝙴 𝚃𝚁𝙴𝙴 𝙾𝙵 𝙾𝙽𝙴-𝚃𝙸𝙼𝙴 𝚂𝙸𝙶𝙽𝙰𝚃𝚄𝚁𝙴𝚂

The tree is assumed to be binary.

Each node of the tree performs three functions:

1. Authenticates the left sub-node. (Alternately: child)
2. Authenticates the right sub-node.
3. Signs a single message.

Therefore each node has three signatures -- 'left', 'right', and 'message'.

## Notation: 

- The root node is designated '1'.
- The left sub-node of node `i` is designated `2i`
- The right sub-node of node `i` is `2i + 1`.

# See also:

BIP98: https://github.com/bitcoin/bips/blob/master/bip-0098.mediawiki
