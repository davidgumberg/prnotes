This PR modifies `DataStream`'s vector `vch` to use the default `std::vector`
allocator, rather than `zero_after_free_allocator`. It also drops the
`zero_after_free_allocator`, since this was only used by `DataStream` and
`SerializeData`, and makes a small change to a unit test where boost
mysteriously fails to find a left shift-operator for `SerializeData` once it
loses its custom allocator.

The `zero_after_free_allocator` is identical to the default `std::allocator`
except that it zeroes memory using `memory_cleanse()` before deallocating.

In my testing (n=2) on a Raspberry Pi 5 with 4GB of memory, syncing from a fast
connection to a stable dedicated node, my branch takes **~74%** of the time taken
by master[^1] to sync to height 815,000; average wall clock time was 35h 58m 40s
on this branch and 48h 17m 15s on master, see the benchmarking appendix for more
detail.

I believe the speedup mainly comes from the use of `DataStream` for all
`CDBWrapper` keys and values, and for all of the data we receive from peers. I
suspect there are other use cases where performance is improved, but I have not
done much testing outside of IBD.

Any objects that contains secrets should *not* be allocated using
`zero_after_free_allocator` since they are liable to get mapped to swap space
and written to disk if the user is running low on memory, and I intuit this is a
likelier path than scanning unzero'd memory for an attacker to find
cryptographic secrets. Secrets should be allocated using `secure_allocator`
which cleanses on deallocation and `mlock()`s the memory reserved for secrets to
prevent it from being mapped to swap space.

## Are any secrets stored in `DataStream` that will lose security?

