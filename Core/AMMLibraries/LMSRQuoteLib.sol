
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";
import "../LMSRMarketMaker.sol";
import "./LMSRMathLib.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRQuoteLib
/// @notice Library for quote-related functions in LMSRMarketMaker.
library LMSRQuoteLib {
    using PRBMathSD59x18 for int256;
    using LMSRMathLib for int256;

    /// @notice Internal implementation for quoting buy cost (pre-fee, 1e6).
    ///         If isBack=true:    m = b ln(1 - p + p e^{+t/b})
    ///         If isBack=false:   m = b ln(  p + (1-p) e^{+t/b})   // true LAY(not-i)
    function quoteBuyInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t
    ) internal view returns (uint256 mNoFee) {
        require(t > 0, "t=0");
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        int256 pWad = (self.R[marketId][slot] * int256(LMSRMarketMaker.WAD)) / LMSRHelpersLib.denom(self, marketId);
        int256 eTB  = LMSRMathLib.expRatioOverB(self.b[marketId], int256(uint256(t))); // e^{+t/b}

        int256 termWad;
        if (isBack)      termWad = int256(LMSRMarketMaker.WAD) - pWad + pWad.wmul(eTB);
        else             termWad = pWad + (int256(LMSRMarketMaker.WAD) - pWad).wmul(eTB);

        int256 lnWad = termWad.ln();
        int256 mSigned = (self.b[marketId] * lnWad) / int256(LMSRMarketMaker.WAD);
        require(mSigned >= 0, "negative m");
        mNoFee = uint256(mSigned);
    }

    /// @notice Internal implementation for quoting sell proceeds (pre-fee magnitude, 1e6).
    ///         If isBack=true:    m = b ln(1 - p + p e^{-t/b})
    ///         If isBack=false:   m = b ln(  p + (1-p) e^{-t/b})
    function quoteSellInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t
    ) internal view returns (uint256 mNoFeeMag) {
        require(t > 0, "t=0");
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        int256 pWad   = (self.R[marketId][slot] * int256(LMSRMarketMaker.WAD)) / LMSRHelpersLib.denom(self, marketId);
        int256 eNegTB = LMSRMathLib.expRatioOverB(self.b[marketId], -int256(uint256(t))); // e^{-t/b}

        int256 termWad;
        if (isBack)      termWad = int256(LMSRMarketMaker.WAD) - pWad + pWad.wmul(eNegTB);
        else             termWad = pWad + (int256(LMSRMarketMaker.WAD) - pWad).wmul(eNegTB);

        int256 lnWad = termWad.ln();
        int256 mSigned = (self.b[marketId] * lnWad) / int256(LMSRMarketMaker.WAD);
        require(mSigned >= 0, "negative m");
        mNoFeeMag = uint256(mSigned);
    }

    /// @notice Internal closed-form tokens for exact USDC-in (fee stripped first).
    /// If isBack=true:
    ///   x = exp(m/b);  y = 1 + (x-1)/p;       t =  b * ln(y)
    /// If isBack=false (true LAY):
    ///   x = exp(m/b);  y = (x - p) / (1 - p); t =  b * ln(y)
    function quoteBuyForUSDCInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 mFinal
    ) internal view returns (uint256 tOut) {
        require(mFinal > 0, "bad m");
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        // strip fee
        uint256 m = (mFinal * 10_000) / (10_000 + LMSRMarketMaker.FEE_BPS);

        int256 pWad = (self.R[marketId][slot] * int256(LMSRMarketMaker.WAD)) / LMSRHelpersLib.denom(self, marketId);
        require(pWad > 0 && pWad < int256(LMSRMarketMaker.WAD), "bad p");

        int256 mWad = (int256(uint256(m)) * int256(LMSRMarketMaker.WAD)) / self.b[marketId]; // m/b 1e18
        int256 x    = mWad.exp();

        int256 y;
        if (isBack) {
            // y = 1 + (x - 1)/p
            int256 numer = x - int256(LMSRMarketMaker.WAD);
            y = int256(LMSRMarketMaker.WAD) + (numer * int256(LMSRMarketMaker.WAD)) / pWad;
        } else {
            // y = (x - p) / (1 - p)
            int256 denom = int256(LMSRMarketMaker.WAD) - pWad;
            require(denom > 0, "denom=0");
            int256 numer = x - pWad;
            require(numer > 0, "domain");
            y = (numer * int256(LMSRMarketMaker.WAD)) / denom;
        }
        require(y >= int256(LMSRMarketMaker.WAD), "ln domain");

        int256 lnY = y.ln();
        int256 tSigned = (self.b[marketId] * lnY) / int256(LMSRMarketMaker.WAD); // 1e6
        require(tSigned >= 0, "no tokens");

        tOut = uint256(tSigned);
    }
}

