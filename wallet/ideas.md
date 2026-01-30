# Big questions / big projects

- [ ] Investigate why we have so many permutations of *ScriptPubKeyMan. e.g. we
  only have descriptorscriptpubkeyman's now, so why are there some seemingly
  duplicated Descriptor vs General ScriptPubKeyMan functions.
    - Bite sized questions:
        - [ ] GetActiveScriptPubKeyMans comment is misleading, compare to
              GetAllScriptPubKeymans
        - [ ] GetOrCreateLegacyDataSPKM - Do we still need this? Why does it have so
              many callers in seemingly not migration-only code

- Wallet loading / creating
    - [ ] Wallet loading should be RAII, instead of being initialized and then loading more stuff later
        - Generally a problem for older stuff
    - [ ] Create/LoadWallet Refactor #32636
        [ ] [#32636](https://github.com/bitcoin/bitcoin/pull/32636)
    - [ ] postInitProcess should perhaps be folded into a multi wallet loading function

- [ ] Pull out AddrBook into separate Class extracting all the relevant methods

- [ ] Clean-up AVOID_REUSE logic
    - MarkDestinationsDirty

- [ ] Take a look at migration related stuff that can be extracted into
  migrate.cpp e.g. GGetDescriptorsForLegacy, ApplyMigrationDAta,
  MigrateToSQLite.

# Bite-sized chunks
- [ ] Rename IsFromMe to IsRelevantToMe
    - Seems ancient, probably comment should be updated, needs to be investigated
- [ ] move locked_coins onto wallet txos?
    - Might break the ability to lock a UTXO before it is created
- [x] Document / deduplicate HasEncryptionKeys <-> IsCrypted also look at
    - [x] [#34147](https://github.com/bitcoin/bitcoin/pull/34147)
  HaveCryptedKeys
- [ ] ComputeTimeSmart(…)
    - Method that could be extracted as a function
- [ ] ReorderTransactions()
    - Could be a function
- [ ] LoadAddressPreviouslySpent is used to set stuff?!
    - "Load…" put something in memory
    - "Set…" do something on disk --> immediately write something on disk when you get user input, otherwise it might be lost if memory is lost
- [ ] TransactionChangeType
    - Name is odd, seems to be missing a verb
- [ ] Maybe GetName is obsolete in lieu of LogName
- [ ] GetActiveHDPubKeys should not be returning a set, it's only caller expects
  and checks for exactly one item in the set.
- [ ] LoadCryptedKey in `src/wallet/walletdb.cpp` is only for legacy /
  migration.
- [ ] Delete settxfee and paytxfee rpc's.
    - [ ] [#32138](https://github.com/bitcoin/bitcoin/pull/32138)
