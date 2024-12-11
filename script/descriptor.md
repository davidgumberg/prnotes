_All code comments in `[]` are my own._

# Descriptor Wallets

    For a high level overview of descriptor wallets see `doc/descriptors.md` in the `bitcoin/bitcoin` repo, this are just my notes on the data structures and methods associated with descriptors.



## `struct Descriptor`

`struct Descriptor` is a pure virtual base class that describes the interface
for parsed descripter objects, the existing comments in `src/descriptor.h` do a
good job of describing the interface:


<details>


<summary>struct Descriptor</summary>


```cpp
struct Descriptor {
    virtual ~Descriptor() = default;

    // [ This doesn't cohere with my understanding of ranged descriptors. ]
    /** Whether the expansion of this descriptor depends on the position. */
    virtual bool IsRange() const = 0;

    // [ What is meant by "ignoring lack of private keys"... ]
    /** Whether this descriptor has all information about signing ignoring lack of private keys. 
     *  This is true for all descriptors except ones that use `raw` or `addr` constructions. */
    virtual bool IsSolvable() const = 0;

    /** Convert the descriptor back to a string, undoing parsing. */
    virtual std::string ToString(bool compat_format=false) const = 0;

    /** Whether this descriptor will return one scriptPubKey or multiple (aka is or is not combo) */
    virtual bool IsSingleType() const = 0;

    // [ String including the private keys to solve? ]
    /** Convert the descriptor to a private string. This fails if the provided provider does not have the relevant private keys. */
    virtual bool ToPrivateString(const SigningProvider& provider, std::string& out) const = 0;

    /** Convert the descriptor to a normalized string. Normalized descriptors have the xpub at the last hardened step. This fails if the provided provider does not have the private keys to derive that xpub. */
    virtual bool ToNormalizedString(const SigningProvider& provider, std::string& out, const DescriptorCache* cache = nullptr) const = 0;

    // [ Why don't unranged descriptors take a pos param? Maybe I am
    //   misunderstanding here and all xpub's even if they have a * range
    //   are ranged, and what is meant by unranged is all scripts which don't
    //   have *any* derivations.... ]
    /** Expand a descriptor at a specified position.
     *
     * @param[in] pos The position at which to expand the descriptor. If IsRange() is false, this is ignored.
     * @param[in] provider The provider to query for private keys in case of hardened derivation.
     * @param[out] output_scripts The expanded scriptPubKeys.
     * @param[out] out Scripts and public keys necessary for solving the expanded scriptPubKeys (may be equal to `provider`).
     * @param[out] write_cache Cache data necessary to evaluate the descriptor at this point without access to private keys.
     */
    virtual bool Expand(int pos, const SigningProvider& provider, std::vector<CScript>& output_scripts, FlatSigningProvider& out, DescriptorCache* write_cache = nullptr) const = 0;

    /** Expand a descriptor at a specified position using cached expansion data.
     *
     * @param[in] pos The position at which to expand the descriptor. If IsRange() is false, this is ignored.
     * @param[in] read_cache Cached expansion data.
     * @param[out] output_scripts The expanded scriptPubKeys.
     * @param[out] out Scripts and public keys necessary for solving the expanded scriptPubKeys (may be equal to `provider`).
     */
    virtual bool ExpandFromCache(int pos, const DescriptorCache& read_cache, std::vector<CScript>& output_scripts, FlatSigningProvider& out) const = 0;

    /** Expand the private key for a descriptor at a specified position, if possible.
     *
     * @param[in] pos The position at which to expand the descriptor. If IsRange() is false, this is ignored.
     * @param[in] provider The provider to query for the private keys.
     * @param[out] out Any private keys available for the specified `pos`.
     */
    virtual void ExpandPrivate(int pos, const SigningProvider& provider, FlatSigningProvider& out) const = 0;

    /** @return The OutputType of the scriptPubKey(s) produced by this descriptor. Or nullopt if indeterminate (multiple or none) */
    virtual std::optional<OutputType> GetOutputType() const = 0;

    /** Get the size of the scriptPubKey for this descriptor. */
    virtual std::optional<int64_t> ScriptSize() const = 0;

    /** Get the maximum size of a satisfaction for this descriptor, in weight units.
     *
     * @param use_max_sig Whether to assume ECDSA signatures will have a high-r.
     */
    virtual std::optional<int64_t> MaxSatisfactionWeight(bool use_max_sig) const = 0;

    /** Get the maximum size number of stack elements for satisfying this descriptor. */
    virtual std::optional<int64_t> MaxSatisfactionElems() const = 0;

    /** Return all (extended) public keys for this descriptor, including any from subdescriptors.
     *
     * @param[out] pubkeys Any public keys
     * @param[out] ext_pubs Any extended public keys
     */
    virtual void GetPubKeys(std::set<CPubKey>& pubkeys, std::set<CExtPubKey>& ext_pubs) const = 0;
};
```

</details>


### `DescriptorImpl`

`class DescriptorImpl` is the base class of all `Descriptor` implementations,
why both `Descriptor` `DescriptorImpl` needed if both are abstract base classes?

#### Params

Some top-level descriptors can take SCRIPT expressions

```cpp
const std::vector<std::unique_ptr<PubkeyProvider>> m_pubkey_args;
//! The string name of the descriptor function.
const std::string m_name;

//! The sub-descriptor arguments (empty for everything but SH and WSH).
//! In doc/descriptors.m this is referred to as SCRIPT expressions sh(SCRIPT)
//! and wsh(SCRIPT), and distinct from KEY expressions and ADDR expressions.
//! Subdescriptors can only ever generate a single script.
const std::vector<std::unique_ptr<DescriptorImpl>> m_subdescriptor_args;
```

