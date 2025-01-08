# `struct PubkeyProvider`

`PubkeyProvider` defines a virtual base "Interface for public key objects in descriptors."

It has a private member `m_expr_index` that represents the index of a key expression in
a descriptor.

<details>

<summary>

Definition of `struct PubkeyProvider`:

</summary>

```cpp
/** Interface for public key objects in descriptors. */
struct PubkeyProvider
{
protected:
    //! Index of this key expression in the descriptor
    //! E.g. If this PubkeyProvider is key1 in multi(2, key1, key2, key3), then m_expr_index = 0
    uint32_t m_expr_index;

public:
    explicit PubkeyProvider(uint32_t exp_index) : m_expr_index(exp_index) {}

    virtual ~PubkeyProvider() = default;

    /** Compare two public keys represented by this provider.
     * Used by the Miniscript descriptors to check for duplicate keys in the script.
     */
    bool operator<(PubkeyProvider& other) const {
        CPubKey a, b;
        SigningProvider dummy;
        KeyOriginInfo dummy_info;

        GetPubKey(0, dummy, a, dummy_info);
        other.GetPubKey(0, dummy, b, dummy_info);

        return a < b;
    }

    /** Derive a public key.
     *  read_cache is the cache to read keys from (if not nullptr)
     *  write_cache is the cache to write keys to (if not nullptr)
     *  Caches are not exclusive but this is not tested. Currently we use them exclusively
     */
    virtual bool GetPubKey(int pos, const SigningProvider& arg, CPubKey& key, KeyOriginInfo& info, const DescriptorCache* read_cache = nullptr, DescriptorCache* write_cache = nullptr) const = 0;

    /** Whether this represent multiple public keys at different positions. */
    virtual bool IsRange() const = 0;

    /** Get the size of the generated public key(s) in bytes (33 or 65). */
    virtual size_t GetSize() const = 0;

    enum class StringType {
        PUBLIC,
        COMPAT // string calculation that mustn't change over time to stay compatible with previous software versions
    };

    /** Get the descriptor string form. */
    virtual std::string ToString(StringType type=StringType::PUBLIC) const = 0;

    /** Get the descriptor string form including private data (if available in arg). */
    virtual bool ToPrivateString(const SigningProvider& arg, std::string& out) const = 0;

    /** Get the descriptor string form with the xpub at the last hardened derivation,
     *  and always use h for hardened derivation.
     */
    virtual bool ToNormalizedString(const SigningProvider& arg, std::string& out, const DescriptorCache* cache = nullptr) const = 0;

    /** Derive a private key, if private data is available in arg. */
    virtual bool GetPrivKey(int pos, const SigningProvider& arg, CKey& key) const = 0;

    /** Return the non-extended public key for this PubkeyProvider, if it has one. */
    virtual std::optional<CPubKey> GetRootPubKey() const = 0;
    /** Return the extended public key for this PubkeyProvider, if it has one. */
    virtual std::optional<CExtPubKey> GetRootExtPubKey() const = 0;

    /** Make a deep copy of this PubkeyProvider */
    virtual std::unique_ptr<PubkeyProvider> Clone() const = 0;
};
```
</details>

It's easier to understand `PubkeyProvider` by looking at one of its concrete
implementations...

## `class ConstPubkeyProvider final : public PubkeyProvider`

`ConstPubkeyProvider` is: "An object representing a parsed constant public key in a descriptor."

It has two additional parameters `CPubKey m_pubkey` and `bool m_xonly`:

```cpp
/** An object representing a parsed constant public key in a descriptor. */
class ConstPubkeyProvider final : public PubkeyProvider
{
    CPubKey m_pubkey;
    bool m_xonly;

public:
    // [ Constructor]
    ConstPubkeyProvider(uint32_t exp_index, const CPubKey& pubkey, bool xonly) : PubkeyProvider(exp_index), m_pubkey(pubkey), m_xonly(xonly) {}
    // [...]
};
```

Of immediate interest is it's implementation of `PubkeyProvider::GetPubKey()`,
which takes a position and `const SigningProvider&`, and  provider, key, and 

```cpp
class ConstPubkeyProvider final : public PubkeyProvider
{
public:
    bool GetPubKey(int pos, const SigningProvider& arg, CPubKey& key, KeyOriginInfo& info, const DescriptorCache* read_cache = nullptr, DescriptorCache* write_cache = nullptr) const override
    {
        key = m_pubkey;
        info.path.clear();
        CKeyID keyid = m_pubkey.GetID();
        std::copy(keyid.begin(), keyid.begin() + sizeof(info.fingerprint), info.fingerprint);
        return true;
    }
};
```

