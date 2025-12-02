// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./0_Types.sol";
import "./2_IntentLib.sol";
import "./2_FreeCollateralLib.sol";
import "./7_PositionTransferLib.sol";
import "./4_SolvencyLib.sol";
import "./7a_SettlementLib.sol"; // <— new import

library FillIntentLib {
    /// @dev Pure P2P settlement: trader is always the buyer, msg.sender is the seller.
    function _settleIntentP2P(
        Types.Intent calldata intent,
        uint256 fillPrimary,  // tokens
        uint256 fillQuote     // ppUSDC / USDC
    ) internal {
        address buyer  = intent.trader;   // always the buyer
        address seller = msg.sender;

        require(seller != address(0), "seller=0");
        require(seller != buyer, "self-fill not allowed"); // optional

        // --- Price guard (buy-only semantics) ---
        if (intent.kind == Types.TradeKind.BUY_EXACT_TOKENS) {
            // (fillQuote / fillPrimary) <= (bound / primaryAmount)
            require(
                fillQuote * intent.primaryAmount
                    <= intent.bound * fillPrimary,
                "price > limit"
            );

            require(fillPrimary <= intent.primaryAmount, "fill > tokens");
            require(fillQuote  <= intent.bound,          "fill > bound");

        } else if (intent.kind == Types.TradeKind.BUY_FOR_USDC) {
            // (fillPrimary / fillQuote) >= (bound / primaryAmount)
            require(
                fillPrimary * intent.primaryAmount
                    >= intent.bound * fillQuote,
                "price < min"
            );

            require(fillQuote  <= intent.primaryAmount, "fill > maxUSDC");
        } else {
            revert("BAD_KIND");
        }

        // Settlement:
        // - buyer is payer of quote (fillQuote), receives the position
        // - seller is payee, gives up the position
        SettlementLib.settleWithFlash(
            buyer,
            seller,
            intent.marketId,
            intent.positionId,
            intent.isBack,
            fillPrimary,
            fillQuote

        );
    }

    /// @dev Full intent flow: verify sig, track partial fills, then settle P2P.
    /// Must be called from the ledger contract (via delegatecall).
    function _fillIntent(
        Types.Intent calldata intent,
        bytes calldata signature,
        uint256 fillPrimary,
        uint256 fillQuote
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        require(intent.trader != address(0), "trader=0");
        require(block.timestamp <= intent.deadline, "intent expired");
        require(fillPrimary > 0, "fillPrimary=0");
        require(fillQuote  > 0, "fillQuote=0");

        // Only BUY intents supported (SELLs can be represented as BUYs)
        require(
            intent.kind == Types.TradeKind.BUY_EXACT_TOKENS ||
            intent.kind == Types.TradeKind.BUY_FOR_USDC,
            "intent kind not supported"
        );

        // EIP-712 sig check
        address signer = IntentLib.recoverSigner(intent, signature);
        require(signer == intent.trader, "bad sig");

        bytes32 key = IntentLib.hashIntent(intent);
        StorageLib.IntentState storage st = s.intentStates[key];

        require(!st.cancelled, "intent cancelled");
        require(st.filledPrimary < intent.primaryAmount, "fully filled");
        require(
            st.filledPrimary + fillPrimary <= intent.primaryAmount,
            "overfill"
        );

        st.filledPrimary += fillPrimary;

        _settleIntentP2P(intent, fillPrimary, fillQuote);
    }
}
