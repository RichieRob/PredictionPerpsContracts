// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./0_Types.sol";
import "./1_StorageLib.sol";

/**
 * @title IntentLib — EIP-712 hashing for "buy-only" intents
 *
 * @notice
 *  The protocol executes both "buy" and "sell" semantics on-chain.
 *  
 *  However on the front end and for order handling there will be no "sell" intents.
 *  Instead "sell" intents will be submitted as "buy" intents.
 *
 *  Frontend / off-chain matching MUST transform every user action
 *  into one of the two canonical intent forms:
 *
 *      - BUY_EXACT_TOKENS   (buy N tokens, price floats)
 *      - BUY_FOR_USDC       (spend up to X USDC, tokens float)
 *
 *  This requires converting SELL actions into equivalent BUY actions:
 *
 *      • Selling BACK  (user gives BACK)  == Buying LAY  at price (1 - p)
 *      • Selling LAY   (user gives LAY)   == Buying BACK at price (1 - p)
 *
 *  Where full-set price = 1.0 by definition (Back + Lay = 1 USDC).
 *
 *  Frontend responsibilities:
 *    1. Detect if user clicked "Sell Back" or "Sell Lay".
 *    2. Convert it into a "Buy" intent:
 *          - Flip `isBack`
 *          - Adjust price or bound:
 *                p_buy_opposite = (1 - p_sell)
 *          - Keep same token amount
 *    3. Sign the EIP-712 intent using ONLY the BUY_* TradeKind values.
 *
 *  As a result:
 *      "Sell 20 Lay for 5 USDC"  becomes  "Buy 20 Back for 15 USDC".
 *      "Sell 20 Back for 15 USDC" becomes "Buy 20 Lay for 5 USDC".
 *
 *  The ledger then processes all intents uniformly:
 *      transferPosition(...) + transferFreeCollateral(...)
 *
 *  This keeps the on-chain logic minimal and symmetric while allowing
 *  any expressive "sell" UX off-chain.
 */

 
library IntentLib {
    event IntentCancelled(
        address indexed trader,
        uint256 indexed marketId,
        uint256 indexed positionId,
        uint256 nonce,
        bytes32 intentHash
    );

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

    bytes32 internal constant NAME_HASH    = keccak256("PredictionPerps-Intents");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

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
                intent.kind,
                intent.primaryAmount,
                intent.bound,
                intent.nonce,
                intent.deadline
            )
        );
    }

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

    function cancelIntent(Types.Intent calldata intent) internal {
        require(intent.trader == msg.sender, "not trader");

        bytes32 key = hashIntent(intent);

        StorageLib.Storage storage s = StorageLib.getStorage();
        StorageLib.IntentState storage st = s.intentStates[key];

        require(!st.cancelled, "already cancelled");
        st.cancelled = true;

        emit IntentCancelled(
            msg.sender,
            intent.marketId,
            intent.positionId,
            intent.nonce,
            key
        );
    }
}
