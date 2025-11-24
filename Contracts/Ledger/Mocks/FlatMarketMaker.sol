// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interfaces/IMarketMaker.sol";

/// @notice Super-dumb flat-pricing market maker for tests.
/// t and price are 1e6-scaled, and we divide by 1e6 so that:
///   usdcIn = t * price / 1e6
contract FlatMockMarketMaker is IMarketMaker {
    uint256 internal constant ONE = 1_000_000; // 1e6

    // prices in 1e6 (so 900_000 = 0.9 USDC per token)
    uint256 public constant PRICE_A        = 900_000; // positionId 0
    uint256 public constant PRICE_B        = 800_000; // positionId 1
    uint256 public constant DEFAULT_PRICE  = 1_000_000;

    function _price(
        uint256 /*marketId*/,
        uint256 positionId,
        bool    /*isBack*/
    ) internal pure returns (uint256) {
        if (positionId == 0) return PRICE_A;
        if (positionId == 1) return PRICE_B;
        return DEFAULT_PRICE;
    }

    // ------------- BUY -------------

    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external pure override returns (uint256 usdcIn) {
        require(t > 0, "t=0");
        uint256 p = _price(marketId, positionId, isBack);
        usdcIn = (t * p) / ONE; // scale down
        require(usdcIn <= maxUSDCIn, "slippage");
    }

    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external pure override returns (uint256 tokensOut) {
        require(usdcIn > 0, "usdcIn=0");
        uint256 p = _price(marketId, positionId, isBack);
        tokensOut = (usdcIn * ONE) / p;
        require(tokensOut >= minTokensOut, "slippage");
    }

    // ------------- SELL -------------

    function applySellExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) external pure override returns (uint256 usdcOut) {
        require(t > 0, "t=0");
        uint256 p = _price(marketId, positionId, isBack);
        usdcOut = (t * p) / ONE;
        require(usdcOut >= minUSDCOut, "slippage");
    }

    function applySellForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) external pure override returns (uint256 tokensIn) {
        require(usdcOut > 0, "usdcOut=0");
        uint256 p = _price(marketId, positionId, isBack);
        tokensIn = (usdcOut * ONE) / p;
        require(tokensIn <= maxTokensIn, "slippage");
    }
}
