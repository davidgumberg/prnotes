_All code comments in `[]` are my own._

## Miniscript Node

A node in a miniscript expression is represented by an instance of `struct
Node`, which is a templated for different key types:

```cpp
template<typename Key> struct Node;
```

Node has the following data members:

```cpp
    //! What node type this node is.
    const Fragment fragment;
    //! The k parameter (time for OLDER/AFTER, threshold for THRESH(_M))
    const uint32_t k = 0;

    // [ These three are the only fragments that take keys as arguments.
    //! The keys used by this expression (only for PK_K/PK_H/MULTI)
    const std::vector<Key> keys;
    //! The data bytes in this expression (only for HASH160/HASH256/SHA256/RIPEMD10).
    const std::vector<unsigned char> data;
    
    // [ NodeRef is a std::shared_ptr<const Node<Key>> ]
    //! Subexpressions (for WRAP_*/AND_*/OR_*/ANDOR/THRESH)
    mutable std::vector<NodeRef<Key>> subs;
    //! The Script context for this node. Either P2WSH or Tapscript.
    const MiniscriptContext m_script_ctx;
```
#### `fragment`

Fragment is an `enum class`  that encodes each miniscript node type, the
miniscript language consists of 'fragments' like "pk_h(arg)" that translate a
semantic like "pubkey hash of arg" semantic to bitcoin script of `DUP HASH160 <HASH160(key)>
EQUALVERIFY`, these are also described here: https://bitcoin.sipa.be/miniscript/
under the "Translation table" heading.
 
<details>

<summary>Fragments</summary> 

```cpp
//! The different node types in miniscript.
enum class Fragment {
    JUST_0,    //!< OP_0
    JUST_1,    //!< OP_1
    PK_K,      //!< [key]
    PK_H,      //!< OP_DUP OP_HASH160 [keyhash] OP_EQUALVERIFY
    OLDER,     //!< [n] OP_CHECKSEQUENCEVERIFY
    AFTER,     //!< [n] OP_CHECKLOCKTIMEVERIFY
    SHA256,    //!< OP_SIZE 32 OP_EQUALVERIFY OP_SHA256 [hash] OP_EQUAL
    HASH256,   //!< OP_SIZE 32 OP_EQUALVERIFY OP_HASH256 [hash] OP_EQUAL
    RIPEMD160, //!< OP_SIZE 32 OP_EQUALVERIFY OP_RIPEMD160 [hash] OP_EQUAL
    HASH160,   //!< OP_SIZE 32 OP_EQUALVERIFY OP_HASH160 [hash] OP_EQUAL
    WRAP_A,    //!< OP_TOALTSTACK [X] OP_FROMALTSTACK
    WRAP_S,    //!< OP_SWAP [X]
    WRAP_C,    //!< [X] OP_CHECKSIG
    WRAP_D,    //!< OP_DUP OP_IF [X] OP_ENDIF
    WRAP_V,    //!< [X] OP_VERIFY (or -VERIFY version of last opcode in X)
    WRAP_J,    //!< OP_SIZE OP_0NOTEQUAL OP_IF [X] OP_ENDIF
    WRAP_N,    //!< [X] OP_0NOTEQUAL
    AND_V,     //!< [X] [Y]
    AND_B,     //!< [X] [Y] OP_BOOLAND
    OR_B,      //!< [X] [Y] OP_BOOLOR
    OR_C,      //!< [X] OP_NOTIF [Y] OP_ENDIF
    OR_D,      //!< [X] OP_IFDUP OP_NOTIF [Y] OP_ENDIF
    OR_I,      //!< OP_IF [X] OP_ELSE [Y] OP_ENDIF
    ANDOR,     //!< [X] OP_NOTIF [Z] OP_ELSE [Y] OP_ENDIF
    THRESH,    //!< [X1] ([Xn] OP_ADD)* [k] OP_EQUAL
    MULTI,     //!< [k] [key_n]* [n] OP_CHECKMULTISIG (only available within P2WSH context)
    MULTI_A,   //!< [key_0] OP_CHECKSIG ([key_n] OP_CHECKSIGADD)* [k] OP_NUMEQUAL (only within Tapscript ctx)
    // AND_N(X,Y) is represented as ANDOR(X,Y,0)
    // WRAP_T(X) is represented as AND_V(X,1)
    // WRAP_L(X) is represented as OR_I(0,X)
    // WRAP_U(X) is represented as OR_I(X,0)
};
</details>