Sub-descriptor arguments used for `sh` and `wsh` inputs 
 
It implements same of the pure virtual functions in the `Descriptor` base class:

`IsSolvable()`:

```cpp
bool IsSolvable() const override
{
    for (const auto& arg : m_subdescriptor_args) {
        if (!arg->IsSolvable()) return false;
    }
    return true;
}
```

#### Expand*

`DescriptorImpl::ExpandHelper()` is invoked by the `Expand`, `ExpandFromCache`,
and `ExpandPrivate` functions that every `DescriptorImpl` provides for retrieving the getting the 

```cpp
    // NOLINTNEXTLINE(misc-no-recursion)
    bool ExpandHelper(int pos, const SigningProvider& arg, const DescriptorCache* read_cache, std::vector<CScript>& output_scripts, FlatSigningProvider& out, DescriptorCache* write_cache) const
    {
        // [ KeyOriginInfo is used to encode HD wallet keypaths, stores the
        //   first 4 bytes of the HASH160 of the root/parent key of the path,
        //   and a vector of bytes representing the BIP32 derivation path
        //   (i think?) in the format used in PSBT's, described in BIP174:
        // 
        //     "The derivation path is represented as 32-bit little endian
        //      unsigned integer indexes concatenated with each other." 
        //  
        //   Introduced in [#13723](https://github.com/bitcoin/bitcoin/pull/13723)
        //   
        //   CPubKey seems to be just a vector of the serialized keydata with
        //   helper member functions. ]
        std::vector<std::pair<CPubKey, KeyOriginInfo>> entries;
        entries.reserve(m_pubkey_args.size());

        // Construct temporary data in `entries`, `subscripts`, and `subprovider` to avoid producing output in case of failure.
        for (const auto& p : m_pubkey_args) {
            // [ Emplace a default constructed entry to the end of the entry
            //   vector. ]
            entries.emplace_back();
            
            // [ Derive the pubkey at a given pos for the pubkey provider
            //   (ConstPubKeyProvider will ignore the pos argument)
            //   using the signing provider `arg` if the pk provider is
            //   hardened/"derived" (see BIP32PubkeyProvider::IsHardened()),
            //   storing the result in the back() entry of the vector.
            //   using the given read and write cache. ]
            if (!p->GetPubKey(pos, arg, entries.back().first, entries.back().second, read_cache, write_cache)) return false;
        }

        std::vector<CScript> subscripts;
        // [ We'll want to get the output flatsigningprovider that the nested
        //   call gives us and merge it with the signing provider that we send
        //   back. ]
        FlatSigningProvider subprovider;
        for (const auto& subarg : m_subdescriptor_args) {
            std::vector<CScript> outscripts;
            if (!subarg->ExpandHelper(pos, arg, read_cache, outscripts, subprovider, write_cache)) return false;
            // [ Why? ]
            assert(outscripts.size() == 1);
            subscripts.emplace_back(std::move(outscripts[0]));
        }
        out.Merge(std::move(subprovider));

        std::vector<CPubKey> pubkeys;
        pubkeys.reserve(entries.size());
        for (auto& entry : entries) {
            pubkeys.push_back(entry.first);
            out.origins.emplace(entry.first.GetID(), std::make_pair<CPubKey, KeyOriginInfo>(CPubKey(entry.first), std::move(entry.second)));
        }

        // [ Make the SPK's for the given pubkeys and subscripts using the out
        //   signing provider ] 
        output_scripts = MakeScripts(pubkeys, Span{subscripts}, out);
        return true;
    }
```


### `PKDescriptor`

Let's look at a simple example of a descriptor class, the pubkey descriptor:

`class PKDescriptor`:

```cpp
/** A parsed pk(P) descriptor. */
class PKDescriptor final : public DescriptorImpl
{
private:
    // [ Whether or not the descriptor's PubkeyProvider's CPubKey data is xonly,
    //   feels like maybe this should be handled by either CPubKey or PubkeyProvider? ]
    const bool m_xonly;
protected:

    // [ MakeScripts (interface inherited from `DescriptorImpl`) is used in
    //   `DescriptorImpl::ExpandHelper()` which  I have annotated above. ]
    std::vector<CScript> MakeScripts(const std::vector<CPubKey>& keys, Span<const CScript>, FlatSigningProvider&) const override
    {
        if (m_xonly) {
            CScript script = CScript() << ToByteVector(XOnlyPubKey(keys[0])) << OP_CHECKSIG;
            return Vector(std::move(script));
        } else {
            return Vector(GetScriptForRawPubKey(keys[0]));
        }
    }
public:
    PKDescriptor(std::unique_ptr<PubkeyProvider> prov, bool xonly = false) : DescriptorImpl(Vector(std::move(prov)), "pk"), m_xonly(xonly) {}
    bool IsSingleType() const final { return true; }

    std::optional<int64_t> ScriptSize() const override {
        return 1 + (m_xonly ? 32 : m_pubkey_args[0]->GetSize()) + 1;
    }

    std::optional<int64_t> MaxSatSize(bool use_max_sig) const override {
        const auto ecdsa_sig_size = use_max_sig ? 72 : 71;
        return 1 + (m_xonly ? 65 : ecdsa_sig_size);
    }

    std::optional<int64_t> MaxSatisfactionWeight(bool use_max_sig) const override {
        return *MaxSatSize(use_max_sig) * WITNESS_SCALE_FACTOR;
    }

    std::optional<int64_t> MaxSatisfactionElems() const override { return 1; }

    std::unique_ptr<DescriptorImpl> Clone() const override
    {
        return std::make_unique<PKDescriptor>(m_pubkey_args.at(0)->Clone(), m_xonly);
    }
};
```
