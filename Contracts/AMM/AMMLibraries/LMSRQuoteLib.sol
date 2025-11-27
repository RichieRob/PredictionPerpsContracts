// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SD59x18, sd } from "@prb/math/src/SD59x18.sol";
import "./LMSRStorageLib.sol";
import "./LMSRMathLib.sol";

/// @title LMSRQuoteLib
/// @notice Pure LMSR pricing formulas (BACK + LAY) using closed-form expressions.
///
/// SCALING:
/// - All *real* quantities (probabilities, exponentials, ln/exp inputs) are 1e18 (WAD).
/// - All *USDC amounts* and trade sizes (b, t, m) are 1e6.
///
/// This library:
/// - Works on LMSRStorageLib.State (no dependency on LMSRMarketMaker).
/// - Applies FEE_BPS internally for buy/sell quotes.
library LMSRQuoteLib {
    using LMSRMathLib for int256;

    uint256 internal constant WAD      = 1e18;
    uint256 internal constant FEE_BPS  = 30;    // e.g. 0.30% – set to whatever you want

    /*//////////////////////////////////////////////////////////////
                             INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireMarket(
        LMSRStorageLib.State storage s,
        uint256               marketId
    ) private view returns (LMSRStorageLib.Market storage m) {
        m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");
        require(m.S > 0, "LMSR: S=0");
    }

    /*//////////////////////////////////////////////////////////////
                                BUY – EXACT TOKENS
    //////////////////////////////////////////////////////////////*/

    /// If BACK:
    ///     m = b ln( 1 - p + p e^{ +t/b } )
    ///
    /// If LAY:
    ///     m = b ln( p + (1-p) e^{ +t/b } )
    ///
    /// Then apply fee:
    ///     mWithFee = mNoFee * (1 + FEE_BPS/10_000).
    function quoteBuyInternal(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 t
    ) internal view returns (uint256 mWithFee) {
        require(t > 0, "LMSR: t=0");

        LMSRStorageLib.Market storage m = _requireMarket(s, marketId);
        uint256 slot = LMSRStorageLib.requireListed(m, ledgerPositionId);

        // p = R_k / S (1e18)
        int256 pWad = (m.R[slot] * int256(WAD)) / m.S;

        // e^{+t/b} in 1e18
        int256 eTB = LMSRMathLib.expRatioOverB(m.b, int256(uint256(t)));

        int256 termWad;
        if (isBack) {
            // term = 1 - p + p e^{t/b}
            termWad = int256(WAD) - pWad + pWad.wmul(eTB);
        } else {
            // term = p + (1-p) e^{t/b}
            termWad = pWad + (int256(WAD) - pWad).wmul(eTB);
        }

        int256 lnWad = LMSRMathLib.lnWad(termWad);

        // mNoFee = b * ln(termReal)  (back to 1e6)
        int256 mSigned = (m.b * lnWad) / int256(WAD);
        require(mSigned >= 0, "LMSR: negative m");

        uint256 mNoFee = uint256(mSigned);

        // apply fee – trader pays more on BUY
        mWithFee = (mNoFee * (10_000 + FEE_BPS)) / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                                SELL – EXACT TOKENS
    //////////////////////////////////////////////////////////////*/

    /// If BACK:
    ///     m = b ln( 1 - p + p e^{ -t/b } )
    ///
    /// If LAY:
    ///     m = b ln( p + (1-p) e^{ -t/b } )
    ///
    /// We interpret `m` as pre-fee gross USDC out and then:
    ///     mWithFee = mNoFee * (1 - FEE_BPS/10_000).
    function quoteSellInternal(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 t
    ) internal view returns (uint256 mWithFee) {
        require(t > 0, "LMSR: t=0");

        LMSRStorageLib.Market storage m = _requireMarket(s, marketId);
        uint256 slot = LMSRStorageLib.requireListed(m, ledgerPositionId);

        int256 pWad = (m.R[slot] * int256(WAD)) / m.S;

        // e^{-t/b}
        int256 eNegTB = LMSRMathLib.expRatioOverB(m.b, -int256(uint256(t)));

        int256 termWad;
        if (isBack) {
            termWad = int256(WAD) - pWad + pWad.wmul(eNegTB);
        } else {
            termWad = pWad + (int256(WAD) - pWad).wmul(eNegTB);
        }

        int256 lnWad = LMSRMathLib.lnWad(termWad);

        int256 mSigned = (m.b * lnWad) / int256(WAD);
        require(mSigned >= 0, "LMSR: negative m");

        uint256 mNoFee = uint256(mSigned);

        // apply fee – trader receives less on SELL
        mWithFee = (mNoFee * (10_000 - FEE_BPS)) / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                          BUY FOR USDC – INVERT COST
    //////////////////////////////////////////////////////////////*/

    /// Invert buy formulas.
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
    /// `mFinal` is post-fee USDC in. We first strip fee to find internal m.
    function quoteBuyForUSDCInternal(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 mFinal
    ) internal view returns (uint256 tOut) {
        require(mFinal > 0, "LMSR: bad m");

        LMSRStorageLib.Market storage m = _requireMarket(s, marketId);
        uint256 slot = LMSRStorageLib.requireListed(m, ledgerPositionId);

        // remove fee
        uint256 mNoFee = (mFinal * 10_000) / (10_000 + FEE_BPS);

        int256 pWad = (m.R[slot] * int256(WAD)) / m.S;
        require(pWad > 0 && pWad < int256(WAD), "LMSR: bad p");

        int256 mbWad = (int256(uint256(mNoFee)) * int256(WAD)) / m.b;
        int256 x = sd(mbWad).exp().unwrap(); // e^{m/b}

        int256 y;
        if (isBack) {
            // y = 1 + (x - 1)/p
            int256 numer = x - int256(WAD);
            y = int256(WAD) + (numer * int256(WAD)) / pWad;
        } else {
            // y = (x - p) / (1 - p)
            int256 denom = int256(WAD) - pWad;
            require(denom > 0, "LMSR: den=0");
            int256 numer = x - pWad;
            require(numer > 0, "LMSR: domain");
            y = (numer * int256(WAD)) / denom;
        }

        require(y >= int256(WAD), "LMSR: ln domain");

        int256 lnY = sd(y).ln().unwrap();
        int256 tSigned = (m.b * lnY) / int256(WAD);
        require(tSigned >= 0, "LMSR: no tokens");

        tOut = uint256(tSigned);
    }

    /*//////////////////////////////////////////////////////////////
                         SELL FOR USDC – INVERT COST
    //////////////////////////////////////////////////////////////*/

    /// If BACK:
    ///   x = exp(m/b)
    ///   y = (x - 1 + p) / p       // y = e^{-t/b}
    ///   t = -b ln(y)
    ///
    /// If LAY:
    ///   x = exp(m/b)
    ///   y = (x - p) / (1 - p)     // y = e^{-t/b}
    ///   t = -b ln(y)
    ///
    /// `mFinal` is post-fee USDC out. We first strip fee to find internal m.
    function quoteSellForUSDCInternal(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 mFinal
    ) internal view returns (uint256 tOut) {
        require(mFinal > 0, "LMSR: bad m");

        LMSRStorageLib.Market storage m = _requireMarket(s, marketId);
        uint256 slot = LMSRStorageLib.requireListed(m, ledgerPositionId);

        // pre-fee internal m
        uint256 mNoFee = (mFinal * 10_000) / (10_000 - FEE_BPS);

        int256 pWad = (m.R[slot] * int256(WAD)) / m.S;
        require(pWad > 0 && pWad < int256(WAD), "LMSR: bad p");

        int256 mWad = (int256(uint256(mNoFee)) * int256(WAD)) / m.b;
        int256 x    = sd(mWad).exp().unwrap(); // e^{m/b}

        int256 y;
        if (isBack) {
            // y = (x - 1 + p) / p
            int256 numer = x + pWad - int256(WAD);
            require(numer > 0, "LMSR: domain");
            y = (numer * int256(WAD)) / pWad;
        } else {
            // y = (x - p) / (1 - p)
            int256 denom = int256(WAD) - pWad;
            require(denom > 0, "LMSR: den=0");
            int256 numer = x - pWad;
            require(numer > 0, "LMSR: domain");
            y = (numer * int256(WAD)) / denom;
        }

        require(y > 0 && y <= int256(WAD), "LMSR: y out of range");

        int256 lnY = sd(y).ln().unwrap();
        int256 tSigned = (-m.b * lnY) / int256(WAD); // -b ln(y)
        require(tSigned >= 0, "LMSR: no tokens");

        tOut = uint256(tSigned);
    }
}
