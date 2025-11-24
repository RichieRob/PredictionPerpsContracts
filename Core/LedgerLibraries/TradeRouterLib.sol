// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TradeExecutionLib.sol";
import "./MarketManagementLib.sol";
import "./Types.sol";

library TradeRouterLib {
    using Types for *;

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
            TradeExecutionLib.buyExactTokens(
                trader,
                mm,
                marketId,
                positionId,
                isBack,
                primaryAmount, // t
                bound          // maxUSDCIn
            );

        } else if (kind == Types.TradeKind.BUY_FOR_USDC) {
            TradeExecutionLib.buyForUSDC(
                trader,
                mm,
                marketId,
                positionId,
                isBack,
                primaryAmount, // usdcIn
                bound          // minTokensOut
            );

        } else if (kind == Types.TradeKind.SELL_EXACT_TOKENS) {
            TradeExecutionLib.sellExactTokens(
                trader,
                mm,
                marketId,
                positionId,
                isBack,
                primaryAmount, // t
                bound          // minUSDCOut
            );

        } else if (kind == Types.TradeKind.SELL_FOR_USDC) {
            TradeExecutionLib.sellForUSDC(
                trader,
                mm,
                marketId,
                positionId,
                isBack,
                primaryAmount, // usdcOut
                bound          // maxTokensIn
            );

        } else {
            revert("BAD_KIND");
        }
    }
}
