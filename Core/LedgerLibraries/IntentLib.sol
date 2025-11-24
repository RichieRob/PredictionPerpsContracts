// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Types.sol";

library IntentLib {
    // EIP-712 domain + struct typehashes
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // Must match Types.Intent layout exactly, in order.
    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent("
        "address trader,"
        "uint256 marketId,"
        "uint256 positionId,"
        "bool isBack,"
        "uint8 kind,"
        "uint256 primaryAmount,"
        "uint256 bound,"
        "uint256 nonce,"
        "uint256 deadline"
        ")"
    );

    // Domain name / version (these are what the frontend must use)
    bytes32 internal constant NAME_HASH    = keccak256("PredictionPerps-Intents");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    // -------------------------
    // Domain separator
    // -------------------------

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this) // the ledger contract
            )
        );
    }

    // -------------------------
    // Struct hash
    // -------------------------

    function hashIntent(Types.Intent memory intent)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.trader,
                intent.marketId,
                intent.positionId,
                intent.isBack,
                intent.kind,          // enum underlying type = uint8
                intent.primaryAmount,
                intent.bound,
                intent.nonce,
                intent.deadline
            )
        );
    }

    // -------------------------
    // Full EIP-712 digest
    // -------------------------

    function digest(Types.Intent memory intent)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                hashIntent(intent)
            )
        );
    }

    // -------------------------
    // Recover signer
    // -------------------------

    function recoverSigner(
        Types.Intent memory intent,
        bytes memory sig
    ) internal view returns (address) {
        require(sig.length == 65, "bad sig length");
        bytes32 d = digest(intent);

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        return ecrecover(d, v, r, s);
    }
}
