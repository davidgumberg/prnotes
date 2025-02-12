# IsMine

<details> 

<summary>The enums and typedefs</summary>

```cpp
/**
 * IsMine() return codes, which depend on ScriptPubKeyMan implementation.
 * Not every ScriptPubKeyMan covers all types, please refer to
 * https://github.com/bitcoin/bitcoin/blob/master/doc/release-notes/release-notes-0.21.0.md#ismine-semantics
 * for better understanding.
 *
 * For LegacyScriptPubKeyMan,
 * ISMINE_NO: the scriptPubKey is not in the wallet;
 * ISMINE_WATCH_ONLY: the scriptPubKey has been imported into the wallet;
 * ISMINE_SPENDABLE: the scriptPubKey corresponds to an address owned by the wallet user (can spend with the private key);
 * ISMINE_USED: the scriptPubKey corresponds to a used address owned by the wallet user;
 * ISMINE_ALL: all ISMINE flags except for USED;
 * ISMINE_ALL_USED: all ISMINE flags including USED;
 * ISMINE_ENUM_ELEMENTS: the number of isminetype enum elements.
 *
 * For DescriptorScriptPubKeyMan and future ScriptPubKeyMan,
 * ISMINE_NO: the scriptPubKey is not in the wallet;
 * ISMINE_SPENDABLE: the scriptPubKey matches a scriptPubKey in the wallet.
 * ISMINE_USED: the scriptPubKey corresponds to a used address owned by the wallet user.
 *
 */
enum isminetype : unsigned int {
    ISMINE_NO         = 0,
    ISMINE_WATCH_ONLY = 1 << 0,
    ISMINE_SPENDABLE  = 1 << 1,
    ISMINE_USED       = 1 << 2,
    ISMINE_ALL        = ISMINE_WATCH_ONLY | ISMINE_SPENDABLE,
    ISMINE_ALL_USED   = ISMINE_ALL | ISMINE_USED,
    ISMINE_ENUM_ELEMENTS,
};

typedef std::vector<unsigned char> valtype;
namespace {

/**
 * This is an enum that tracks the execution context of a script, similar to
 * SigVersion in script/interpreter. It is separate however because we want to
 * distinguish between top-level scriptPubKey execution and P2SH redeemScript
 * execution (a distinction that has no impact on consensus rules).
 */
enum class IsMineSigVersion
{
    TOP = 0,        //!< scriptPubKey execution
    P2SH = 1,       //!< P2SH redeemScript
    WITNESS_V0 = 2, //!< P2WSH witness script execution
};

/**
 * This is an internal representation of isminetype + invalidity.
 * Its order is significant, as we return the max of all explored
 * possibilities.
 */
enum class IsMineResult
{
    NO = 0,         //!< Not ours
    WATCH_ONLY = 1, //!< Included in watch-only balance
    SPENDABLE = 2,  //!< Included in all balances
    INVALID = 3,    //!< Not spendable by anyone (uncompressed pubkey in segwit, P2SH inside P2SH or witness, witness inside witness)
};
```

</details>