```cpp
    bool IsRange() const override { return false; }
    size_t GetSize() const override { return m_pubkey.size(); }
    std::string ToString(StringType type) const override { return m_xonly ? HexStr(m_pubkey).substr(2) : HexStr(m_pubkey); }
    bool ToPrivateString(const SigningProvider& arg, std::string& ret) const override
    {
        CKey key;
        if (m_xonly) {
            for (const auto& keyid : XOnlyPubKey(m_pubkey).GetKeyIDs()) {
                arg.GetKey(keyid, key);
                if (key.IsValid()) break;
            }
        } else {
            arg.GetKey(m_pubkey.GetID(), key);
        }
        if (!key.IsValid()) return false;
        ret = EncodeSecret(key);
        return true;
    }
    bool ToNormalizedString(const SigningProvider& arg, std::string& ret, const DescriptorCache* cache) const override
    {
        ret = ToString(StringType::PUBLIC);
        return true;
    }
    bool GetPrivKey(int pos, const SigningProvider& arg, CKey& key) const override
    {
        return arg.GetKey(m_pubkey.GetID(), key);
    }
    std::optional<CPubKey> GetRootPubKey() const override
    {
        return m_pubkey;
    }
    std::optional<CExtPubKey> GetRootExtPubKey() const override
    {
        return std::nullopt;
    }
    std::unique_ptr<PubkeyProvider> Clone() const override
    {
        return std::make_unique<ConstPubkeyProvider>(m_expr_index, m_pubkey, m_xonly);
    }
};
```

# `class CPubKey`

```cpp
/** An encapsulated public key. */
class CPubKey
{
public:
    /**
     * secp256k1:
     */
    static constexpr unsigned int SIZE                   = 65;
    static constexpr unsigned int COMPRESSED_SIZE        = 33;
    static constexpr unsigned int SIGNATURE_SIZE         = 72;
    static constexpr unsigned int COMPACT_SIGNATURE_SIZE = 65;
private:

    /**
     * Just store the serialized data.
     * Its length can very cheaply be computed from the first byte.
     */
    unsigned char vch[SIZE];

public:

    //! Construct a public key from a byte vector.
    explicit CPubKey(Span<const uint8_t> _vch)
    {
        Set(_vch.begin(), _vch.end());
    }
```

# `class XOnlyPubKey`

```cpp
class XOnlyPubKey
{
private:
    uint256 m_keydata;

public:
    CPubKey GetEvenCorrespondingCPubKey() const;

    const unsigned char& operator[](int pos) const { return *(m_keydata.begin() + pos); }
    static constexpr size_t size() { return decltype(m_keydata)::size(); }
    const unsigned char* data() const { return m_keydata.begin(); }
    const unsigned char* begin() const { return m_keydata.begin(); }
    const unsigned char* end() const { return m_keydata.end(); }
    unsigned char* data() { return m_keydata.begin(); }
    unsigned char* begin() { return m_keydata.begin(); }
    unsigned char* end() { return m_keydata.end(); }
    bool operator==(const XOnlyPubKey& other) const { return m_keydata == other.m_keydata; }
    bool operator!=(const XOnlyPubKey& other) const { return m_keydata != other.m_keydata; }
    bool operator<(const XOnlyPubKey& other) const { return m_keydata < other.m_keydata; }
};
```

Private member `uint256 m_keydata`

Q: Since any x-coordinate valid point if `uint256` only has 32 bytes, how is the
[evenness / parity](https://crypto.stackexchange.com/a/98364) bit of the
y-coordinate represented in an `XOnlyPubKey`?

A: Short answer seems to be that isn't, this class is used for representing just
an x-coordinate.

`XOnlyPubKey::GetEvenCorrespondingCPubKey()` provides a way to "retrieve" the
even CPubKey of a given x-coordinate by constructing a compressed CPubKey with
the `0x02` even y-coordinate prefix.

```cpp
CPubKey XOnlyPubKey::GetEvenCorrespondingCPubKey() const
{
    // [ Initialize an array of 33 unsigned chars and first entry to 0x02.
    //   https://en.cppreference.com/w/c/language/array_initialization . ] 
    unsigned char full_key[CPubKey::COMPRESSED_SIZE] = {0x02};
            
    // [ Copy from begin() to end() of m_keydata, into full_key starting at
    //   full_key[1]. m_keydata is exactly 32 bytes and full_key is 33 bytes. ]
    std::copy(begin(), end(), full_key + 1);

    // [ Return a pubkey constructed from the full_key array which gets
    //   implicitly constructed into a span of uint8_t. ]
    return CPubKey{full_key};
}
```

# `struct KeyOriginInfo`

Quoting from [`doc/descriptors.md`](https://github.com/bitcoin/bitcoin/blob/master/doc/descriptors.md),

In descriptors expressions, keys may begin with optional origin information,
consisting of:
- An open bracket `[`
- Exactly 8 hex characters for the fingerprint of the key where the derivation
  starts (see BIP32 for details)
- Followed by zero or more `/NUM` or `/NUM'` path elements to indicate
  unhardened or hardened derivation steps between the fingerprint and the key or
  xpub/xprv root that follows
- A closing bracket `]` Followed by the actual key consisting of
    - ...

For example:

`pkh([d34db33f/44'/0'/0']xpub6ERApfZwUNrhLCkDtcHTcxd75RbzS1ed54G1LkBUHQVHQKqhMkhgbmJbZRkrgZw4koxb5JaHWkY4ALHY2grBGRjaDMzQLcgJvLJuZZvRcEL/1/*)`
describes a set of P2PKH outputs, but additionally specifies that the specified
xpub is a child of a master with fingerprint d34db33f, and derived using path
`44'/0'/0'`.

From `src/script/keyorigin.h`:

```cpp
struct KeyOriginInfo
{
    unsigned char fingerprint[4]; //!< First 32 bits of the Hash160 of the public key at the root of the path
    std::vector<uint32_t> path;
};
```
