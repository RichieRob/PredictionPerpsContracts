// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LedgerLibraries/0_Types.sol";

interface ILedgerIntent {
    function settleIntentP2P(
        address trader,
        address filler,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 fillPrimary,
        uint256 fillQuote
    ) external;
}

contract IntentContract {
    ILedgerIntent public immutable ledger;

    struct IntentState {
        uint128 filledPrimary;
        bool    cancelled;
    }

    mapping(bytes32 => IntentState) public intentStates;

    event IntentCancelled(
        address indexed trader,
        uint256 indexed marketId,
        uint256 indexed positionId,
        uint256 nonce,
        bytes32 intentHash
    );

    // ─────────────────────────────────────────────
    // EIP-712 constants (copy of your IntentLib)
    // ─────────────────────────────────────────────

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

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

    constructor(address _ledger) {
        require(_ledger != address(0), "ledger=0");
        ledger = ILedgerIntent(_ledger);
    }

    // Domain uses *this* contract as verifyingContract.
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

    function _hashIntent(Types.Intent memory intent)
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

    function _digest(Types.Intent memory intent)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                _hashIntent(intent)
            )
        );
    }

    function _recoverSigner(
        Types.Intent memory intent,
        bytes memory sig
    ) internal view returns (address) {
        require(sig.length == 65, "bad sig length");
        bytes32 d = _digest(intent);

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

    // ─────────────────────────────────────────────
    // Core settlement logic (was FillIntentLib)
    // ─────────────────────────────────────────────

    function fillIntent(
        Types.Intent calldata intent,
        bytes calldata signature,
        uint256 fillPrimary,  // tokens
        uint256 fillQuote     // ppUSDC / USDC
    ) external {
        require(intent.trader != address(0), "trader=0");
        require(block.timestamp <= intent.deadline, "intent expired");
        require(fillPrimary > 0, "fillPrimary=0");
        require(fillQuote  > 0, "fillQuote=0");

        // Only BUY intents supported
        require(
            intent.kind == Types.TradeKind.BUY_EXACT_TOKENS ||
            intent.kind == Types.TradeKind.BUY_FOR_USDC,
            "intent kind not supported"
        );

        // Sig check
        address signer = _recoverSigner(intent, signature);
        require(signer == intent.trader, "bad sig");

        bytes32 key = _hashIntent(intent);
        IntentState storage st = intentStates[key];

        require(!st.cancelled, "intent cancelled");
        require(st.filledPrimary < intent.primaryAmount, "fully filled");
        require(
            st.filledPrimary + fillPrimary <= intent.primaryAmount,
            "overfill"
        );

        st.filledPrimary += uint128(fillPrimary);

        // P2P settlement: intent.trader = buyer, msg.sender = seller
        address buyer  = intent.trader;
        address seller = msg.sender;

        require(seller != address(0), "seller=0");
        require(seller != buyer, "self-fill not allowed");

        // --- Price guards (same logic as your FillIntentLib) ---

        if (intent.kind == Types.TradeKind.BUY_EXACT_TOKENS) {
            // (fillQuote / fillPrimary) <= (bound / primaryAmount)
            require(
                fillQuote * intent.primaryAmount
                    <= intent.bound * fillPrimary,
                "price > limit"
            );

            require(fillPrimary <= intent.primaryAmount, "fill > tokens");
            require(fillQuote  <= intent.bound,          "fill > bound");

        } else {
            // BUY_FOR_USDC
            // (fillPrimary / fillQuote) >= (bound / primaryAmount)
            require(
                fillPrimary * intent.primaryAmount
                    >= intent.bound * fillQuote,
                "price < min"
            );

            require(fillQuote  <= intent.primaryAmount, "fill > maxUSDC");
        }

        // Call into the ledger to actually move balances and enforce solvency
        ledger.settleIntentP2P(
            buyer,
            seller,
            intent.marketId,
            intent.positionId,
            intent.isBack,
            fillPrimary,
            fillQuote
        );
    }

    function cancelIntent(Types.Intent calldata intent) external {
        require(intent.trader == msg.sender, "not trader");

        bytes32 key = _hashIntent(intent);
        IntentState storage st = intentStates[key];

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