```cpp
typedef std::vector<unsigned char> valtype;

// [ just wraps the return values of IsMineInner, note that both invalid and no
//   results return ISMINE_NO ]
isminetype LegacyDataSPKM::IsMine(const CScript& script) const
{
    switch (IsMineInner(*this, script, IsMineSigVersion::TOP)) {
    case IsMineResult::INVALID:
    case IsMineResult::NO:
        return ISMINE_NO;
    case IsMineResult::WATCH_ONLY:
        return ISMINE_WATCH_ONLY;
    case IsMineResult::SPENDABLE:
        return ISMINE_SPENDABLE;
    }
    assert(false);
}

namespace {

// [ Standardness rules forbid uncompressed pubkeys in segwit transactions (bip
//  143), and despite the strange name (imo), sigversion represents the IsMine
//  parsing context, starts at TOP, and is invoked recursively with different
//  contexts inside]
bool PermitsUncompressed(IsMineSigVersion sigversion)
{
    // [ permitted at the top level (p2pk) and inside of a p2sh. ] 
    return sigversion == IsMineSigVersion::TOP || sigversion == IsMineSigVersion::P2SH;
}

//! Recursively solve script and return spendable/watchonly/invalid status.
//!
//! @param keystore            legacy key and script store
//! @param scriptPubKey        script to solve
//! @param sigversion          script type (top-level / redeemscript / witnessscript)
//! @param recurse_scripthash  whether to recurse into nested p2sh and p2wsh
//!                            scripts or simply treat any script that has been
//!                            stored in the keystore as spendable
// NOLINTNEXTLINE(misc-no-recursion)
IsMineResult IsMineInner(const LegacyDataSPKM& keystore, const CScript& scriptPubKey, IsMineSigVersion sigversion, bool recurse_scripthash=true)
{
    // [ An early return means no. ]
    IsMineResult ret = IsMineResult::NO;

    std::vector<valtype> vSolutions;
    TxoutType whichType = Solver(scriptPubKey, vSolutions);

    CKeyID keyID;
    switch (whichType) {
    case TxoutType::NONSTANDARD:
    case TxoutType::NULL_DATA:
    case TxoutType::WITNESS_UNKNOWN:
    case TxoutType::WITNESS_V1_TAPROOT:
    case TxoutType::ANCHOR:
        // [ interesting.. these will be handled later.
        //   later: returns ret ]
        break;
    case TxoutType::PUBKEY:
        // [ Get the pkh of the pubkey in the p2pk. ]
        keyID = CPubKey(vSolutions[0]).GetID();
        // [ Standardness rules forbid uncompressed pubkeys in segwit
        //   transactions (bip 143), so if uncompressed is unpermitted, invalid. ]
        if (!PermitsUncompressed(sigversion) && vSolutions[0].size() != 33) {
            return IsMineResult::INVALID;
        }
        // [ Check mapKeys or mapCryptedKeys for the pkh/ckeyid ] 
        if (keystore.HaveKey(keyID)) {
            // [ interesting that the ismine is always set to the std::max
            //   (greater) of it's existing value and the new value. ]
            ret = std::max(ret, IsMineResult::SPENDABLE);
        }
        break;
    case TxoutType::WITNESS_V0_KEYHASH:
    {
        if (sigversion == IsMineSigVersion::WITNESS_V0) {
            // P2WPKH inside P2WSH is invalid.
            return IsMineResult::INVALID;
        }
        // [ the solutions value returned by solver is the witness program with
        //   the version byte and pushbytes removed, so we recreate it below,
        //   the CScript serializer nicely handles prepending a push based on the
        //   length of the vSolutions[0]. ]
        if (sigversion == IsMineSigVersion::TOP && !keystore.HaveCScript(CScriptID(CScript() << OP_0 << vSolutions[0]))) {
            // We do not support bare witness outputs unless the P2SH version of it would be
            // acceptable as well. This protects against matching before segwit activates.
            // This also applies to the P2WSH case.
            // [ breaking generally ends with returning IsMineResult::NO, the only last
            //   chance it gets is if HaveWatchOnly(scriptpubkey) ]
            break;
        }
        ret = std::max(ret, IsMineInner(keystore, GetScriptForDestination(PKHash(uint160(vSolutions[0]))), IsMineSigVersion::WITNESS_V0));
        break;
    }
    case TxoutType::PUBKEYHASH:
        keyID = CKeyID(uint160(vSolutions[0]));
        if (!PermitsUncompressed(sigversion)) {
            CPubKey pubkey;
            if (keystore.GetPubKey(keyID, pubkey) && !pubkey.IsCompressed()) {
                return IsMineResult::INVALID;
            }
        }
        if (keystore.HaveKey(keyID)) {
            ret = std::max(ret, IsMineResult::SPENDABLE);
        }
        break;
    case TxoutType::SCRIPTHASH:
    {
        if (sigversion != IsMineSigVersion::TOP) {
            // P2SH inside P2WSH or P2SH is invalid.
            return IsMineResult::INVALID;
        }
        CScriptID scriptID = CScriptID(uint160(vSolutions[0]));
        CScript subscript;
        if (keystore.GetCScript(scriptID, subscript)) {
            ret = std::max(ret, recurse_scripthash ? IsMineInner(keystore, subscript, IsMineSigVersion::P2SH) : IsMineResult::SPENDABLE);
        }
        break;
    }
    case TxoutType::WITNESS_V0_SCRIPTHASH:
    {
        if (sigversion == IsMineSigVersion::WITNESS_V0) {
            // P2WSH inside P2WSH is invalid.
            return IsMineResult::INVALID;
        }
        if (sigversion == IsMineSigVersion::TOP && !keystore.HaveCScript(CScriptID(CScript() << OP_0 << vSolutions[0]))) {
            break;
        }
        CScriptID scriptID{RIPEMD160(vSolutions[0])};
        CScript subscript;
        if (keystore.GetCScript(scriptID, subscript)) {
            ret = std::max(ret, recurse_scripthash ? IsMineInner(keystore, subscript, IsMineSigVersion::WITNESS_V0) : IsMineResult::SPENDABLE);
        }
        break;
    }

    case TxoutType::MULTISIG:
    {
        // Never treat bare multisig outputs as ours (they can still be made watchonly-though)
        if (sigversion == IsMineSigVersion::TOP) {
            break;
        }

        // Only consider transactions "mine" if we own ALL the
        // keys involved. Multi-signature transactions that are
        // partially owned (somebody else has a key that can spend
        // them) enable spend-out-from-under-you attacks, especially
        // in shared-wallet situations.
        std::vector<valtype> keys(vSolutions.begin()+1, vSolutions.begin()+vSolutions.size()-1);
        if (!PermitsUncompressed(sigversion)) {
            for (size_t i = 0; i < keys.size(); i++) {
                if (keys[i].size() != 33) {
                    return IsMineResult::INVALID;
                }
            }
        }
        if (HaveKeys(keys, keystore)) {
            ret = std::max(ret, IsMineResult::SPENDABLE);
        }
        break;
    }
    } // no default case, so the compiler can warn about missing cases

    if (ret == IsMineResult::NO && keystore.HaveWatchOnly(scriptPubKey)) {
        ret = std::max(ret, IsMineResult::WATCH_ONLY);
    }
    return ret;
}
} // namespace


// [ https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki#witness-program ]
// A witness program is any valid CScript that consists of a 1-byte push opcode
// followed by a data push between 2 and 40 bytes.
bool CScript::IsWitnessProgram(int& version, std::vector<unsigned char>& program) const
{
    // [ shortest witness program is op_0 || op_push2bytes || {arbitrary 2-bytes }
    //   longest is op_0 || op_push40 || {arbitrary 40-bytes} ]
    } 
    if (this->size() < 4 || this->size() > 42) {
        return false;
    }
    // [ check witness version number
    if ((*this)[0] != OP_0 && ((*this)[0] < OP_1 || (*this)[0] > OP_16)) {
        return false;
    }
    if ((size_t)((*this)[1] + 2) == this->size()) {
        version = DecodeOP_N((opcodetype)(*this)[0]);
        // [ The returned "program" omits the witness version and the pushbytes
        //   opcode. ]
        program = std::vector<unsigned char>(this->begin() + 2, this->end());
        return true;
    }
    return false;
}

```
