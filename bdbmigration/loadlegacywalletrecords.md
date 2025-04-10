```cpp
static DBErrors LoadLegacyWalletRecords(CWallet* pwallet, DatabaseBatch& batch, int last_client) EXCLUSIVE_LOCKS_REQUIRED(pwallet->cs_wallet)
{
    AssertLockHeld(pwallet->cs_wallet);
    DBErrors result = DBErrors::LOAD_OK;

    // Make sure descriptor wallets don't have any legacy records
    if (pwallet->IsWalletFlagSet(WALLET_FLAG_DESCRIPTORS)) {
        for (const auto& type : DBKeys::LEGACY_TYPES) {
            DataStream key;
            DataStream value{};

            DataStream prefix;
            prefix << type;
            std::unique_ptr<DatabaseCursor> cursor = batch.GetNewPrefixCursor(prefix);
            if (!cursor) {
                pwallet->WalletLogPrintf("Error getting database cursor for '%s' records\n", type);
                return DBErrors::CORRUPT;
            }

            DatabaseCursor::Status status = cursor->Next(key, value);
            if (status != DatabaseCursor::Status::DONE) {
                pwallet->WalletLogPrintf("Error: Unexpected legacy entry found in descriptor wallet %s. The wallet might have been tampered with or created with malicious intent.\n", pwallet->GetName());
                return DBErrors::UNEXPECTED_LEGACY_ENTRY;
            }
        }

        return DBErrors::LOAD_OK;
    }

    // Load HD Chain
    // Note: There should only be one HDCHAIN record with no data following the type
    LoadResult hd_chain_res = LoadRecords(pwallet, batch, DBKeys::HDCHAIN,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        return LoadHDChain(pwallet, value, err) ? DBErrors:: LOAD_OK : DBErrors::CORRUPT;
    });
    result = std::max(result, hd_chain_res.m_result);

    // Load unencrypted keys
    LoadResult key_res = LoadRecords(pwallet, batch, DBKeys::KEY,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        return LoadKey(pwallet, key, value, err) ? DBErrors::LOAD_OK : DBErrors::CORRUPT;
    });
    result = std::max(result, key_res.m_result);

    // Load encrypted keys
    LoadResult ckey_res = LoadRecords(pwallet, batch, DBKeys::CRYPTED_KEY,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        return LoadCryptedKey(pwallet, key, value, err) ? DBErrors::LOAD_OK : DBErrors::CORRUPT;
    });
    result = std::max(result, ckey_res.m_result);

    // Load scripts
    LoadResult script_res = LoadRecords(pwallet, batch, DBKeys::CSCRIPT,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& strErr) {
        uint160 hash;
        key >> hash;
        CScript script;
        value >> script;
        if (!pwallet->GetOrCreateLegacyDataSPKM()->LoadCScript(script))
        {
            strErr = "Error reading wallet database: LegacyDataSPKM::LoadCScript failed";
            return DBErrors::NONCRITICAL_ERROR;
        }
        return DBErrors::LOAD_OK;
    });
    result = std::max(result, script_res.m_result);

    // Check whether rewrite is needed
    if (ckey_res.m_records > 0) {
        // Rewrite encrypted wallets of versions 0.4.0 and 0.5.0rc:
        if (last_client == 40000 || last_client == 50000) result = std::max(result, DBErrors::NEED_REWRITE);
    }

    // Load keymeta
    std::map<uint160, CHDChain> hd_chains;
    LoadResult keymeta_res = LoadRecords(pwallet, batch, DBKeys::KEYMETA,
        [&hd_chains] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& strErr) {
        CPubKey vchPubKey;
        key >> vchPubKey;
        CKeyMetadata keyMeta;
        value >> keyMeta;
        pwallet->GetOrCreateLegacyDataSPKM()->LoadKeyMetadata(vchPubKey.GetID(), keyMeta);

        // Extract some CHDChain info from this metadata if it has any
        if (keyMeta.nVersion >= CKeyMetadata::VERSION_WITH_HDDATA && !keyMeta.hd_seed_id.IsNull() && keyMeta.hdKeypath.size() > 0) {
            // Get the path from the key origin or from the path string
            // Not applicable when path is "s" or "m" as those indicate a seed
            // See https://github.com/bitcoin/bitcoin/pull/12924
            bool internal = false;
            uint32_t index = 0;
            if (keyMeta.hdKeypath != "s" && keyMeta.hdKeypath != "m") {
                std::vector<uint32_t> path;
                if (keyMeta.has_key_origin) {
                    // We have a key origin, so pull it from its path vector
                    path = keyMeta.key_origin.path;
                } else {
                    // No key origin, have to parse the string
                    if (!ParseHDKeypath(keyMeta.hdKeypath, path)) {
                        strErr = "Error reading wallet database: keymeta with invalid HD keypath";
                        return DBErrors::NONCRITICAL_ERROR;
                    }
                }

                // Extract the index and internal from the path
                // Path string is m/0'/k'/i'
                // Path vector is [0', k', i'] (but as ints OR'd with the hardened bit
                // k == 0 for external, 1 for internal. i is the index
                if (path.size() != 3) {
                    strErr = "Error reading wallet database: keymeta found with unexpected path";
                    return DBErrors::NONCRITICAL_ERROR;
                }
                if (path[0] != 0x80000000) {
                    strErr = strprintf("Unexpected path index of 0x%08x (expected 0x80000000) for the element at index 0", path[0]);
                    return DBErrors::NONCRITICAL_ERROR;
                }
                if (path[1] != 0x80000000 && path[1] != (1 | 0x80000000)) {
                    strErr = strprintf("Unexpected path index of 0x%08x (expected 0x80000000 or 0x80000001) for the element at index 1", path[1]);
                    return DBErrors::NONCRITICAL_ERROR;
                }
                if ((path[2] & 0x80000000) == 0) {
                    strErr = strprintf("Unexpected path index of 0x%08x (expected to be greater than or equal to 0x80000000)", path[2]);
                    return DBErrors::NONCRITICAL_ERROR;
                }
                internal = path[1] == (1 | 0x80000000);
                index = path[2] & ~0x80000000;
            }

            // Insert a new CHDChain, or get the one that already exists
            auto [ins, inserted] = hd_chains.emplace(keyMeta.hd_seed_id, CHDChain());
            CHDChain& chain = ins->second;
            if (inserted) {
                // For new chains, we want to default to VERSION_HD_BASE until we see an internal
                chain.nVersion = CHDChain::VERSION_HD_BASE;
                chain.seed_id = keyMeta.hd_seed_id;
            }
            if (internal) {
                chain.nVersion = CHDChain::VERSION_HD_CHAIN_SPLIT;
                chain.nInternalChainCounter = std::max(chain.nInternalChainCounter, index + 1);
            } else {
                chain.nExternalChainCounter = std::max(chain.nExternalChainCounter, index + 1);
            }
        }
        return DBErrors::LOAD_OK;
    });
    result = std::max(result, keymeta_res.m_result);

    // Set inactive chains
    if (!hd_chains.empty()) {
        LegacyDataSPKM* legacy_spkm = pwallet->GetLegacyDataSPKM();
        if (legacy_spkm) {
            for (const auto& [hd_seed_id, chain] : hd_chains) {
                if (hd_seed_id != legacy_spkm->GetHDChain().seed_id) {
                    legacy_spkm->AddInactiveHDChain(chain);
                }
            }
        } else {
            pwallet->WalletLogPrintf("Inactive HD Chains found but no Legacy ScriptPubKeyMan\n");
            result = DBErrors::CORRUPT;
        }
    }

    // Load watchonly scripts
    LoadResult watch_script_res = LoadRecords(pwallet, batch, DBKeys::WATCHS,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        CScript script;
        key >> script;
        uint8_t fYes;
        value >> fYes;
        if (fYes == '1') {
            pwallet->GetOrCreateLegacyDataSPKM()->LoadWatchOnly(script);
        }
        return DBErrors::LOAD_OK;
    });
    result = std::max(result, watch_script_res.m_result);

    // Load watchonly meta
    LoadResult watch_meta_res = LoadRecords(pwallet, batch, DBKeys::WATCHMETA,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        CScript script;
        key >> script;
        CKeyMetadata keyMeta;
        value >> keyMeta;
        pwallet->GetOrCreateLegacyDataSPKM()->LoadScriptMetadata(CScriptID(script), keyMeta);
        return DBErrors::LOAD_OK;
    });
    result = std::max(result, watch_meta_res.m_result);

    // Load keypool
    LoadResult pool_res = LoadRecords(pwallet, batch, DBKeys::POOL,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        int64_t nIndex;
        key >> nIndex;
        CKeyPool keypool;
        value >> keypool;
        pwallet->GetOrCreateLegacyDataSPKM()->LoadKeyPool(nIndex, keypool);
        return DBErrors::LOAD_OK;
    });
    result = std::max(result, pool_res.m_result);

    // Deal with old "wkey" and "defaultkey" records.
    // These are not actually loaded, but we need to check for them

    // We don't want or need the default key, but if there is one set,
    // we want to make sure that it is valid so that we can detect corruption
    // Note: There should only be one DEFAULTKEY with nothing trailing the type
    LoadResult default_key_res = LoadRecords(pwallet, batch, DBKeys::DEFAULTKEY,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        CPubKey default_pubkey;
        try {
            value >> default_pubkey;
        } catch (const std::exception& e) {
            err = e.what();
            return DBErrors::CORRUPT;
        }
        if (!default_pubkey.IsValid()) {
            err = "Error reading wallet database: Default Key corrupt";
            return DBErrors::CORRUPT;
        }
        return DBErrors::LOAD_OK;
    });
    result = std::max(result, default_key_res.m_result);

    // "wkey" records are unsupported, if we see any, throw an error
    LoadResult wkey_res = LoadRecords(pwallet, batch, DBKeys::OLD_KEY,
        [] (CWallet* pwallet, DataStream& key, DataStream& value, std::string& err) {
        err = "Found unsupported 'wkey' record, try loading with version 0.18";
        return DBErrors::LOAD_FAIL;
    });
    result = std::max(result, wkey_res.m_result);

    if (result <= DBErrors::NONCRITICAL_ERROR) {
        // Only do logging and time first key update if there were no critical errors
        pwallet->WalletLogPrintf("Legacy Wallet Keys: %u plaintext, %u encrypted, %u w/ metadata, %u total.\n",
               key_res.m_records, ckey_res.m_records, keymeta_res.m_records, key_res.m_records + ckey_res.m_records);

        // nTimeFirstKey is only reliable if all keys have metadata
        if (pwallet->IsLegacy() && (key_res.m_records + ckey_res.m_records + watch_script_res.m_records) != (keymeta_res.m_records + watch_meta_res.m_records)) {
            auto spk_man = pwallet->GetLegacyScriptPubKeyMan();
            if (spk_man) {
                LOCK(spk_man->cs_KeyStore);
                spk_man->UpdateTimeFirstKey(1);
            }
        }
    }

    return result;
}
```