I have reviewed every appearance of `DataStream` and `SerializeData` as of
[`39219fe`](https://github.com/bitcoin/bitcoin/commit/39219fe145e5e6e6f079b591e3f4b5fea8e718040)
and have made notes in the appendix below. describing why I think each instance
does not involve the handling of secrets.

The only use case that I wasn't certain of is PSBT's, I believe these are never
secrets, but I don't know enough about to know if there are use cases where
PSBT's are worthy of being treated as secrets, and being vigilant about not
writing them to disk is wise.

As I understand, most of the use of `DataStream` in the wallet code is for the
reading and writing of "crypted" key and value data, and they get decrypted
somewhere else in a `ScriptPubKeyMan` far away from any `DataStream` container,
but I could also be wrong about this, or have misunderstood it's use elsewhere
in the wallet.

## Zero-after-free as a buffer overflow mitigation

The `zero_after_free` allocator was added as a buffer overflow mitigation, the
idea being that `DataStream`'s store a lot of unsecured data that we don't
control like the UTXO set and all P2P messages, and an attacker could fill
memory in a predictable way to escalate a buffer overflow into an RCE. (See
Historical Background in the Appendix).

I agree completely with practicing security in depth, but I don't think this
mitigation is worth the performance hit because: 

1. Aren't there still an abundance of other opportunities for an attacker to
   fill memory that never gets deallocated?
2. Doesn't ASLR mostly mitigate this issue and don't most devices have some form
   of ASLR?

I'm not an expert in this topic and I had a hard time finding any writing
anywhere that discusses this particular mitigation strategy of zeroing memory,
so I hope someone with more knowledge of memory vulnerabilities can assist.

### Other notes

I have a feeling that it's not just the fact that we're memsetting everything to 0 in
`memory_cleanse` that is causing the performance issue, but the fact that the
trick we do to prevent compilers from optimizing out the `memset` call is also
preventing other optimizations on the `DataStream`s.

# Appendices

<details>

<summary>

## Benchmarking

</summary>

Command being timed:
```bash
./src/bitcoind -daemon=0 -connect=amd-ryzen-7900x-node:8333 -stopatheight=815000 -port=8444 -rpcport=8445 -dbcache=2048 -prune=550 -debug=bench -debug=blockstorage -debug=coindb -debug=mempool -debug=prune"
```

I applied my branch on
[6d546336e800](https://github.com/bitcoin/bitcoin/commit/6d546336e800), which is
"master" in the data below.

Average master time (hh:mm:ss): 48:17:15 (173835s)
Average branch time (hh:mm:ss): 35:58:40 (129520s)

~25% reduction in IBD time on a raspberry Pi 5 with a DB cache of 2GB.

# Master run 1
Wall clock time (hh:mm:ss): 49:38:31 (178711s)

```console
Bitcoin Core version v27.99.0-6d546336e800 (release build)
- Connect block: 158290.53s (620.94ms/blk)
    - Sanity checks: 10.89s (0.01ms/blk)
    - Fork checks: 151.82s (0.02ms/blk)
    - Verify 7077 txins: 135057.68s (165.71ms/blk)
      - Connect 1760 transactions: 134786.36s (165.38ms/blk)
    - Write undo data: 2681.34s (7.38ms/blk)
    - Index writing: 52.76s (0.03ms/blk)
  - Connect total: 138100.75s (611.27ms/blk)
  - Flush: 3933.29s (8.97ms/blk)
  - Writing chainstate: 15814.36s (0.14ms/blk)
  - Connect postprocess: 273.39s (0.52ms/blk)
```

# Master run 2
Wall clock time (hh:mm:ss): 46:55:58 (168958s)

```
Bitcoin Core version v27.99.0-6d546336e800 (release build)
- Connect block: 145449.95s (940.78ms/blk)
    - Sanity checks: 10.69s (0.01ms/blk)
    - Fork checks: 155.81s (0.02ms/blk)
    - Verify 7077 txins: 115935.55s (142.25ms/blk)
      - Connect 1760 transactions: 115481.15s (141.69ms/blk)
    - Write undo data: 2561.36s (9.05ms/blk)
    - Index writing: 73.63s (0.04ms/blk)
  - Connect total: 118877.56s (929.93ms/blk)
  - Flush: 3864.34s (10.11ms/blk)
  - Writing chainstate: 22294.82s (0.14ms/blk)
  - Connect postprocess: 267.68s (0.56ms/blk)
```

# Branch run 1
Wall clock time (hh:mm:ss): 34:28:56 (124136s)

```
Bitcoin Core version v27.99.0-a0dddf8b4092 (release build)
- Connect block: 107134.59s (1017.01ms/blk)
    - Sanity checks: 11.01s (0.01ms/blk)
    - Fork checks: 150.93s (0.03ms/blk)
    - Verify 7077 txins: 87446.53s (107.30ms/blk)
      - Connect 1760 transactions: 87329.99s (107.15ms/blk)
    - Write undo data: 2495.47s (7.36ms/blk)
    - Index writing: 37.95s (0.04ms/blk)
  - Connect total: 90318.60s (1006.42ms/blk)
  - Flush: 3917.28s (9.92ms/blk)
  - Writing chainstate: 12560.43s (0.15ms/blk)
  - Connect postprocess: 259.89s (0.47ms/blk)
```

# Branch run 2
Wall clock time (hh:mm:ss): 37:28:24 (134904s)

```
Bitcoin Core version v27.99.0-a0dddf8b4092 (release build)
- Connect block: 117991.55s (144.77ms/blk)
  - Connect total: 101298.20s (124.29ms/blk)
    - Sanity checks: 11.17s (0.01ms/blk)
    - Fork checks: 151.24s (0.19ms/blk)
    - Verify 7077 txins: 98446.38s (120.79ms/blk)
      - Connect 1760 transactions: 98339.79s (120.66ms/blk)
    - Write undo data: 2484.75s (3.05ms/blk)
    - Index writing: 36.62s (0.04ms/blk)
  - Flush: 3892.28s (4.78ms/blk)
  - Writing chainstate: 12446.33s (15.27ms/blk)
  - Connect postprocess: 259.11s (0.32ms/blk)
```
</details>

<details>

<summary>

## Historical background

</summary>

<details>

At some point prior to the oldest git commit for the repo, an allocator
`secure_allocator` was
[added](https://github.com/bitcoin/bitcoin/blob/0a61b0df1224a5470bcddab302bc199ca5a9e356/serialize.h#L675-L702)
that zeroes out memory on deallocation with `memset()`, and was
[used](https://github.com/bitcoin/bitcoin/blob/0a61b0df1224a5470bcddab302bc199ca5a9e356/serialize.h#L711-L714)
as the allocator for the vector `vch` in `CDataStream` (now `DataStream`).

In July 2011, PR [#352](https://github.com/bitcoin/bitcoin/pull/352) adding
support for encrypted wallets `secure_allocator` was
[modified](https://github.com/bitcoin/bitcoin/pull/352/commits/c1aacf0be347b10a6ab9bbce841e8127412bce41)
to also `mlock()` data on allocation to prevent the wallet passphrase or other
secrets from being paged to swap space (written to disk).

In January 2012, findings were shared
(https://bitcointalk.org/index.php?topic=56491.0) that
[#352](https://github.com/bitcoin/bitcoin/pull/352) modifying `CDataStream`'s
allocator slowed down IBD substantially[^2], since `CDataStream` was used in
many places that did not need the guarantees of `mlock()`, and since every call
to `mlock()` results in a flush of the TLB (a cache that maps virtual memory to
physical memory).

PR [#740](https://github.com/bitcoin/bitcoin/pull/740) was opened to fix
this, initially[^3] by removing the custom allocator `secure_allocator` from
`CDataStream`'s `vector_type`:

```diff
 class CDataStream
 {
 protected:
-    typedef std::vector<char, secure_allocator<char> > vector_type;
+    typedef std::vector<char> vector_type;
     vector_type vch;
```

A reviewer of [#740](https://github.com/bitcoin/bitcoin/pull/740)
[suggested](https://github.com/bitcoin/bitcoin/pull/740#issuecomment-3356239)
that dropping `mlock()` was a good idea, but that the original behavior of
zeroing-after-freeing (should it be zeroing-*before*-freeing?) `CDataStream`
should be restored as a mitigation for buffer overflows:

> I love the performance improvement, but I still don't like the elimination of zero-after-free. Security in depth is important.
>
> Here's the danger:
>
> Attacker finds a remotely-exploitable buffer overrun somewhere in the networking code that crashes the process.
> They turn the crash into a full remote exploit by sending carefully constructed packets before the crash packet, to initialize used-but-then-freed memory to a known state.
>
> Unlikely? Sure.
>
> Is it ugly to define a zero_after_free_allocator for CDataStream? Sure. (simplest implementation: copy secure_allocator, remove the mlock/munlock calls).
>
> But given that CDataStream is the primary interface between bitcoin and the network, I think being extra paranoid here is a very good idea.

Another reviewer benchmarked `CDataStream` with an allocator that zeroed
memory using `memset` without `mlock`ing it and found that performance was almost identical to
the default allocator, while both were substantially faster than the `mlock`ing
variant of `CDataStream`.
(https://web.archive.org/web/20130622160044/https://people.xiph.org/~greg/bitcoin-sync.png).

Based on the benchmark, and the potential security benefit, the
`zero_after_free` allocator was created and used as `CDataStream`'s
allocator.

In November 2012, PR [#1992](https://github.com/bitcoin/bitcoin/pull/1992) was
opened to address the fact that in many cases `memset()` calls are optimized
away by compilers as part of a family of compiler optimizations called
[dead store elimination](https://www.usenix.org/conference/usenixsecurity17/technical-sessions/presentation/yang)
by replacing the `memset` call with openssl's `OPENSSL_cleanse` which is meant
to solve this problem. Given that all of the data being zero'ed out in the
deallocator is also having it's only pointer destroyed, these memset calls were
candidates for being optimized.

I suspect that the reason no performance regression was found in the
benchmarking of [#740](https://github.com/bitcoin/bitcoin/pull/740) which
introduced the `zero_after_free` allocator is that the `memset` calls were being
optimized out.

I am not the first to suggest that this is a performance issue:

https://bitcoin-irc.chaincode.com/bitcoin-core-dev/2015-11-06#1446837840-1446854100;

https://bitcoin-irc.chaincode.com/bitcoin-core-dev/2016-11-23#1479883620-1479882900;

Or to write a patch changing it:

https://github.com/bitcoin/bitcoin/commit/671c724716abdd69b9d253a01f8fec67a37ab7d7

</details>

<details>

<summary>

## All uses of `DataStream` and `SerializeData`
(Warning when opening: very long)

</summary>

# All uses of `DataStream` and `SerializeData`

I performed this review on commit
[39219fe145e5e6e6f079b591e3f4b5fea8e71804](https://github.com/bitcoin/bitcoin/commit/39219fe145e5e6e6f079b591e3f4b5fea8e71804)

I look, briefly, at every single use of `DataStream` outside of test code, to
see whether or not it contains secret information that should be zeroed out, or
should be mlocked to prevent paging to swap.

I've taken liberties to editorialize some of the codeblocks below for
legibility, and all comments that have `[]` are my own.

# `DataStream`

In `src/addrdb.cpp`+`src/addrdb.h`:

```cpp
/** Only used by tests. */
void ReadFromStream(AddrMan& addr, DataStream& ssPeers);
```

😺 Only used by tests.

-----

In `src/addrman.cpp` `Addrman::Serialize(DataStream&)` &
`Unserialize(DataStream&)`, are explicitly instantiated, these are used in
`SerializeFileDB` and `DeserializeDB` which are used to serialize
(`DumpPeerAddresses`) addrman to disk, and to deserialize addrman from disk
(`LoadAddrman`).

The most valuable secret seems to be addrman's `nKey` used to determine the
address buckets randomly.

-------

In `src/blockencodings.cpp`:

```cpp
void CBlockHeaderAndShortTxIDs::FillShortTxIDSelector() const {
    DataStream stream{};
    stream << header << nonce;
    CSHA256 hasher;
    hasher.Write((unsigned char*)&(*stream.begin()), stream.end() - stream.begin());
    uint256 shorttxidhash;
    hasher.Finalize(shorttxidhash.begin());
    shorttxidk0 = shorttxidhash.GetUint64(0);
    shorttxidk1 = shorttxidhash.GetUint64(1);
}
```

Here we are just using the DataStream to be able to Serialize the block header
and nonce into a string of bytes that get hashed to make short id k0 and k1 for
[BIP 152](https://github.com/bitcoin/bips/blob/master/bip-0152.mediawiki#short-transaction-ids).

This gets invoked when we construct a `CBlockHeaderandShortTxIDs` for an INV of
type `MSG_CMPCT_BLOCK` in `PeerManagerImpl::SendMessage()`.

-------

In `src/common/blooms.cpp`:

DataStream is used to deserialize outpoints into our bloom filter, these are not
secrets in any way:

```cpp
void CBloomFilter::insert(const COutPoint& outpoint)
{
    DataStream stream{};
    stream << outpoint;
    insert(MakeUCharSpan(stream));
}
```

-------

In `src/core_read.cpp`:

DataStream is used in `DecodeTx` for serialization/deserialization of the
transaction data, used afaict only in RPC's for deserializing user arguments
into `CMutableTransaction`'s.

It's used in `DecodeHexBlockHeader()`which deserializes a block header argument
into a `CBlockHeader` for the `submitheader` rpc.

Similar for `DecodeHexBlk()` used by the `getblocktemplate` and `submitblock`
rpc's.

----

In `src/core_write.cpp`:

```cpp
void CBloomFilter::insert(const COutPoint& outpoint)
{
    DataStream stream{};
    stream << outpoint;
    insert(MakeUCharSpan(stream));
}
```

`EncodeHexTx` is only used in RPC's, and transaction data does not contain
secrets.

------

In `dbwrapper.h` and `dbwrapper.cpp` it is used exclusively to serialize and
deserialize coinsdb keys and values, none of which is secret.

--------

In `src/external_signer`:

```cpp
bool ExternalSigner::SignTransaction(PartiallySignedTransaction& psbtx, std::string& error)
{
    // Serialize the PSBT
    DataStream ssTx{};
    ssTx << psbtx;
```

I don't think this is a secret, but I don't know enough about PSBT's to be sure.

-------

There is some scaffolding for being able to transmit serializable stuff over the
IPC wire in `src/capnp/common-types.h`, I assume this depends on how it's used,
nothing essentially secret.

--------

In `src/kernel/coinstats.cpp`:

```cpp
void ApplyCoinHash(MuHash3072& muhash, const COutPoint& outpoint, const Coin& coin)
{
    DataStream ss{};
    TxOutSer(ss, outpoint, coin);
    muhash.Insert(MakeUCharSpan(ss));
}
```

Here it's used for serializing oupoints and coins for creating the AssumeUTXO
assumed utxo set hash, nothing secret.

-------

In `src/net.cpp`:

In `ConvertSeeds()` serialized seeds get converted into usable address objects, we
initialize a DataStream with the input seeds that we are going to try connecting
to during node bootstrapping.

```cpp
//! Convert the serialized seeds into usable address objects.
static std::vector<CAddress> ConvertSeeds(const std::vector<uint8_t> &vSeedsIn)
{
    // It'll only connect to one or two seed nodes because once it connects,
    // it'll get a pile of addresses with newer timestamps.
    // Seed nodes are given a random 'last seen time' of between one and two
    // weeks ago.
    const auto one_week{7 * 24h};
    std::vector<CAddress> vSeedsOut;
    FastRandomContext rng;
    ParamsStream s{DataStream{vSeedsIn}, CAddress::V2_NETWORK};
    while (!s.eof()) {
        CService endpoint;
        s >> endpoint;
        CAddress addr{endpoint, SeedsServiceFlags()};
        addr.nTime = rng.rand_uniform_delay(Now<NodeSeconds>() - one_week, -one_week);
        LogDebug(BCLog::NET, "Added hardcoded seed: %s\n", addr.ToStringAddrPort());
        vSeedsOut.push_back(addr);
    }
    return vSeedsOut;
}
```

It is also used for creating an empty `CNetMessage` which has a `DataStream`
member in `CNetMessage V2Transport::GetReceivedMessage()`:

```cpp
//! Convert the serialized seeds into usable address objects.
static std::vector<CAddress> ConvertSeeds(const std::vector<uint8_t> &vSeedsIn)
{
    // It'll only connect to one or two seed nodes because once it connects,
    // it'll get a pile of addresses with newer timestamps.
    // Seed nodes are given a random 'last seen time' of between one and two
    // weeks ago.
    const auto one_week{7 * 24h};
    std::vector<CAddress> vSeedsOut;
    FastRandomContext rng;
    ParamsStream s{DataStream{vSeedsIn}, CAddress::V2_NETWORK};
    while (!s.eof()) {
        CService endpoint;
        s >> endpoint;
        CAddress addr{endpoint, SeedsServiceFlags()};
        addr.nTime = rng.rand_uniform_delay(Now<NodeSeconds>() - one_week, -one_week);
        LogDebug(BCLog::NET, "Added hardcoded seed: %s\n", addr.ToStringAddrPort());
        vSeedsOut.push_back(addr);
    }
    return vSeedsOut;
}
```

--------

In `net.h`

`CNetMessage` the universal p2p message container used a `DataStream` to store
received message data.

```cpp
/** Transport protocol agnostic message container.
 * Ideally it should only contain receive time, payload,
 * type and size.
 */
class CNetMessage
{
public:
    DataStream m_recv;                   //!< received message data
    std::chrono::microseconds m_time{0}; //!< time of message receipt
    uint32_t m_message_size{0};          //!< size of the payload
    uint32_t m_raw_message_size{0};      //!< used wire size of the message (including header/checksum)
    std::string m_type;

    explicit CNetMessage(DataStream&& recv_in) : m_recv(std::move(recv_in)) {}
    // Only one CNetMessage object will exist for the same message on either
    // the receive or processing queue. For performance reasons we therefore
    // delete the copy constructor and assignment operator to avoid the
    // possibility of copying CNetMessage objects.
    CNetMessage(CNetMessage&&) = default;
    CNetMessage(const CNetMessage&) = delete;
    CNetMessage& operator=(CNetMessage&&) = default;
    CNetMessage& operator=(const CNetMessage&) = delete;
};
```

It's also used for the lower level handling of messages, including partially
received header buffers and received socket data in `V1Transport` as in v2
transport above in `net.cpp`.

```cpp
/** Transport protocol agnostic message container.
 * Ideally it should only contain receive time, payload,
 * type and size.
 */
class CNetMessage
{
public:
    DataStream m_recv;                   //!< received message data
    std::chrono::microseconds m_time{0}; //!< time of message receipt
    uint32_t m_message_size{0};          //!< size of the payload
    uint32_t m_raw_message_size{0};      //!< used wire size of the message (including header/checksum)
    std::string m_type;

    explicit CNetMessage(DataStream&& recv_in) : m_recv(std::move(recv_in)) {}
    // Only one CNetMessage object will exist for the same message on either
    // the receive or processing queue. For performance reasons we therefore
    // delete the copy constructor and assignment operator to avoid the
    // possibility of copying CNetMessage objects.
    CNetMessage(CNetMessage&&) = default;
    CNetMessage(const CNetMessage&) = delete;
    CNetMessage& operator=(CNetMessage&&) = default;
    CNetMessage& operator=(const CNetMessage&) = delete;
};
```

--------

In `src/net_processing.cpp` it used for representing the received data when
processing messages in the great `PeerManagerImpl::ProcessMessage()`:

```cpp
void PeerManagerImpl::ProcessMessage(CNode& pfrom, const std::string& msg_type, DataStream& vRecv,
                                     const std::chrono::microseconds time_received,
                                     const std::atomic<bool>& interruptMsgProc)
{
```

And for Processing BIP 157 cfilters: 

```cpp
/**
 * Handle a cfilters request.
 *
 * May disconnect from the peer in the case of a bad request.
 *
 * @param[in]   node            The node that we received the request from
 * @param[in]   peer            The peer that we received the request from
 * @param[in]   vRecv           The raw message received
 */
void PeerManagerImpl::ProcessGetCFilters(CNode& node, Peer& peer, DataStream& vRecv)
{
    uint8_t filter_type_ser;
    uint32_t start_height;
    uint256 stop_hash;

    vRecv >> filter_type_ser >> start_height >> stop_hash;

    const BlockFilterType filter_type = static_cast<BlockFilterType>(filter_type_ser);

    const CBlockIndex* stop_index;
    BlockFilterIndex* filter_index;
    if (!PrepareBlockFilterRequest(node, peer, filter_type, start_height, stop_hash,
                                   MAX_GETCFILTERS_SIZE, stop_index, filter_index)) {
        return;
    }

    std::vector<BlockFilter> filters;
    if (!filter_index->LookupFilterRange(start_height, stop_index, filters)) {
        LogDebug(BCLog::NET, "Failed to find block filter in index: filter_type=%s, start_height=%d, stop_hash=%s\n",
                     BlockFilterTypeName(filter_type), start_height, stop_hash.ToString());
        return;
    }

    for (const auto& filter : filters) {
        MakeAndPushMessage(node, NetMsgType::CFILTER, filter);
    }
```

and bip 157 cfheaders:

```cpp
/**
 * Handle a cfheaders request.
 *
 * May disconnect from the peer in the case of a bad request.
 *
 * @param[in]   node            The node that we received the request from
 * @param[in]   peer            The peer that we received the request from
 * @param[in]   vRecv           The raw message received
 */
 void PeerManagerImpl::ProcessGetCFHeaders(CNode& node, Peer& peer, DataStream& vRecv)
{
    uint8_t filter_type_ser;
    uint32_t start_height;
    uint256 stop_hash;

    vRecv >> filter_type_ser >> start_height >> stop_hash;

    const BlockFilterType filter_type = static_cast<BlockFilterType>(filter_type_ser);

    const CBlockIndex* stop_index;
    BlockFilterIndex* filter_index;
    if (!PrepareBlockFilterRequest(node, peer, filter_type, start_height, stop_hash,
                                   MAX_GETCFHEADERS_SIZE, stop_index, filter_index)) {
        return;
    }

    uint256 prev_header;
    if (start_height > 0) {
        const CBlockIndex* const prev_block =
            stop_index->GetAncestor(static_cast<int>(start_height - 1));
        if (!filter_index->LookupFilterHeader(prev_block, prev_header)) {
            LogDebug(BCLog::NET, "Failed to find block filter header in index: filter_type=%s, block_hash=%s\n",
                         BlockFilterTypeName(filter_type), prev_block->GetBlockHash().ToString());
            return;
        }
    }

    std::vector<uint256> filter_hashes;
    if (!filter_index->LookupFilterHashRange(start_height, stop_index, filter_hashes)) {
        LogDebug(BCLog::NET, "Failed to find block filter hashes in index: filter_type=%s, start_height=%d, stop_hash=%s\n",
                     BlockFilterTypeName(filter_type), start_height, stop_hash.ToString());
        return;
    }

    MakeAndPushMessage(node, NetMsgType::CFHEADERS,
              filter_type_ser,
              stop_index->GetBlockHash(),
              prev_header,
              filter_hashes);
}
```

------

In `src/psbt.cpp`:

```cpp
bool DecodeRawPSBT(PartiallySignedTransaction& psbt, Span<const std::byte> tx_data, std::string& error)
{
    DataStream ss_data{tx_data};
    try {
        ss_data >> psbt;
        if (!ss_data.empty()) {
            error = "extra data after PSBT";
            return false;
        }
    } catch (const std::exception& e) {
        error = e.what();
        return false;
    }
    return true;
}
```

It is used for deserializing hex data into a `PartiallySignedTransaction`
object.

--------


In `src/qt/psbtoperationsdialog.cpp`:

Bitcoin Qt interface for 

Copying psbt to clipboard:

```cpp
void PSBTOperationsDialog::copyToClipboard() {
    DataStream ssTx{};
    ssTx << m_transaction_data;
    GUIUtil::setClipboard(EncodeBase64(ssTx.str()).c_str());
    showStatus(tr("PSBT copied to clipboard."), StatusLevel::INFO);
}
```

Saving PSBT to disk:
```cpp
void PSBTOperationsDialog::saveTransaction() {
    DataStream ssTx{};
    ssTx << m_transaction_data;

    QString selected_filter;
    QString filename_suggestion = "";
    bool first = true;
    for (const CTxOut& out : m_transaction_data.tx->vout) {
        if (!first) {
            filename_suggestion.append("-");
        }
        CTxDestination address;
        ExtractDestination(out.scriptPubKey, address);
        QString amount = BitcoinUnits::format(m_client_model->getOptionsModel()->getDisplayUnit(), out.nValue);
        QString address_str = QString::fromStdString(EncodeDestination(address));
        filename_suggestion.append(address_str + "-" + amount);
        first = false;
    }
    filename_suggestion.append(".psbt");
    QString filename = GUIUtil::getSaveFileName(this,
        tr("Save Transaction Data"), filename_suggestion,
        //: Expanded name of the binary PSBT file format. See: BIP 174.
        tr("Partially Signed Transaction (Binary)") + QLatin1String(" (*.psbt)"), &selected_filter);
    if (filename.isEmpty()) {
        return;
    }
    std::ofstream out{filename.toLocal8Bit().data(), std::ofstream::out | std::ofstream::binary};
    out << ssTx.str();
    out.close();
    showStatus(tr("PSBT saved to disk."), StatusLevel::INFO);
}
```

--------

In `src/qt/recentrequestsstablemodel.cpp`:

```cpp
// called when adding a request from the GUI
void RecentRequestsTableModel::addNewRequest(const SendCoinsRecipient &recipient)
{
    RecentRequestEntry newEntry;
    newEntry.id = ++nReceiveRequestsMaxId;
    newEntry.date = QDateTime::currentDateTime();
    newEntry.recipient = recipient;

    DataStream ss{};
    ss << newEntry;

    if (!walletModel->wallet().setAddressReceiveRequest(DecodeDestination(recipient.address.toStdString()), ToString(newEntry.id), ss.str()))
        return;

    addNewRequest(newEntry);
}
```

I am not very familiar with the GUI but as far as I can tell the
`RecentRequestsTable` stores and displays receive addresses / payment requests
that you've generated. Here the `SendCoinsRecipient` of payment request consists
of an address, a label, an amount, and a memo/message. We serialize the
recipient and other data about the request, an ID, and a date/time for the
request, and then pass the string into a function which will store it in the
`RecentRequestsTable`.

--------

In `src/qt/sendcoinsdialog.cpp`:

```cpp
void SendCoinsDialog::presentPSBT(PartiallySignedTransaction& psbtx)
{
    // Serialize the PSBT
    DataStream ssTx{};
    ssTx << psbtx;
    GUIUtil::setClipboard(EncodeBase64(ssTx.str()).c_str());
    QMessageBox msgBox(this);
    //: Caption of "PSBT has been copied" messagebox
    msgBox.setText(tr("Unsigned Transaction", "PSBT copied"));
    msgBox.setInformativeText(tr("The PSBT has been copied to the clipboard. You can also save it."));
    msgBox.setStandardButtons(QMessageBox::Save | QMessageBox::Discard);
    msgBox.setDefaultButton(QMessageBox::Discard);
    msgBox.setObjectName("psbt_copied_message");
    switch (msgBox.exec()) {
    case QMessageBox::Save: {
        QString selectedFilter;
        QString fileNameSuggestion = "";
        bool first = true;
        for (const SendCoinsRecipient &rcp : m_current_transaction->getRecipients()) {
            if (!first) {
                fileNameSuggestion.append(" - ");
            }
            QString labelOrAddress = rcp.label.isEmpty() ? rcp.address : rcp.label;
            QString amount = BitcoinUnits::formatWithUnit(model->getOptionsModel()->getDisplayUnit(), rcp.amount);
            fileNameSuggestion.append(labelOrAddress + "-" + amount);
            first = false;
        }
        fileNameSuggestion.append(".psbt");
        QString filename = GUIUtil::getSaveFileName(this,
            tr("Save Transaction Data"), fileNameSuggestion,
            //: Expanded name of the binary PSBT file format. See: BIP 174.
            tr("Partially Signed Transaction (Binary)") + QLatin1String(" (*.psbt)"), &selectedFilter);
        if (filename.isEmpty()) {
            return;
        }
        std::ofstream out{filename.toLocal8Bit().data(), std::ofstream::out | std::ofstream::binary};
        out << ssTx.str();
        out.close();
        //: Popup message when a PSBT has been saved to a file
        Q_EMIT message(tr("PSBT saved"), tr("PSBT saved to disk"), CClientUIInterface::MSG_INFORMATION);
        break;
    }
    case QMessageBox::Discard:
        break;
    default:
        assert(false);
    } // msgBox.exec()
}
```

Here it's used to serialize the PSBT in order to display it to the user during
the process of sending in the GUI.


---------

In `src/qt/walletmodel.cpp`:

`DataStream`'s are used to serialize PSBT's when fee bumping a stuck transaction
in:

```cpp
bool WalletModel::bumpFee(uint256 hash, uint256& new_hash)
```

and to serialize the sent transaction in `WalletModel::sendCoins()`:

```cpp
void WalletModel::sendCoins(WalletModelTransaction& transaction)
{
    QByteArray transaction_array; /* store serialized transaction */

    {
        std::vector<std::pair<std::string, std::string>> vOrderForm;
        for (const SendCoinsRecipient &rcp : transaction.getRecipients())
        {
            if (!rcp.message.isEmpty()) // Message from normal bitcoin:URI (bitcoin:123...?message=example)
                vOrderForm.emplace_back("Message", rcp.message.toStdString());
        }

        auto& newTx = transaction.getWtx();
        wallet().commitTransaction(newTx, /*value_map=*/{}, std::move(vOrderForm));

        DataStream ssTx;
        ssTx << TX_WITH_WITNESS(*newTx);
        transaction_array.append((const char*)ssTx.data(), ssTx.size());
    }

    // Add addresses / update labels that we've sent to the address book,
    // and emit coinsSent signal for each recipient
    for (const SendCoinsRecipient &rcp : transaction.getRecipients())
    {
        // [...]
        Q_EMIT coinsSent(this, rcp, transaction_array);
    }

    checkBalanceChanged(m_wallet->getBalances()); // update balance immediately, otherwise there could be a short noticeable delay until pollBalanceChanged hits
}
```

-----------------------------

In `src/rest.cpp`:

`DataStream` is used by Bitcoin Core's REST interface to serialize responses to
requests for headers in `rest_headers()`, blocks in `rest_block()`,
blockfilterheaders in `rest_filter_header()` blockfilters in
`rest_block_filter()`, tx's in `rest_tx()` utxo's in `rest_getutxos()` and
blockhashes in `rest_blockhash_by_height()`.


---------------------------

In `src/rpc/blockchain.cpp`:

`DataStream` is used to serialize the block header in the `getblockheader` rpc
command:

```cpp
    if (!fVerbose)
    {
        DataStream ssBlock{};
        ssBlock << pblockindex->GetBlockHeader();
        std::string strHex = HexStr(ssBlock);
        return strHex;
    }
```

and to deserialize the block data into a `CBlock` in the `getblock` rpc command:

```cpp
    const std::vector<uint8_t> block_data{GetRawBlockChecked(chainman.m_blockman, *pblockindex)};

    DataStream block_stream{block_data};
    CBlock block{};
    block_stream >> TX_WITH_WITNESS(block);

    return blockToJSON(chainman.m_blockman, block, *tip, *pblockindex, tx_verbosity);
```

------------------

In `src/rpc/mining.cpp`:

`DataStream` is used by the `generateblock` rpc for serializing the output hex
of a generated block when `generateblock` is called with `submit=false`:

```cpp
    UniValue obj(UniValue::VOBJ);
    obj.pushKV("hash", block_out->GetHash().GetHex());
    if (!process_new_block) {
        DataStream block_ser;
        block_ser << TX_WITH_WITNESS(*block_out);
        obj.pushKV("hex", HexStr(block_ser));
    }
```

----------------

In `src/rpc/rawtransaction.cpp`:

`DataStream` is used to serialize the resulting PSBT's that get passed to
`EncodeBase64()` and returned in
`combinepsbt`:

```cpp
static RPCHelpMan combinepsbt()
    // [ ..preparing merged_psbt.. ]

    DataStream ssTx{};
    ssTx << merged_psbt;
    return EncodeBase64(ssTx);
```

and `finalizepsbt()` which also might serialize the final transaction hex using
a `DataStream` of `TX_WITH_WITNESS(tx)` passed to `HexStr()`:

```cpp
static RPCHelpMan finalizepsbt()
{
    // Unserialize the transactions
    PartiallySignedTransaction psbtx;
    std::string error;
    if (!DecodeBase64PSBT(psbtx, request.params[0].get_str(), error)) {
        throw JSONRPCError(RPC_DESERIALIZATION_ERROR, strprintf("TX decode failed %s", error));
    }

    bool extract = request.params[1].isNull() || (!request.params[1].isNull() && request.params[1].get_bool());

    CMutableTransaction mtx;
    bool complete = FinalizeAndExtractPSBT(psbtx, mtx);

    UniValue result(UniValue::VOBJ);
    DataStream ssTx{};
    std::string result_str;

    if (complete && extract) {
        ssTx << TX_WITH_WITNESS(mtx);
        result_str = HexStr(ssTx);
        result.pushKV("hex", result_str);
    } else {
        ssTx << psbtx;
        result_str = EncodeBase64(ssTx.str());
        result.pushKV("psbt", result_str);
    }
    result.pushKV("complete", complete);

    return result;
}
```

and in `createpsbt`:

```cpp
static RPCHelpMan createpsbt()
{

    std::optional<bool> rbf;
    if (!request.params[3].isNull()) {
        rbf = request.params[3].get_bool();
    }
    CMutableTransaction rawTx = ConstructTransaction(request.params[0], request.params[1], request.params[2], rbf);

    // Make a blank psbt
    PartiallySignedTransaction psbtx;
    psbtx.tx = rawTx;
    for (unsigned int i = 0; i < rawTx.vin.size(); ++i) {
        psbtx.inputs.emplace_back();
    }
    for (unsigned int i = 0; i < rawTx.vout.size(); ++i) {
        psbtx.outputs.emplace_back();
    }

    // Serialize the PSBT
    DataStream ssTx{};
    ssTx << psbtx;

    return EncodeBase64(ssTx);
}
```

and in `utxoupdatepsbt()`:

```cpp
static RPCHelpMan utxoupdatepsbt()
{
    // Parse descriptors, if any.
    FlatSigningProvider provider;
    if (!request.params[1].isNull()) {
        auto descs = request.params[1].get_array();
        for (size_t i = 0; i < descs.size(); ++i) {
            EvalDescriptorStringOrObject(descs[i], provider);
        }
    }

    // We don't actually need private keys further on; hide them as a precaution.
    const PartiallySignedTransaction& psbtx = ProcessPSBT(
        request.params[0].get_str(),
        request.context,
        HidingSigningProvider(&provider, /*hide_secret=*/true, /*hide_origin=*/false),
        /*sighash_type=*/SIGHASH_ALL,
        /*finalize=*/false);

    DataStream ssTx{};
    ssTx << psbtx;
    return EncodeBase64(ssTx);
}
```

and `joinpsbts`:

```cpp
static RPCHelpMan joinpsbts()
    // [ ... prepare PartiallySignedTransaction shuffled psbt ... ]
    DataStream ssTx{};
    ssTx << shuffled_psbt;
    return EncodeBase64(ssTx);
}
```

and in `descriptorprocesspsbt`, which like `finalizepsbt` above might also
use `DataStream` for serializing a final transaction hex that gets passed to
`HexStr` and return if the psbt is complete:


```cpp
RPCHelpMan descriptorprocesspsbt()
    // [ ...prepare PartiallySignedTransaction &psbtx... ]
    DataStream ssTx{};
    ssTx << psbtx;

    UniValue result(UniValue::VOBJ);

    result.pushKV("psbt", EncodeBase64(ssTx));
    result.pushKV("complete", complete);
    if (complete) {
        CMutableTransaction mtx;
        PartiallySignedTransaction psbtx_copy = psbtx;
        CHECK_NONFATAL(FinalizeAndExtractPSBT(psbtx_copy, mtx));
        DataStream ssTx_final;
        ssTx_final << TX_WITH_WITNESS(mtx);
        result.pushKV("hex", HexStr(ssTx_final));
    }
    return result;
}
```

------

In `src/rpc/txoutproof`:

It is used for serializing the merkle inclusion proof in `gettxoutproof()`:

```cpp
static RPCHelpMan gettxoutproof()
{
    // [...]

    DataStream ssMB{};
    CMerkleBlock mb(block, setTxids);
    ssMB << mb;
    std::string strHex = HexStr(ssMB);
    return strHex;
}
```

and for deserializing the inclusion proof in `verifytxoutproof`:

```cpp
static RPCHelpMan verifytxoutproof()
{
    DataStream ssMB{ParseHexV(request.params[0], "proof")};
    CMerkleBlock merkleBlock;
    ssMB >> merkleBlock;

    // [ ... Validate merkleBlock ... ] 
}
```

-------

## Wallet

If wallet is unencrypted on disk, I feel there is no reason for us to be delicate about
how it is handled in memory.

### How wallet disk encryption happens

My understanding of the way that wallet encryption on disk works is that keys
and values are written and read by the wallet in crypted form, and they are
decrypted/encrypted in memory by `ScriptPubKeyMan`, for example:

```cpp
// [ Getting the private key for `CKeyID` address and storing the result 
//   in `CKey& keyOut` ]
bool LegacyDataSPKM::GetKey(const CKeyID &address, CKey& keyOut) const
{
    LOCK(cs_KeyStore);
    if (!m_storage.HasEncryptionKeys()) {
        return FillableSigningProvider::GetKey(address, keyOut);
    }

    // [ a map of crypted keys is created on legacy wallet load in
    //   `LoadLegacyWalletRecords()` ]
    CryptedKeyMap::const_iterator mi = mapCryptedKeys.find(address);
    if (mi != mapCryptedKeys.end())
    {
        const CPubKey &vchPubKey = (*mi).second.first;
        const std::vector<unsigned char> &vchCryptedSecret = (*mi).second.second;
        // [ Use the encryption key to decrypt the crypted key from the map. ]
        return m_storage.WithEncryptionKey([&](const CKeyingMaterial& encryption_key) {
            return DecryptKey(encryption_key, vchCryptedSecret, vchPubKey, keyOut);
        });
    }
    return false;
}
```

Because of this, we should not be vigilant about securing memory that contains
crypted data from the disk.

------

In `src/wallet/bdb.cpp`:

`BerkeleyDatabase::Rewrite()` uses `DataStream` to serialize the keys and values
from the existing db when rewriting the database. 

`BerkeleyDatabase::Rewrite()` is used when encrypting a wallet for the first
time, since, according to comments "BDB might keep bits of the unencrypted
private key in slack space in the database file." or when we detect a wallet
that was encrypted by version <0.5.0 and >0.4.0 of bitcoin, presumably because
of some horrible bug in those versions. (PR [#635](https://github.com/bitcoin/bitcoin/pull/635)

But at this point, the wallet has already been encrypted, and we won't be loading anything from slack space when rewriting the db, so no problems.

`BerkeleyCursor::Next()` is used when cursoring through the BDB, and stores the
retrieved Key and Value in DataStream's, if the wallet is encrypted these will
be crypted, if not, the keys are on disk in plaintext anyways.

`BerkeleyBatch::ReadKey()` retrieves the value for a given key in the database:

```cpp
bool BerkeleyBatch::ReadKey(DataStream&& key, DataStream& value)
{
    if (!pdb)
        return false;

    SafeDbt datKey(key.data(), key.size());

    SafeDbt datValue;
    int ret = pdb->get(activeTxn, datKey, datValue, 0);
    if (ret == 0 && datValue.get_data() != nullptr) {
        value.clear();
        value.write(SpanFromDbt(datValue));
        return true;
    }
    return false;
}
```

This is not a concern because like above, this data is either in plaintext on
disk, or it is being retrieved in crypted form and will be decrypted elsewhere
by SPKM.

Similar arguments to the above apply for `BerkeleyBatch::WriteKey()`,
`BerkeleyBatch::EraseKey()`, and `BerkeleyBatch::HasKey()`

-------

In `src/wallet/db.h`:

The same argument as above applies for keys and values used here in
`DatabaseBatch` functions Read, Write, Erase, Exists:

```cpp
/** RAII class that provides access to a WalletDatabase */
class DatabaseBatch
{
private:
    virtual bool ReadKey(DataStream&& key, DataStream& value) = 0;
    virtual bool WriteKey(DataStream&& key, DataStream&& value, bool overwrite = true) = 0;
    virtual bool EraseKey(DataStream&& key) = 0;
    virtual bool HasKey(DataStream&& key) = 0;

public:
    template <typename K, typename T>
    bool Read(const K& key, T& value)
    {
        DataStream ssKey{};
        ssKey.reserve(1000);
        ssKey << key;

        DataStream ssValue{};
        if (!ReadKey(std::move(ssKey), ssValue)) return false;
        try {
            ssValue >> value;
            return true;
        } catch (const std::exception&) {
            return false;
        }
    }

    template <typename K, typename T>
    bool Write(const K& key, const T& value, bool fOverwrite = true)
    {
        DataStream ssKey{};
        ssKey.reserve(1000);
        ssKey << key;

        DataStream ssValue{};
        ssValue.reserve(10000);
        ssValue << value;

        return WriteKey(std::move(ssKey), std::move(ssValue), fOverwrite);
    }

    template <typename K>
    bool Erase(const K& key)
    {
        DataStream ssKey{};
        ssKey.reserve(1000);
        ssKey << key;

        return EraseKey(std::move(ssKey));
    }

    template <typename K>
    bool Exists(const K& key)
    {
        DataStream ssKey{};
        ssKey.reserve(1000);
        ssKey << key;

        return HasKey(std::move(ssKey));
    }
};
```

-----

In `dump.cpp`:

`DumpWallet()` invoked by doing `bitcoin-wallet dump` prints all keys and values
in a wallet, but does not decrypt them:

```cpp
// [ I've editorialized this codeblock to focus on the part I'm interested in ]
bool DumpWallet(const ArgsManager& args, WalletDatabase& db, bilingual_str& error)
{
    // [.. handle dump file stuff ..]
    std::unique_ptr<DatabaseBatch> batch = db.MakeBatch();
    std::unique_ptr<DatabaseCursor> cursor = batch->GetNewCursor();

    // Read the records
    while (true) {
        DataStream ss_key{};
        DataStream ss_value{};
        DatabaseCursor::Status status = cursor->Next(ss_key, ss_value);
        if (status == DatabaseCursor::Status::DONE) {
            ret = true;
            break;
        } else if (status == DatabaseCursor::Status::FAIL) {
            error = _("Error reading next record from wallet database");
            ret = false;
            break;
        }
        std::string key_str = HexStr(ss_key);
        std::string value_str = HexStr(ss_value);
        line = strprintf("%s,%s\n", key_str, value_str);
        dump_file.write(line.data(), line.size());
        hasher << Span{line};
    }

    cursor.reset();
    batch.reset();

    // [.. handle dump file stuff ..]

    return ret;
}
```

----------------

In `src/wallet/migrate.cpp` & `src/wallet/migrate.h`:

`BerkeleyRO*` exist so that we can read keys and values from a legacy bdb wallet
when migrating so that we can drop the bdb wallet entirely in the future, the
same as in `db.h` applies here, all the ekys and values read in
`BerkeleyROBatch::ReadKey()`, `HasKey` and `BerkeleyROCursor::Next()` are
crypted as in their non-RO counterparts found above.

---------------------

In `src/wallet/rpc/backup.cpp`:

`DataStream` is used to serialize the transaction inclusion proof argument to
the `importprunedfunds()` rpc which lets pruned nodes import funds without
rescanning if they have inclusion proofs similar to above in
`src/rpc/txoutproof.cpp`.

```cpp
RPCHelpMan importprunedfunds()
{
    std::shared_ptr<CWallet> const pwallet = GetWalletForJSONRPCRequest(request);
    if (!pwallet) return UniValue::VNULL;

    CMutableTransaction tx;
    if (!DecodeHexTx(tx, request.params[0].get_str())) {
        throw JSONRPCError(RPC_DESERIALIZATION_ERROR, "TX decode failed. Make sure the tx has at least one input.");
    }
    uint256 hashTx = tx.GetHash();

    DataStream ssMB{ParseHexV(request.params[1], "proof")};
    CMerkleBlock merkleBlock;
    ssMB >> merkleBlock;

    // [.. validate merkle block ..]

    // [.. add transactions to wallet.. ]
}
```

------------------------


In `src/wallet/rpc/txoutproof.cpp`:

In `static Univalue FinishTransaction` used by the rpc's `send()` and
`sendall()`, DataStream is used to serialize the completed psbt and print it if
either was called with `psbt=true`.

In `bumpfee_helper` when invoked as the `psbtbumpfee` rpc, a DataStream is used
to serialize the unsigned psbt of the new transaction that gets returned.

In `walletprocesspsbt()` `DataStream is used to serialize the PSBT, and if the
transaction is complete to serialize the final transaction:

```cpp
RPCHelpMan walletprocesspsbt()
{
    // [...prepare psbtx...]

    UniValue result(UniValue::VOBJ);
    DataStream ssTx{};
    ssTx << psbtx;
    result.pushKV("psbt", EncodeBase64(ssTx.str()));
    result.pushKV("complete", complete);
    if (complete) {
        CMutableTransaction mtx;
        // Returns true if complete, which we already think it is.
        CHECK_NONFATAL(FinalizeAndExtractPSBT(psbtx, mtx));
        DataStream ssTx_final;
        ssTx_final << TX_WITH_WITNESS(mtx);
        result.pushKV("hex", HexStr(ssTx_final));
    }

    return result;
}
```

in the `walletcreatefundedpsbt` rpc, it contains the serialized psbt

--------------------

In `src/wallet/salvage.cpp`:

`DataStream` is used during `RecoverDatabaseFile()` when trying to recover key
and value data from a db, nothing gets decrypted here:

```cpp
    for (KeyValPair& row : salvagedData)
    {
        /* Filter for only private key type KV pairs to be added to the salvaged wallet */
        DataStream ssKey{row.first};
        DataStream ssValue(row.second);
        std::string strType, strErr;

        // We only care about KEY, MASTER_KEY, CRYPTED_KEY, and HDCHAIN types
        ssKey >> strType;
        bool fReadOK = false;
        // [ The below just load the crypted form of the key, no decryption. ]
        if (strType == DBKeys::KEY) {
            fReadOK = LoadKey(&dummyWallet, ssKey, ssValue, strErr);
        } else if (strType == DBKeys::CRYPTED_KEY) {
            fReadOK = LoadCryptedKey(&dummyWallet, ssKey, ssValue, strErr);
        } else if (strType == DBKeys::MASTER_KEY) {
            fReadOK = LoadEncryptionKey(&dummyWallet, ssKey, ssValue, strErr);
        } else if (strType == DBKeys::HDCHAIN) {
            fReadOK = LoadHDChain(&dummyWallet, ssValue, strErr);
        } else {
            continue;
        }
```

--------

In `src/wallet/sqlite.cpp` & `src/wallet/sqlite.h`:

`SQLiteBatch::ReadKey`, WriteKey, etc. and `SQLiteCursor::next` mirror berkeley
and berkeley RO batches above, again: all reading crypted data from disk, data
gets decrypted somewhere else, once it's far away from it's humble `DataStream`
beginnings.

---------

In `src/wallet/wallet.cpp`:

Used in `MigrateToSQLite()` when iterating through BDB with the bdb cursor:

```cpp
bool CWallet::MigrateToSQLite(bilingual_str& error)
{
    while (true) {
        DataStream ss_key{};
        DataStream ss_value{};
        status = cursor->Next(ss_key, ss_value);
        if (status != DatabaseCursor::Status::MORE) {
            break;
        }
        SerializeData key(ss_key.begin(), ss_key.end());
        SerializeData value(ss_value.begin(), ss_value.end());
        records.emplace_back(key, value);
    }
    cursor.reset();
    batch.reset();

    // [....insert the records in to the new sqlite db...] 
}
```

---------------------

In `src/wallet/walletdb.cpp`:

Most of the arguments above about encrypted data on disk hold true here...

```cpp
bool WalletBatch::IsEncrypted()
{
    DataStream prefix;
    prefix << DBKeys::MASTER_KEY;
    if (auto cursor = m_batch->GetNewPrefixCursor(prefix)) {
        DataStream k, v;
        if (cursor->Next(k, v) == DatabaseCursor::Status::MORE) return true;
    }
    return false;
}
```

master encryption keys are stored in the db (in crypted form!), this is just
serializing the master key prefix and then searching for such an entry, no
secrets in the prefix!

`LoadKey` and `LoadCryptedKey` don't do any decryption of the keys. LoadKey just
grabs all the keys that have the unencrypted key prefix as-is, and
loadcryptedkey loads keys with the crypted key prefix as-is. The story is almost
identical with `LoadHDChain` and `LoadEncryptionKey` and the same with the rest
of the `LoadRecords()`, `LoadLegacyWalletRecoreds()`, and
`LoadDescriptorWalletRecords()` circus.

I definitely got tired and slacked a little while reviewing `walletdb.cpp` but
I'm pretty confident about this.

-------------------------

In `src/zmq/zmpqpublishnotifier.cpp`:

```cpp
bool CZMQPublishRawTransactionNotifier::NotifyTransaction(const CTransaction &transaction)
{
    uint256 hash = transaction.GetHash();
    LogDebug(BCLog::ZMQ, "Publish rawtx %s to %s\n", hash.GetHex(), this->address);
    DataStream ss;
    ss << TX_WITH_WITNESS(transaction);
    return SendZmqMessage(MSG_RAWTX, &(*ss.begin()), ss.size());
}`
```

Used to serialize the raw transaction that we are sending a ZeroMQ notification
about.

# Not done: `SerializeData`

Let's also look at every instance of `SerializeData` being used, since this is a
vector of bytes, with the `zero_after_free_allocator`:

-----------

In `src/wallet/migrate.cpp`:

Used in the `BerkeleyROBatch::*` family of `ReadKey()`, `HasKey()` to represent
the vector portion of the same `DataStream`'s I used and described above that
have just crypted key data, or unencrypted data *if* the wallet itself is
unencrypted, e.g.:

```cpp

bool BerkeleyROBatch::ReadKey(DataStream&& key, DataStream& value)
{
    SerializeData key_data{key.begin(), key.end()};
    const auto it{m_database.m_records.find(key_data)};
    if (it == m_database.m_records.end()) {
        return false;
    }
    auto val = it->second;
    value.clear();
    value.write(Span(val));
    return true;
}
```

-----------

In `src/wallet/wallet.cpp`:

Used in `MigrateToSQLite()` as discussed above to store the `DataStream` data
described above:

```cpp
while (true) {
    DataStream ss_key{};
    DataStream ss_value{};
    status = cursor->Next(ss_key, ss_value);
    if (status != DatabaseCursor::Status::MORE) {
        break;
    }
    SerializeData key(ss_key.begin(), ss_key.end());
    SerializeData value(ss_value.begin(), ss_value.end());
    records.emplace_back(key, value);
}
```

</details>

[^1]: Master at the time of my testing was: [`6d546336e800`](https://github.com/bitcoin/bitcoin/commit/6d546336e800)
[^2]: Maybe as much as 50x: https://github.com/bitcoin/bitcoin/pull/740#issuecomment-3337245
[^3]: I am assuming this from the discussion, github seems to not have dead
      commits for old pr's
