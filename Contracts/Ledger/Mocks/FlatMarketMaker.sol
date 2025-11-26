// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interfaces/IMarketMaker.sol";
import { SD59x18, sd } from "@prb/math/src/SD59x18.sol";


/// @title FlatMockMarketMaker
/// @notice Same flat pricing as before, but now wastes gas
///         by doing one exp + ln using PRBMathSD59x18 per call.
contract FlatMockMarketMaker is IMarketMaker {

    uint256 internal constant ONE = 1_000_000; // 1e6

    uint256 public constant PRICE_A       = 900_000;  // positionId 0
    uint256 public constant PRICE_B       = 800_000;  // positionId 1
    uint256 public constant DEFAULT_PRICE = 1_000_000;

    function _price(
        uint256 /*marketId*/,
        uint256 positionId,
        bool    /*isBack*/
    ) internal pure returns (uint256) {
        if (positionId == 0) return PRICE_A;
        if (positionId == 1) return PRICE_B;
        return DEFAULT_PRICE;
    }

    // Gas burner using PRBMath: one exp followed by ln (natural log)
    // Input must be positive for ln; we use abs(x) + small offset to avoid issues.
    function _burnGas(int256 x) internal pure {
        // Wrap into typed fixed-point
        int256 raw = x < 0 ? -x : x;
        if (raw == 0) {
            raw = 1e18; // avoid ln(0)
        }

        SD59x18 positiveX = sd(raw);

        // exp(x) then ln(exp(x)) just to burn gas
        SD59x18 expResult = positiveX.exp();
        SD59x18 lnResult  = expResult.ln();

        // silence unused variable warning
        lnResult;
    }


    // ------------- BUY -------------

    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external pure override returns (uint256 usdcIn) {
        //_burnGas(int256(t)); // ← burn: exp + ln
        uint256 p = _price(marketId, positionId, isBack);
        usdcIn = (t * p) / ONE;
        require(usdcIn <= maxUSDCIn, "slippage");
    }

    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external pure override returns (uint256 tokensOut) {
        //_burnGas(int256(usdcIn));
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
       // _burnGas(int256(t));
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
      //  _burnGas(int256(usdcOut));
        uint256 p = _price(marketId, positionId, isBack);
        tokensIn = (usdcOut * ONE) / p;
        require(tokensIn <= maxTokensIn, "slippage");
    }
}