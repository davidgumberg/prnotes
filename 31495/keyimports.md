# Functions of interest in key importing

This is mainly looking at key importing in legacy spkm's.

What I'm most interested in are `mapScript` and setWatchOnly, in particular I'm
confused about why functions with names like `AddWatchOnly*` that take
`CScript()`'s write them to the spkm's `mapScript`, and I'm also confused about
where solving information for the script's found in `mapScripts` come from.. My
current vague guess is that they *are* watch-only in mapScript, and solving data
is stored elsewhere?

I have good reason to suspect that `setWatchOnly` really is just the set of
scripts and/or keys that we definitely don't have solving data for, and are
totally just watching :). it was added in
[#4045](https://github.com/bitcoin/bitcoin/pull/4045) (the discussion there is
really interesting! let alone the fact that this patch was carried through by
four separate authors, [#2121](https://github.com/bitcoin/bitcoin/pull/2121)) ->
[#2861](https://github.com/bitcoin/bitcoin/pull/2861) ->
[#3383](https://github.com/bitcoin/bitcoin/pull/3383) -> [#4045](https://github.com/bitcoin/bitcoin/pull/4045))

Another thing to note is that `LegacyScriptPubKeyMan` is a descendant of
`LegacyDataSPKM`. As I understand, the former is the true legacy spkm, and the
latter is the read only post-legacy deprecation handler of legacy spkm's during
migration. `LegacyDataSPKM` inherits multiply from `ScriptPubKeyMan` and
`FillableSigningProvider`.

It also seems that solving data is not explicitly linked with scripts on import,
we just keep a map of the script and it's Hash160, and I assume find the right
keys later when it's time to sign.

Relevant comments re: my `mapScripts` confusion:

>> What sorts of scripts are being stored in this map? Input scripts, output
>> scripts, redeemscripts, witness programs, witness scripts, all of the above,
>> a subset of the above, etc.?
>
>  All of the above. All types of scripts are stored in mapScripts, without
>  contexts. Thus all scripts in mapScripts can appear in any context. That is
>  the insanity of legacy IsMine.

(https://github.com/bitcoin/bitcoin/pull/30328#discussion_r1844645672k)

```cpp
// [ Helper used by wallet rpc's like importmulti, I've editorialized to remove
//   some error checking and make reading simpler. ]
static UniValue ProcessImport(CWallet& wallet, const UniValue& data, const int64_t timestamp) EXCLUSIVE_LOCKS_REQUIRED(wallet.cs_wallet)
{
    // [ aka change.] 
    const bool internal = data.exists("internal") ? data["internal"].get_bool() : false;
    const std::string label{LabelFromValue(data["label"])};
    const bool add_keypool = data.exists("keypool") ? data["keypool"].get_bool() : false;

    ImportData import_data;
    std::map<CKeyID, CPubKey> pubkey_map;
    std::map<CKeyID, CKey> privkey_map;
    std::set<CScript> script_pub_keys;
    std::vector<std::pair<CKeyID, bool>> ordered_pubkeys;
    bool have_solving_data;

    // [ For now we can treat these import functions as black boxes that
    //   fill all the data structures declared above and passed by ref. ]
    if (data.exists("scriptPubKey")) { ProcessImportLegacy(import_data, pubkey_map, privkey_map, script_pub_keys, have_solving_data, data, ordered_pubkeys);
    } else if (data.exists("desc")) {
        ProcessImportDescriptor(import_data, pubkey_map, privkey_map, script_pub_keys, have_solving_data, data, ordered_pubkeys);

    // Check whether we have any work to do
    for (const CScript& script : script_pub_keys) {
        if (wallet.IsMine(script) & ISMINE_SPENDABLE) {
            throw JSONRPCError(RPC_WALLET_ERROR, "The wallet already contains the private key for this address or script (\"" + HexStr(script) + "\")");
        }
    }

    // All good, time to import
    wallet.MarkDirty();

    // [ annotated these four horsemen below. ]
    wallet.ImportScripts(import_data.import_scripts, timestamp)
    wallet.ImportPrivKeys(privkey_map, timestamp)
    wallet.ImportPubKeys(ordered_pubkeys, pubkey_map, import_data.key_origins, add_keypool, timestamp)
    wallet.ImportScriptPubKeys(label, script_pub_keys, have_solving_data, !internal, timestamp)

    UniValue result(UniValue::VOBJ);
    result.pushKV("success", UniValue(true));
    return result;
}
```

## The four imports

### ImportScripts

```cpp
// [ Just grabs the LegacyScriptPubKeyMan and passes it down, they all look like
//   this, so I'll omit the `CWallet::` wrapper and just reproduce the
//   legacyscriptpubkeyman member function. ]
bool CWallet::ImportScripts(const std::set<CScript> scripts, int64_t timestamp)
{
    auto spk_man = GetLegacyScriptPubKeyMan();
    if (!spk_man) {
        return false;
    }
    LOCK(spk_man->cs_KeyStore);
    return spk_man->ImportScripts(scripts, timestamp);
}
```

```cpp
bool LegacyScriptPubKeyMan::ImportScripts(const std::set<CScript> scripts, int64_t timestamp)
{
    // [ Write batch for the db ]
    WalletBatch batch(m_storage.GetDatabase());
    // [ Loop through each script. ]
    for (const auto& entry : scripts) {
        // [ Get the bip-16 p2sh scriptid of each script. ]
        CScriptID id(entry);
        if (HaveCScript(id)) {
            WalletLogPrintf("Already have script %s, skipping\n", HexStr(entry));
            continue;
        }
        // [ Just adds CScriptId : CScript to mapScripts. ]
        if (!AddCScriptWithDB(batch, entry)) {
            return false;
        }

        // [ Added in [#1863](https://github.com/bitcoin/bitcoin/pull/1863),
        //   CKeyMetadata stores key / script creation time to optimize rescans ]
        if (timestamp > 0) {
            m_script_metadata[CScriptID(entry)].nCreateTime = timestamp;
        }
    }
    if (timestamp > 0) {
        // [ Store the creation time in the spkm, doesn't it make CKeyMetadata
        //   redundant? No, the wallet timestamp comes from scanning during
        //   loadwallet or something it seems and is stored in memory, not written to
        //   disk and recomputed each time it's loaded.]
        UpdateTimeFirstKey(timestamp);
    }

    return true;
}
```

```cpp
// [ Question: I wonder how expensive the two extra Hash160's are for wallet
//   migration? Probably not expensive at all. ]
bool LegacyScriptPubKeyMan::AddCScriptWithDB(WalletBatch& batch, const CScript& redeemScript)
{
    // [ This adds the CScript to the (in-memory) mapScripts. ]
    if (!FillableSigningProvider::AddCScript(redeemScript))
        return false;
    // [ This writes it to disk. Kind of ugly, maybe this could look a little
    //   more like the CCoinsView family. ] 
    if (batch.WriteCScript(Hash160(redeemScript), redeemScript)) {
        m_storage.UnsetBlankWalletFlag(batch);
        return true;
    }
    return false;
}
```

### `ImportScriptPubKeys()`

```cpp
bool LegacyScriptPubKeyMan::ImportScriptPubKeys(const std::set<CScript>& script_pub_keys, const bool have_solving_data, const int64_t timestamp)
{
    // [ Create a write batch for the db. ] 
    WalletBatch batch(m_storage.GetDatabase());
    for (const CScript& script : script_pub_keys) {
        // [ If no solving data and not already in the SPKM, import watch-only.]
        if (!have_solving_data || !IsMine(script)) { // Always call AddWatchOnly for non-solvable watch-only, so that watch timestamp gets updated
            if (!AddWatchOnlyWithDB(batch, script, timestamp)) {
                return false;
            }
        }
    }
    // [ Otherwise do nothing, why, maybe it was already handled earlier? ]
    return true;
}
```

```cpp
// [ I have the same comment for AddCScriptWithDB as above, I dislike that this
//   function does two things separately, write to disk, and update our
//   in-memory map of what's on disk, I feel like there should be a view
//   hierarchy like in CCoinsView*, but I guess that does come with it's own
//   tradeoffs like tracking dirtyness and freshness. ]
bool LegacyScriptPubKeyMan::AddWatchOnlyWithDB(WalletBatch &batch, const CScript& dest)
{
    if (!AddWatchOnlyInMem(dest))
        return false;
    // [ We don't need to care much about anything that happens below, it's just
    //   writing to disk so that on next startup we can return to the same memory
    //   state that AddWatchOnlyInMem above gets us to now, I'll annotate that
    below.. ]
    const CKeyMetadata& meta = m_script_metadata[CScriptID(dest)];
    UpdateTimeFirstKey(meta.nCreateTime);
    NotifyWatchonlyChanged(true);
    if (batch.WriteWatchOnly(dest, meta)) {
        m_storage.UnsetBlankWalletFlag(batch);
        return true;
    }
    return false;
}
```

```cpp
bool LegacyDataSPKM::AddWatchOnlyInMem(const CScript &dest)
{
    LOCK(cs_KeyStore);
    // [ Going back to my question from the very top, it's still not clear to me
    //   what the relationship between setWatchOnly and mapScripts is.]
    setWatchOnly.insert(dest);
    CPubKey pubKey;

    // [ wasn't obvious to me, p2pk scripts only. does stuff get turned into p2pk before
    //   it arrives here? ]
    if (ExtractPubKey(dest, pubKey)) {
        // [ mapWatchKeys appears to be the p2pkh map, it's std::map <CKeyID, CPubKey> ]
        mapWatchKeys[pubKey.GetID()] = pubKey;
        // [ This is the strange part to me, we learn the related keyscripts
        //   into mapScripts, not setWatchOnly, why? I thought mapSCripts just
        //   mapped scripts we have the solving data for, but I guess not... OK
        //   more context for this in LegacyDataSPKM::GetScriptPubKeys(), in
        //   short, mapScripts is a superset of spendable scripts, why?
        ImplicitlyLearnRelatedKeyScripts(pubKey);
    }
    return true;
}

static bool ExtractPubKey(const CScript &dest, CPubKey& pubKeyOut)
{
    std::vector<std::vector<unsigned char>> solutions;
    // [ Only P2PK scripts, p2pkh and p2wpkh have different TxoutType, also
    //   solver is a nice simple function, I thought it would be a monster, but
    //   basically TxoutType::PUBKEY will be returned by solver if the script matches
    //   MatchPayToPubkey()!.]
    return Solver(dest, solutions) == TxoutType::PUBKEY &&
        (pubKeyOut = CPubKey(solutions[0])).IsFullyValid();
}

typedef std::vector<unsigned char> valtype;

static bool MatchPayToPubkey(const CScript& script, valtype& pubkey)
{
    // [ P2PK: OP_PUSHBYTES{uncompressed_key_size} + uncompressed key + OP_CHECKSIG ]
    if (script.size() == CPubKey::SIZE + 2 && script[0] == CPubKey::SIZE && script.back() == OP_CHECKSIG) {
        pubkey = valtype(script.begin() + 1, script.begin() + CPubKey::SIZE + 1);
        // [ ensures PK size matches the prefix. ]
        return CPubKey::ValidSize(pubkey);
    }
        
    // [ I actually didn't know p2pk could be both compressed and uncompressed. ]
    // [ P2PK: OP_PUSHBYTES{uncompressed_key_size} + uncompressed key + OP_CHECKSIG ]
    if (script.size() == CPubKey::COMPRESSED_SIZE + 2 && script[0] == CPubKey::COMPRESSED_SIZE && script.back() == OP_CHECKSIG) {
        pubkey = valtype(script.begin() + 1, script.begin() + CPubKey::COMPRESSED_SIZE + 1);
        return CPubKey::ValidSize(pubkey);
    }
    return false;
}

void FillableSigningProvider::ImplicitlyLearnRelatedKeyScripts(const CPubKey& pubkey)
{
    AssertLockHeld(cs_KeyStore);
    // [ Get keyhash ] 
    CKeyID key_id = pubkey.GetID();
    // This adds the redeemscripts necessary to detect P2WPKH and P2SH-P2WPKH
    // outputs. Technically P2WPKH outputs don't have a redeemscript to be
    // spent. However, our current IsMine logic requires the corresponding
    // P2SH-P2WPKH redeemscript to be present in the wallet in order to accept
    // payment even to P2WPKH outputs.
    // Also note that having superfluous scripts in the keystore never hurts.
    // They're only used to guide recursion in signing and IsMine logic - if
    // a script is present but we can't do anything with it, it has no effect.
    // "Implicitly" refers to fact that scripts are derived automatically from
    // existing keys, and are present in memory, even without being explicitly
    // loaded (e.g. from a file).
    // [ Uncompressed pubkeys violate standardness rules for segwit, so we don't
    //   add them. ]
    if (pubkey.IsCompressed()) {
        // [ I don't understand how the comment above claims to add the
        //   redeemscripts necessary for both p2wpkh and p2sh-p2wpkh, I guess we
        //   check both sides of mapScripts when deciding if an SPK ismine... no
        //   that's silly, the comment actually tells us, but a bit opaquely, at
        //   least to me, it seems like we maybe hash160 any p2wpkh we encounter
        //   before checking if IsMine() ]
        CScript script = GetScriptForDestination(WitnessV0KeyHash(key_id));
        // This does not use AddCScript, as it may be overridden.
        CScriptID id(script);
        mapScripts[id] = std::move(script);
    }
}
```

## `ImportPrivKeys()`

In summary, this adds a key to 

```cpp
bool LegacyScriptPubKeyMan::ImportPrivKeys(const std::map<CKeyID, CKey>& privkey_map, const int64_t timestamp)
{
    // [ grab the db batch... ]
    WalletBatch batch(m_storage.GetDatabase());
    // [ loop through each entry <pkh, privkey> ]
    for (const auto& entry : privkey_map) {
        // [ get a const ref, I think this is just for cleanliness... ]
        const CKey& key = entry.second;
        // [ get the priv's pub. ]
        CPubKey pubkey = key.GetPubKey();
        // [ same as the first expression in the for loop. ]
        const CKeyID& id = entry.first;
        assert(key.VerifyPubKey(pubkey));
        // [ HaveKey checks the SPKM's `keys` map which is std::map<CKeyID, CKey>,
        //   alternately written, std::map<pkh, privkey> ]
        // Skip if we already have the key
        if (HaveKey(id)) {
            WalletLogPrintf("Already have key with pubkey %s, skipping\n", HexStr(pubkey));
            continue;
        }
        // [ TODO: This seems wrong, shouldn't we only do this when the key insertion
        //   succeeds in the if branch below? ]
        mapKeyMetadata[id].nCreateTime = timestamp;
        // If the private key is not present in the wallet, insert it.
        if (!AddKeyPubKeyWithDB(batch, key, pubkey)) {
            return false;
        }
        UpdateTimeFirstKey(timestamp);
    }
    return true;
}

// [ This function closely approximates what really happens when
//   AddKeyPubKeyWithDB above happens, see below for more context. ]
bool FillableSigningProvider::AddKeyPubKey(const CKey& key, const CPubKey &pubkey)
{
    LOCK(cs_KeyStore);
    // [ Adds the key to std::map<CKeyId, CKey> or std::map<pkh, privkey>]
    mapKeys[pubkey.GetID()] = key; 
    // [ We looked at this above, adds the "scripts necessary" for p2sh-p2wpkh
    //   and p2wpkh to mapScripts.  (they both need just one script, the
    //   p2sh-p2wpkh present in mapScripts) ]
    ImplicitlyLearnRelatedKeyScripts(pubkey);
    return true;
}

bool LegacyScriptPubKeyMan::AddKeyPubKeyWithDB(WalletBatch& batch, const CKey& secret, const CPubKey& pubkey)
{
    AssertLockHeld(cs_KeyStore);

    // Make sure we aren't adding private keys to private key disabled wallets
    assert(!m_storage.IsWalletFlagSet(WALLET_FLAG_DISABLE_PRIVATE_KEYS));

    // [ ?? ]
    // FillableSigningProvider has no concept of wallet databases, but calls AddCryptedKey
    // which is overridden below.  To avoid flushes, the database handle is
    // tunneled through to it.
    bool needsDB = !encrypted_batch;
    if (needsDB) {
        encrypted_batch = &batch;
    }
    if (!AddKeyPubKeyInner(secret, pubkey)) {
        if (needsDB) encrypted_batch = nullptr;
        return false;
    }
    if (needsDB) encrypted_batch = nullptr;

    // check if we need to remove from watch-only
    CScript script;
    script = GetScriptForDestination(PKHash(pubkey));
    if (HaveWatchOnly(script)) {
        // [ RemoveWatchOnly removes from setWatchOnly and mapWatchKeys. ]
        RemoveWatchOnly(script);
    }
    script = GetScriptForRawPubKey(pubkey);
    if (HaveWatchOnly(script)) {
        RemoveWatchOnly(script);
    }

    m_storage.UnsetBlankWalletFlag(batch);
    if (!m_storage.HasEncryptionKeys()) {
        return batch.WriteKey(pubkey,
                                 secret.GetPrivKey(),
                                 mapKeyMetadata[pubkey.GetID()]);
    }
    return true;
}


bool LegacyScriptPubKeyMan::AddKeyPubKeyInner(const CKey& key, const CPubKey &pubkey)
{
    LOCK(cs_KeyStore);
    if (!m_storage.HasEncryptionKeys()) {
        return FillableSigningProvider::AddKeyPubKey(key, pubkey);
    }

    if (m_storage.IsLocked()) {
        return false;
    }

    std::vector<unsigned char> vchCryptedSecret;
    CKeyingMaterial vchSecret{UCharCast(key.begin()), UCharCast(key.end())};
    if (!m_storage.WithEncryptionKey([&](const CKeyingMaterial& encryption_key) {
            return EncryptSecret(encryption_key, vchSecret, pubkey.GetHash(), vchCryptedSecret);
        })) {
        return false;
    }

    // [ behavior is almost identical to unencrypted invocation of fillable add
    //   key above, so I'll just look at that for comprehension. ]
    if (!AddCryptedKey(pubkey, vchCryptedSecret)) {
        return false;
    }
    return true;
}




```


-----



```cpp
static UniValue ProcessImportLegacy(ImportData& import_data, std::map<CKeyID, CPubKey>& pubkey_map, std::map<CKeyID, CKey>& privkey_map, std::set<CScript>& script_pub_keys, bool& have_solving_data, const UniValue& data, std::vector<std::pair<CKeyID, bool>>& ordered_pubkeys)
{
    UniValue warnings(UniValue::VARR);

    // First ensure scriptPubKey has either a script or JSON with "address" string
    const UniValue& scriptPubKey = data["scriptPubKey"];
    bool isScript = scriptPubKey.getType() == UniValue::VSTR;
    if (!isScript && !(scriptPubKey.getType() == UniValue::VOBJ && scriptPubKey.exists("address"))) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "scriptPubKey must be string with script or JSON with address string");
    }
    const std::string& output = isScript ? scriptPubKey.get_str() : scriptPubKey["address"].get_str();

    // Optional fields.
    const std::string& strRedeemScript = data.exists("redeemscript") ? data["redeemscript"].get_str() : "";
    const std::string& witness_script_hex = data.exists("witnessscript") ? data["witnessscript"].get_str() : "";
    const UniValue& pubKeys = data.exists("pubkeys") ? data["pubkeys"].get_array() : UniValue();
    const UniValue& keys = data.exists("keys") ? data["keys"].get_array() : UniValue();
    const bool internal = data.exists("internal") ? data["internal"].get_bool() : false;
    const bool watchOnly = data.exists("watchonly") ? data["watchonly"].get_bool() : false;

    if (data.exists("range")) {
        throw JSONRPCError(RPC_INVALID_PARAMETER, "Range should not be specified for a non-descriptor import");
    }

    // Generate the script and destination for the scriptPubKey provided
    CScript script;
    if (!isScript) {
        CTxDestination dest = DecodeDestination(output);
        if (!IsValidDestination(dest)) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid address \"" + output + "\"");
        }
        if (OutputTypeFromDestination(dest) == OutputType::BECH32M) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Bech32m addresses cannot be imported into legacy wallets");
        }
        script = GetScriptForDestination(dest);
    } else {
        if (!IsHex(output)) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid scriptPubKey \"" + output + "\"");
        }
        std::vector<unsigned char> vData(ParseHex(output));
        script = CScript(vData.begin(), vData.end());
        CTxDestination dest;
        if (!ExtractDestination(script, dest) && !internal) {
            throw JSONRPCError(RPC_INVALID_PARAMETER, "Internal must be set to true for nonstandard scriptPubKey imports.");
        }
    }
    script_pub_keys.emplace(script);

    // Parse all arguments
    if (strRedeemScript.size()) {
        if (!IsHex(strRedeemScript)) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid redeem script \"" + strRedeemScript + "\": must be hex string");
        }
        auto parsed_redeemscript = ParseHex(strRedeemScript);
        import_data.redeemscript = std::make_unique<CScript>(parsed_redeemscript.begin(), parsed_redeemscript.end());
    }
    if (witness_script_hex.size()) {
        if (!IsHex(witness_script_hex)) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid witness script \"" + witness_script_hex + "\": must be hex string");
        }
        auto parsed_witnessscript = ParseHex(witness_script_hex);
        import_data.witnessscript = std::make_unique<CScript>(parsed_witnessscript.begin(), parsed_witnessscript.end());
    }
    for (size_t i = 0; i < pubKeys.size(); ++i) {
        CPubKey pubkey = HexToPubKey(pubKeys[i].get_str());
        pubkey_map.emplace(pubkey.GetID(), pubkey);
        ordered_pubkeys.emplace_back(pubkey.GetID(), internal);
    }
    for (size_t i = 0; i < keys.size(); ++i) {
        const auto& str = keys[i].get_str();
        CKey key = DecodeSecret(str);
        if (!key.IsValid()) {
            throw JSONRPCError(RPC_INVALID_ADDRESS_OR_KEY, "Invalid private key encoding");
        }
        CPubKey pubkey = key.GetPubKey();
        CKeyID id = pubkey.GetID();
        if (pubkey_map.count(id)) {
            pubkey_map.erase(id);
        }
        privkey_map.emplace(id, key);
    }


    // Verify and process input data
    have_solving_data = import_data.redeemscript || import_data.witnessscript || pubkey_map.size() || privkey_map.size();
    if (have_solving_data) {
        // Match up data in import_data with the scriptPubKey in script.
        auto error = RecurseImportData(script, import_data, ScriptContext::TOP);

        // Verify whether the watchonly option corresponds to the availability of private keys.
        bool spendable = std::all_of(import_data.used_keys.begin(), import_data.used_keys.end(), [&](const std::pair<CKeyID, bool>& used_key){ return privkey_map.count(used_key.first) > 0; });
        if (!watchOnly && !spendable) {
            warnings.push_back("Some private keys are missing, outputs will be considered watchonly. If this is intentional, specify the watchonly flag.");
        }
        if (watchOnly && spendable) {
            warnings.push_back("All private keys are provided, outputs will be considered spendable. If this is intentional, do not specify the watchonly flag.");
        }

        // Check that all required keys for solvability are provided.
        if (error.empty()) {
            for (const auto& require_key : import_data.used_keys) {
                if (!require_key.second) continue; // Not a required key
                if (pubkey_map.count(require_key.first) == 0 && privkey_map.count(require_key.first) == 0) {
                    error = "some required keys are missing";
                }
            }
        }

        if (!error.empty()) {
            warnings.push_back("Importing as non-solvable: " + error + ". If this is intentional, don't provide any keys, pubkeys, witnessscript, or redeemscript.");
            import_data = ImportData();
            pubkey_map.clear();
            privkey_map.clear();
            have_solving_data = false;
        } else {
            // RecurseImportData() removes any relevant redeemscript/witnessscript from import_data, so we can use that to discover if a superfluous one was provided.
            if (import_data.redeemscript) warnings.push_back("Ignoring redeemscript as this is not a P2SH script.");
            if (import_data.witnessscript) warnings.push_back("Ignoring witnessscript as this is not a (P2SH-)P2WSH script.");
            for (auto it = privkey_map.begin(); it != privkey_map.end(); ) {
                auto oldit = it++;
                if (import_data.used_keys.count(oldit->first) == 0) {
                    warnings.push_back("Ignoring irrelevant private key.");
                    privkey_map.erase(oldit);
                }
            }
            for (auto it = pubkey_map.begin(); it != pubkey_map.end(); ) {
                auto oldit = it++;
                auto key_data_it = import_data.used_keys.find(oldit->first);
                if (key_data_it == import_data.used_keys.end() || !key_data_it->second) {
                    warnings.push_back("Ignoring public key \"" + HexStr(oldit->first) + "\" as it doesn't appear inside P2PKH or P2WPKH.");
                    pubkey_map.erase(oldit);
                }
            }
        }
    }

    return warnings;
}
```

