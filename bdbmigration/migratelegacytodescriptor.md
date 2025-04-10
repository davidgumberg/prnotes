# title


```cpp
// [ Weird overloaded function thing, let's call this phase 1 of migration. We
//   are basically unloading the wallet from global context, and loading it into an
//   empty, local context. ]

// [ WalletContext holds on to some global state for us, e.g. what wallets are loaded. ]
util::Result<MigrationResult> MigrateLegacyToDescriptor(const std::string& wallet_name, const SecureString& passphrase, WalletContext& context)
{
    std::vector<bilingual_str> warnings;
    bilingual_str error;

    // [ Not sure I get this, we're not doing anything here? ]
    // If the wallet is still loaded, unload it so that nothing else tries to use it while we're changing it
    bool was_loaded = false;
    // [ GetWallet checks if we have a wallet with wallet_name loaded in context. ]
    if (auto wallet = GetWallet(context, wallet_name)) {
        if (wallet->IsWalletFlagSet(WALLET_FLAG_DESCRIPTORS)) {
            return util::Error{_("Error: This wallet is already a descriptor wallet")};
        }

        // Flush chain state before unloading wallet
        CBlockLocator locator;
        // [ Side note about findBlock: I think findBlock works in an insane way, but maybe I haven't thought through it's design:
        //   AFAICT, you initialize a FoundBlock() with references where it can store the metadata you care
        //   about, e.g. FoundBlock().locator(locator).height(height); will return true/false whether or not
        //   the block is found, and store the block height in `height` and locator in `locator`. See
        //   `FillBlock()` for more details ]

        // [ CWallet::GetLastBlockHash() is a little bit disingenously named, seemingly has
        //   little to do with the last block the wallet processed, and more to
        //   do with the wallet's idea of the most recent chaintip, this is to
        //   avoid the wallet having to talk to the chain and lock cs_main,
        //   seems to me like this could probably be changed so that the . ]
        WITH_LOCK(wallet->cs_wallet, context.chain->findBlock(wallet->GetLastBlockHash(), FoundBlock().locator(locator)));
        // [ If the chain
        if (!locator.IsNull()) wallet->chainStateFlushed(ChainstateRole::NORMAL, locator);

        // [ Despite the name, used to unload wallet in memory. ]
        if (!RemoveWallet(context, wallet, /*load_on_start=*/std::nullopt, warnings)) {
            return util::Error{_("Unable to unload the wallet before migrating")};
        }
        // [ Both have to be done I guess, but this one waits, strange. ]
        WaitForDeleteWallet(std::move(wallet));
        was_loaded = true;
    // [ It wasn't already loaded. Presumably, this will always be the case
    //   post-legacy-removal? ]
    } else {
        // [ I guess we perform some basic checks to make sure we can proceed,
        //   we don't need to check if the file's exist if the wallet was already
        //   loaded. ]
        // Check if the wallet is BDB
        const auto& wallet_path = GetWalletPath(wallet_name);
        if (!wallet_path) {
            return util::Error{util::ErrorString(wallet_path)};
        }
        if (!fs::exists(*wallet_path)) {
            return util::Error{_("Error: Wallet does not exist")};
        }
        if (!IsBDBFile(BDBDataFile(*wallet_path))) {
            return util::Error{_("Error: This wallet is already a descriptor wallet")};
        }
    }

    // Load the wallet but only in the context of this function.
    // No signals should be connected nor should anything else be aware of this wallet
    WalletContext empty_context;
    empty_context.args = context.args;
    DatabaseOptions options;
    options.require_existing = true;
    options.require_format = DatabaseFormat::BERKELEY_RO;
    DatabaseStatus status;
    // [ WalletDatabase is the generic interface that wraps our "database
    //   handle" no matter the database backend we're using. When we "make" one,
    //   we're basically just opening a database handle to a file, not necessarily
    //   "creating" a database that didn't exist. 
    //
    //   MakeWalletDatabase is a unique_ptr factory, the wallet
    //   database constructor will end up calling Open() on the database file,
    //   usually most of "Open()" is just begging the db's api to give us a
    //   handle on something with the right file name, but in the case of the
    //   ROBerkeleyDatabase, we perform validations and stand up a db "handle"
    //   on our own. Since we verified the file exists above, if this fails, there's
    //   probably something wrong with the file format. ]
    std::unique_ptr<WalletDatabase> database = MakeWalletDatabase(wallet_name, options, status, error);
    if (!database) {
        return util::Error{Untranslated("Wallet file verification failed.") + Untranslated(" ") + error};
    }

    // [ Skipping digging deep on this for now, but we are creating a cwallet
    //   object using this db handle, like above, not necessarily creating
    //   something that didn't exist, just initializing an interface to it. I
    //   believe that CWallet will cleverly tell if you're using it for the first
    //   time, and set up the right stuff if this wallet didn't exist before. I
    //   guess a necessary ambiguity of almost all these interfaces is ambiguity
    //   between the language for object construction, and the language of
    //   users. e.g here, the difference between creating a "CWallet" object, and
    //   "creating a wallet." ]
    // Make the local wallet
    std::shared_ptr<CWallet> local_wallet = CWallet::Create(empty_context, wallet_name, std::move(database), options.create_flags, error, warnings);
    if (!local_wallet) {
        return util::Error{Untranslated("Wallet loading failed.") + Untranslated(" ") + error};
    }

    // [ Why, oh why, does this have to have two overloaded functions like this,
    //   makes it so hard to figure out what's going on!!! ]
    return MigrateLegacyToDescriptor(std::move(local_wallet), passphrase, context, was_loaded);
}

util::Result<MigrationResult> MigrateLegacyToDescriptor(std::shared_ptr<CWallet> local_wallet, const SecureString& passphrase, WalletContext& context, bool was_loaded)
{
    MigrationResult res;
    bilingual_str error;
    std::vector<bilingual_str> warnings;

    DatabaseOptions options;
    options.require_existing = true;
    DatabaseStatus status;

    const std::string wallet_name = local_wallet->GetName();

    // Helper to reload as normal for some of our exit scenarios
    const auto& reload_wallet = [&](std::shared_ptr<CWallet>& to_reload) {
        assert(to_reload.use_count() == 1);
        std::string name = to_reload->GetName();
        to_reload.reset();
        to_reload = LoadWallet(context, name, /*load_on_start=*/std::nullopt, options, status, error, warnings);
        return to_reload != nullptr;
    };

    // Before anything else, check if there is something to migrate.
    if (local_wallet->IsWalletFlagSet(WALLET_FLAG_DESCRIPTORS)) {
        if (was_loaded) {
            reload_wallet(local_wallet);
        }
        return util::Error{_("Error: This wallet is already a descriptor wallet")};
    }

    // Make a backup of the DB
    fs::path this_wallet_dir = fs::absolute(fs::PathFromString(local_wallet->GetDatabase().Filename())).parent_path();
    fs::path backup_filename = fs::PathFromString(strprintf("%s_%d.legacy.bak", (wallet_name.empty() ? "default_wallet" : wallet_name), GetTime()));
    fs::path backup_path = this_wallet_dir / backup_filename;
    if (!local_wallet->BackupWallet(fs::PathToString(backup_path))) {
        if (was_loaded) {
            reload_wallet(local_wallet);
        }
        return util::Error{_("Error: Unable to make a backup of your wallet")};
    }
    res.backup_path = backup_path;

    bool success = false;

    // Unlock the wallet if needed
    if (local_wallet->IsLocked() && !local_wallet->Unlock(passphrase)) {
        if (was_loaded) {
            reload_wallet(local_wallet);
        }
        if (passphrase.find('\0') == std::string::npos) {
            return util::Error{Untranslated("Error: Wallet decryption failed, the wallet passphrase was not provided or was incorrect.")};
        } else {
            return util::Error{Untranslated("Error: Wallet decryption failed, the wallet passphrase entered was incorrect. "
                                            "The passphrase contains a null character (ie - a zero byte). "
                                            "If this passphrase was set with a version of this software prior to 25.0, "
                                            "please try again with only the characters up to — but not including — "
                                            "the first null character.")};
        }
    }

    {
        LOCK(local_wallet->cs_wallet);
        // First change to using SQLite
        if (!local_wallet->MigrateToSQLite(error)) return util::Error{error};

        // Do the migration of keys and scripts for non-blank wallets, and cleanup if it fails
        success = local_wallet->IsWalletFlagSet(WALLET_FLAG_BLANK_WALLET);
        if (!success) {
            success = DoMigration(*local_wallet, context, error, res);
        } else {
            // Make sure that descriptors flag is actually set
            local_wallet->SetWalletFlag(WALLET_FLAG_DESCRIPTORS);
        }
    }

    // In case of reloading failure, we need to remember the wallet dirs to remove
    // Set is used as it may be populated with the same wallet directory paths multiple times,
    // both before and after reloading. This ensures the set is complete even if one of the wallets
    // fails to reload.
    std::set<fs::path> wallet_dirs;
    if (success) {
        // Migration successful, unload all wallets locally, then reload them.
        // Reload the main wallet
        wallet_dirs.insert(fs::PathFromString(local_wallet->GetDatabase().Filename()).parent_path());
        success = reload_wallet(local_wallet);
        res.wallet = local_wallet;
        res.wallet_name = wallet_name;
        if (success && res.watchonly_wallet) {
            // Reload watchonly
            wallet_dirs.insert(fs::PathFromString(res.watchonly_wallet->GetDatabase().Filename()).parent_path());
            success = reload_wallet(res.watchonly_wallet);
        }
        if (success && res.solvables_wallet) {
            // Reload solvables
            wallet_dirs.insert(fs::PathFromString(res.solvables_wallet->GetDatabase().Filename()).parent_path());
            success = reload_wallet(res.solvables_wallet);
        }
    }
    if (!success) {
        // Migration failed, cleanup
        // Before deleting the wallet's directory, copy the backup file to the top-level wallets dir
        fs::path temp_backup_location = fsbridge::AbsPathJoin(GetWalletDir(), backup_filename);
        fs::copy_file(backup_path, temp_backup_location, fs::copy_options::none);

        // Make list of wallets to cleanup
        std::vector<std::shared_ptr<CWallet>> created_wallets;
        if (local_wallet) created_wallets.push_back(std::move(local_wallet));
        if (res.watchonly_wallet) created_wallets.push_back(std::move(res.watchonly_wallet));
        if (res.solvables_wallet) created_wallets.push_back(std::move(res.solvables_wallet));

        // Get the directories to remove after unloading
        for (std::shared_ptr<CWallet>& w : created_wallets) {
            wallet_dirs.emplace(fs::PathFromString(w->GetDatabase().Filename()).parent_path());
        }

        // Unload the wallets
        for (std::shared_ptr<CWallet>& w : created_wallets) {
            if (w->HaveChain()) {
                // Unloading for wallets that were loaded for normal use
                if (!RemoveWallet(context, w, /*load_on_start=*/false)) {
                    error += _("\nUnable to cleanup failed migration");
                    return util::Error{error};
                }
                WaitForDeleteWallet(std::move(w));
            } else {
                // Unloading for wallets in local context
                assert(w.use_count() == 1);
                w.reset();
            }
        }

        // Delete the wallet directories
        for (const fs::path& dir : wallet_dirs) {
            fs::remove_all(dir);
        }

        // Restore the backup
        // Convert the backup file to the wallet db file by renaming it and moving it into the wallet's directory.
        // Reload it into memory if the wallet was previously loaded.
        bilingual_str restore_error;
        const auto& ptr_wallet = RestoreWallet(context, temp_backup_location, wallet_name, /*load_on_start=*/std::nullopt, status, restore_error, warnings, /*load_after_restore=*/was_loaded);
        if (!restore_error.empty()) {
            error += restore_error + _("\nUnable to restore backup of wallet.");
            return util::Error{error};
        }

        // The wallet directory has been restored, but just in case, copy the previously created backup to the wallet dir
        fs::copy_file(temp_backup_location, backup_path, fs::copy_options::none);
        fs::remove(temp_backup_location);

        // Verify that there is no dangling wallet: when the wallet wasn't loaded before, expect null.
        // This check is performed after restoration to avoid an early error before saving the backup.
        bool wallet_reloaded = ptr_wallet != nullptr;
        assert(was_loaded == wallet_reloaded);

        return util::Error{error};
    }
    return res;
}
```
