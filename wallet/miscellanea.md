Waiting room...

```cpp
bool LoadWallets(WalletContext& context)
{
    interfaces::Chain& chain = *context.chain;
    try {
        std::set<fs::path> wallet_paths;
        for (const auto& wallet : chain.getSettingsList("wallet")) {
            if (!wallet.isStr()) {
                chain.initError(_("Invalid value detected for '-wallet' or '-nowallet'. "
                                  "'-wallet' requires a string value, while '-nowallet' accepts only '1' to disable all wallets"));
                return false;
            }
            const auto& name = wallet.get_str();
            if (!wallet_paths.insert(fs::PathFromString(name)).second) {
                continue;
            }
            // [ All of this can be replaced with LoadWallet() once Create() and load() are split up. ]
            DatabaseOptions options;
            DatabaseStatus status;
            ReadDatabaseArgs(*context.args, options);
            options.require_existing = true;
            options.verify = false; // No need to verify, assuming verified earlier in VerifyWallets()
            bilingual_str error;
            std::vector<bilingual_str> warnings;
            std::unique_ptr<WalletDatabase> database = MakeWalletDatabase(name, options, status, error);
            if (!database && status == DatabaseStatus::FAILED_NOT_FOUND) {
                continue;
            }
            chain.initMessage(_("Loading wallet…"));
            std::shared_ptr<CWallet> pwallet = database ? CWallet::Create(context, name, std::move(database), options.create_flags, error, warnings) : nullptr;
            if (!warnings.empty()) chain.initWarning(Join(warnings, Untranslated("\n")));
            if (!pwallet) {
                chain.initError(error);
                return false;
            }

            NotifyWalletLoaded(context, pwallet);
            AddWallet(context, pwallet);
        }
        return true;
    } catch (const std::runtime_error& e) {
        chain.initError(Untranslated(e.what()));
        return false;
    }
}
```

```cpp
bool DescriptorScriptPubKeyMan::TopUpWithDB(WalletBatch& batch, unsigned int size)
{
    LOCK(cs_desc_man);
    std::set<CScript> new_spks;
    unsigned int target_size;
    if (size > 0) {
        target_size = size;
    } else {
        target_size = m_keypool_size;
    }

    // [ AFAIU next_index is the next key we'd give to a wallet user invoking e.g. getnewaddress, so we stay `m_keypool_size` ahead of that. ]
    // Calculate the new range_end
    int32_t new_range_end = std::max(m_wallet_descriptor.next_index + (int32_t)target_size, m_wallet_descriptor.range_end);

    // If the descriptor is not ranged, we actually just want to fill the first cache item
    if (!m_wallet_descriptor.descriptor->IsRange()) {
        new_range_end = 1;
        m_wallet_descriptor.range_end = 1;
        m_wallet_descriptor.range_start = 0;
    }

    FlatSigningProvider provider;
    provider.keys = GetKeys();

    uint256 id = GetID();
    // [ m_max_cached_index is -1 by default, so the unranged case above works to make exactly one.
    //   presumably, m_max_cached_index represents the latest generated key. ]
    for (int32_t i = m_max_cached_index + 1; i < new_range_end; ++i) {
        FlatSigningProvider out_keys;
        std::vector<CScript> scripts_temp;
        DescriptorCache temp_cache;
        // [ Sketch of ExpandFromCache: expand the descriptor at a given index, `i`, SPK's/pubkeys into scripts_temp,
        //   and signing data into out_keys, naming could probably be improved here imo (scripts_temp vs out_keys?), using
        //   this descriptor's particular cache. If that fails, expand without cache. Later on here, we'll add the expanded
        //   descs made here to the `m_wallet_descriptor` cache. I feel like this whole sequence is a layer violation,
        //   shouldn't the descriptor's cache be an internal detail?]
        //   Maybe we have a cached xpub and we can expand from the cache first
        if (!m_wallet_descriptor.descriptor->ExpandFromCache(i, m_wallet_descriptor.cache, scripts_temp, out_keys)) {
            if (!m_wallet_descriptor.descriptor->Expand(i, provider, scripts_temp, out_keys, &temp_cache)) return false;
        }
        // Add all of the scriptPubKeys to the scriptPubKey set
        new_spks.insert(scripts_temp.begin(), scripts_temp.end());
        for (const CScript& script : scripts_temp) {
            // [ I guess this map is kind of funny, maps SPK's to descriptor index, but makes sense, since we'll be scanning scripts to check whether their ours, and if they are we want to know their index in the descriptor. ]
            m_map_script_pub_keys[script] = i;
        }
        for (const auto& pk_pair : out_keys.pubkeys) {
            const CPubKey& pubkey = pk_pair.second;
            if (m_map_pubkeys.count(pubkey) != 0) {
                // We don't need to give an error here.
                // It doesn't matter which of many valid indexes the pubkey has, we just need an index where we can derive it and it's private key
                continue;
            }
            m_map_pubkeys[pubkey] = i;
        }
        // Merge and write the cache
        // [ This seems like the cause of the layering issues with descriptor caches, we need the diff between the cache before and after, I don't understand this,
        //   why not just keep the global wallet state in sync with the disk state at the end of this top up? ]
        DescriptorCache new_items = m_wallet_descriptor.cache.MergeAndDiff(temp_cache);
        if (!batch.WriteDescriptorCacheItems(id, new_items)) {
            throw std::runtime_error(std::string(__func__) + ": writing cache items failed");
        }
        m_max_cached_index++;
    }
    m_wallet_descriptor.range_end = new_range_end;
    batch.WriteDescriptor(GetID(), m_wallet_descriptor);

    // By this point, the cache size should be the size of the entire range
    assert(m_wallet_descriptor.range_end - 1 == m_max_cached_index);

    m_storage.TopUpCallback(new_spks, this);
    NotifyCanGetAddressesChanged();
    return true;
}
```
