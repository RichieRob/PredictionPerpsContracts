// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";
import "../LMSRMarketMaker.sol";
import "./LMSRMathLib.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRQuoteLib
/// @notice Pure LMSR pricing formulas (BACK + LAY) using closed-form expressions.
///
/// ## SCALING OVERVIEW
/// - All quantities that represent *real numbers* such as probabilities,
///   exponentials, and ln/exp inputs **must be 1e18-scaled (WAD)**.
///   This is because PRBMathSD59x18 expects fixed-point 59x18 inputs.
///
/// - All *USDC amounts* (m, b, t) remain **1e6-scaled**.
///
/// ## LOGIC SUMMARY
/// - We compute:
///       p = R_k / S               (1e18)
///       e = exp( ± t / b )        (1e18)
///       term = (...)              (1e18)
///       ln(term)                  (returns ln(termReal) * 1e18)
///       m = b * ln(termReal)      (converted to 1e6)
///
/// - Critically: ln() and exp() operate on 1e18-fixed-point reals.
///   To get back to 1e6 USDC, we multiply by b (1e6) and divide by 1e18.
///
/// - These routines now return **with-fee** amounts, applying FEE_BPS at the end.
library LMSRQuoteLib {
    using PRBMathSD59x18 for int256;
    using LMSRMathLib for int256;

    /// ---------------------------------------------------------------------
    /// BUY: price a trade of size `t` tokens (BACK or true LAY)
    /// ---------------------------------------------------------------------
    ///
    /// If BACK:
    ///     m = b ln( 1 - p + p e^{ +t/b } )
    ///
    /// If LAY (true not-i):
    ///     m = b ln( p + (1-p) e^{ +t/b } )
    ///
    /// NOTES ON SCALING:
    ///     - pWad, eTB, termWad, lnWad are all 1e18
    ///     - lnWad = ln(termReal) * 1e18
    ///     - mSigned = (b * lnWad) / 1e18   → 1e6
    ///     - We then apply the protocol fee:
    ///           mWithFee = mNoFee * (1 + FEE_BPS/10_000)
    function quoteBuyInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t
    ) internal view returns (uint256 mWithFee) {
        require(t > 0, "t=0");

        // Get the internal LMSR slot index for this ledger position.
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        // pWad = p * 1e18 = R_k / S
        int256 pWad = (self.R[marketId][slot] * int256(LMSRMarketMaker.WAD))
                    / self.S[marketId];

        // eTB = e^{+t/b} * 1e18
        int256 eTB  = LMSRMathLib.expRatioOverB(self.b[marketId], int256(uint256(t)));

        // termWad is always 1e18-scaled
        int256 termWad;
        if (isBack) {
            // term = 1 - p + p e^{t/b}
            termWad = int256(LMSRMarketMaker.WAD) - pWad + pWad.wmul(eTB);
        } else {
            // term = p + (1-p) e^{t/b}
            termWad = pWad + (int256(LMSRMarketMaker.WAD) - pWad).wmul(eTB);
        }

        // lnWad = ln(termReal) * 1e18
        int256 lnWad = termWad.ln();

        // Convert back to 1e6 USDC:
        // mNoFee = b * ln(termReal)
        // because lnWad = ln(termReal)*1e18
        int256 mSigned = (self.b[marketId] * lnWad) / int256(LMSRMarketMaker.WAD);
        require(mSigned >= 0, "negative m");

        uint256 mNoFee = uint256(mSigned);

        // Apply fee for BUY (user pays more):
        // mWithFee = mNoFee * (1 + FEE_BPS/10_000)
        mWithFee = (mNoFee * (10_000 + LMSRMarketMaker.FEE_BPS)) / 10_000;
    }

    /// ---------------------------------------------------------------------
    /// SELL: price a trade of size `t` tokens (BACK or true LAY)
    /// ---------------------------------------------------------------------
    ///
    /// If BACK:
    ///     m = b ln( 1 - p + p e^{ -t/b } )
    ///
    /// If LAY:
    ///     m = b ln( p + (1-p) e^{ -t/b } )
    ///
    /// We interpret `m` as the **pre-fee gross USDC out**, then apply the
    /// protocol fee so the trader receives:
    ///
    ///     mWithFee = mNoFee * (1 - FEE_BPS/10_000)
    ///
    /// Same scaling considerations as quoteBuyInternal.
    function quoteSellInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t
    ) internal view returns (uint256 mWithFee) {
        require(t > 0, "t=0");

        // Get the internal LMSR slot for the ledgerPositionId.
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        // p in 1e18
        int256 pWad = (self.R[marketId][slot] * int256(LMSRMarketMaker.WAD))
                    / self.S[marketId];

        // e^{-t/b} in 1e18 form
        int256 eNegTB = LMSRMathLib.expRatioOverB(self.b[marketId], -int256(uint256(t)));

        // termWad is what is inside the ln(..) multiplied up by 10^18
        int256 termWad;
        if (isBack) {
            // term = 1 - p + p e^{-t/b}
            termWad = int256(LMSRMarketMaker.WAD) - pWad + pWad.wmul(eNegTB);
        } else {
            // term = p + (1-p) e^{-t/b}
            termWad = pWad + (int256(LMSRMarketMaker.WAD) - pWad).wmul(eNegTB);
        }

        // lnWad is the result of taking ln(termReal) and then multiplying by 10^18
        int256 lnWad = termWad.ln();

        // mSigned is the pre-fee m in 1e6 units (USDC),
        // **not** multiplied by 1e18 anymore:
        //
        //   mNoFee = b * ln(termReal)
        int256 mSigned = (self.b[marketId] * lnWad) / int256(LMSRMarketMaker.WAD);
        require(mSigned >= 0, "negative m");

        uint256 mNoFee = uint256(mSigned);

        // Apply fee for SELL (trader receives less):
        // mWithFee = mNoFee * (1 - FEE_BPS/10_000)
        mWithFee = (mNoFee * (10_000 - LMSRMarketMaker.FEE_BPS)) / 10_000;
    }

    /// ---------------------------------------------------------------------
    /// BUY FOR USDC: invert the cost function to compute t for a given m
    /// ---------------------------------------------------------------------
    ///
    /// If BACK:
    ///   x = exp(m/b)
    ///   y = 1 + (x - 1)/p
    ///   t = b ln(y)
    ///
    /// If LAY:
    ///   x = exp(m/b)
    ///   y = (x - p) / (1 - p)
    ///   t = b ln(y)
    ///
    /// SCALING:
    ///   - m, b, t are all 1e6
    ///   - x, y, p are 1e18
    ///   - ln() returns 1e18 scaling
    ///   - final tSigned is converted back to 1e6
    ///
    /// NOTE: here `mFinal` is **with-fee** USDC in. We first strip the fee
    /// to recover the internal LMSR m (pre-fee), then invert the formula.
    function quoteBuyForUSDCInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 mFinal
    ) internal view returns (uint256 tOut) {
        require(mFinal > 0, "bad m");

        // get the internal LMSR slot for the ledgerPositionId
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        // Remove fee → still 1e6 units
        // m = mFinal / (1 + FEE_BPS/10_000)
        uint256 m = (mFinal * 10_000) / (10_000 + LMSRMarketMaker.FEE_BPS);

        // p in 1e18
        int256 pWad = (self.R[marketId][slot] * int256(LMSRMarketMaker.WAD))
                    / self.S[marketId];
        require(pWad > 0 && pWad < int256(LMSRMarketMaker.WAD), "bad p");

        // mWad = (m/b) * 1e18   — the input to exp()
        int256 mbWad = (int256(uint256(m)) * int256(LMSRMarketMaker.WAD))
                    / self.b[marketId];

        // x = e^{m/b} in 1e18
        int256 x = mbWad.exp();

        int256 y;
        if (isBack) {
            // y = 1 + (x - 1) / p
            int256 numer = x - int256(LMSRMarketMaker.WAD);
            y = int256(LMSRMarketMaker.WAD)
                + (numer * int256(LMSRMarketMaker.WAD)) / pWad;
        } else {
            // y = (x - p) / (1 - p)
            int256 denom = int256(LMSRMarketMaker.WAD) - pWad;
            require(denom > 0, "den=0");

            int256 numer = x - pWad;
            require(numer > 0, "domain");

            y = (numer * int256(LMSRMarketMaker.WAD)) / denom;
        }

        // ln domain restriction (y >= 1)
        require(y >= int256(LMSRMarketMaker.WAD), "ln domain");

        // lnY = ln(yReal) * 1e18
        int256 lnY = y.ln();

        // Convert to 1e6:
        // t = b * ln(yReal)
        int256 tSigned =
            (self.b[marketId] * lnY) / int256(LMSRMarketMaker.WAD);

        require(tSigned >= 0, "no tokens");

        tOut = uint256(tSigned);
    }
}
