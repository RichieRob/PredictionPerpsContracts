// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./7a_SettlementLib.sol";
import "./2_MarketManagementLib.sol";
import "./0_Types.sol";
import "../Interfaces/IMarketMaker.sol";

library TradeRouterLib {
    using Types for *;

    /// @dev Main entrypoint for MM trades using ppUSDC.
    /// - `primaryAmount` / `bound` semantics depend on `kind`:
    ///   - BUY_EXACT_TOKENS:  primaryAmount = t,        bound = maxUSDCIn
    ///   - BUY_FOR_USDC:      primaryAmount = usdcIn,   bound = minTokensOut
    ///   - SELL_EXACT_TOKENS: primaryAmount = t,        bound = minUSDCOut
    ///   - SELL_FOR_USDC:     primaryAmount = usdcOut,  bound = maxTokensIn
    function tradeWithPPUSDC(
        Types.TradeKind kind,
        address          trader,
        address          mm,
        uint256          marketId,
        uint256          positionId,
        bool             isBack,
        uint256          primaryAmount,
        uint256          bound
    ) internal {
        require(mm != address(0), "mm=0");
        require(primaryAmount > 0, "amt=0");
        require(
            MarketManagementLib.positionExists(marketId, positionId),
            "pos !exists"
        );

        if (kind == Types.TradeKind.BUY_EXACT_TOKENS) {
            // primaryAmount = t, bound = maxUSDCIn
            uint256 t       = primaryAmount;
            uint256 maxIn   = bound;

            uint256 usdcIn = IMarketMaker(mm).applyBuyExactTokens(
                marketId,
                positionId,
                isBack,
                t,
                maxIn
            );

            // trader pays usdcIn, receives t tokens from mm
            SettlementLib.settleWithFlash(
                trader, // payer
                mm,     // payee
                marketId,
                positionId,
                isBack,
                t,       // base
                usdcIn   // quote
            );

        } else if (kind == Types.TradeKind.BUY_FOR_USDC) {
            // primaryAmount = usdcIn, bound = minTokensOut
            uint256 usdcIn      = primaryAmount;
            uint256 minTokens   = bound;

            uint256 tokensOut = IMarketMaker(mm).applyBuyForUSDC(
                marketId,
                positionId,
                isBack,
                usdcIn,
                minTokens
            );

            // trader pays usdcIn, receives tokensOut from mm
            SettlementLib.settleWithFlash(
                trader,
                mm,
                marketId,
                positionId,
                isBack,
                tokensOut,
                usdcIn
            );

        } else if (kind == Types.TradeKind.SELL_EXACT_TOKENS) {
            // primaryAmount = t, bound = minUSDCOut
            uint256 t          = primaryAmount;
            uint256 minUSDCOut = bound;

            uint256 usdcOut = IMarketMaker(mm).applySellExactTokens(
                marketId,
                positionId,
                isBack,
                t,
                minUSDCOut
            );

            // mm pays usdcOut, receives t tokens from trader
            SettlementLib.settleWithFlash(
                mm,      // payer
                trader,  // payee
                marketId,
                positionId,
                isBack,
                t,
                usdcOut
            );

        } else if (kind == Types.TradeKind.SELL_FOR_USDC) {
            // primaryAmount = usdcOut, bound = maxTokensIn
            uint256 usdcOut    = primaryAmount;
            uint256 maxTokens  = bound;

            uint256 tokensIn = IMarketMaker(mm).applySellForUSDC(
                marketId,
                positionId,
                isBack,
                usdcOut,
                maxTokens
            );

            // mm pays usdcOut, receives tokensIn from trader
            SettlementLib.settleWithFlash(
                mm,
                trader,
                marketId,
                positionId,
                isBack,
                tokensIn,
                usdcOut
            );

        } else {
            revert("BAD_KIND");
        }
    }
}
