// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Generic interface that any market maker used by the ledger must implement.
/// @dev All functions are expected to:
///      - perform pricing,
///      - enforce slippage,
///      - update their own internal state,
///      - and return the actual amount used/received.
///
///      If slippage conditions are not met, they MUST revert.
interface IMarketMaker {
    /// @notice Buy exact `t` tokens (BACK or LAY).
    /// @param marketId   Market identifier on the MM side.
    /// @param positionId Position identifier within the market.
    /// @param isBack     true = Back(i), false = Lay(i).
    /// @param t          Exact number of tokens the trader wants to receive.
    /// @param maxUSDCIn  Max ppUSDC / USDC the trader is willing to spend.
    /// @return usdcIn    Actual ppUSDC / USDC cost of the trade.
    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external returns (uint256 usdcIn);

    /// @notice Buy using exact `usdcIn`, MM determines tokensOut.
    /// @return tokensOut Actual tokens received by the trader.
    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external returns (uint256 tokensOut);

    /// @notice Sell exact `t` tokens, MM returns `usdcOut`.
    /// @return usdcOut Actual ppUSDC / USDC the trader receives.
    function applySellExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) external returns (uint256 usdcOut);

    /// @notice Sell tokens to receive exact `usdcOut`, MM returns tokensIn.
    /// @return tokensIn Actual number of tokens the trader had to sell.
    function applySellForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) external returns (uint256 tokensIn);
}

