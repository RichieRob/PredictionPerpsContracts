// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Generic interface that any market maker used by the ledger must implement.
/// @dev All functions price the trade, enforce slippage, update MM internal state,
///      and return the actual amount used/received. NO token transfers here.
interface IMarketMaker {
    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external returns (uint256 usdcIn);

    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external returns (uint256 tokensOut);

    function applySellExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) external returns (uint256 usdcOut);

    function applySellForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) external returns (uint256 tokensIn);
}
