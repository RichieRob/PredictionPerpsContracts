// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";
import "./LMSRMathLib.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRUpdateLib
/// @notice Library for state update functions in LMSRMarketMaker.
/// @dev This is where the multiplicative χ factors described in the
///      LMSR O(1) maths are actually applied:
///
///      χ_G     = e^{ΔU_rest / b}
///      χ_R_k   = e^{(ΔU_k - ΔU_rest) / b}
///
///      G'      = G  · χ_G
///      R_k'    = R_k · χ_R_k
///      S'      = S - R_k + R_k'
library LMSRUpdateLib {
    using LMSRMathLib for int256;

    /// @notice Internal O(1) state update for trades.
    ///
    /// Mapping from action → (ΔU_rest, ΔU_k):
    ///   BACK buy:  (0, +t)
    ///   BACK sell: (0, -t)
    ///   LAY  buy:  (+t, 0)
    ///   LAY  sell: (-t, 0)
    ///
    /// These ΔU components generate the χ factors.
    function applyUpdateInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 slot,
        bool isBack,
        bool isBuy,
        uint256 t
    ) internal {
        int256 Ri_old = self.R[marketId][slot];

        // -------------------------
        // 1. Compute ΔU components
        // -------------------------
        int256 dU_rest = 0;       // ΔU_rest
        int256 dU_k    = 0;       // ΔU_k
        int256 dt      = isBuy ? int256(uint256(t)) : -int256(uint256(t));

        if (isBack) dU_k = dt;    // BACK modifies local slot k
        else        dU_rest = dt; // LAY modifies "rest of market"

        // -----------------------------------------------------
        // 2. Compute χ factors (in code called e_rest, e_local)
        // -----------------------------------------------------
        //
        // χ_G    = e^{ΔU_rest / b}
        // χ_R_k  = e^{(ΔU_k - ΔU_rest) / b}
        //
        // These values are the multiplicative state changes.
        //
        int256 chi_G    = LMSRMathLib.expRatioOverB(self.b[marketId], dU_rest);
        int256 chi_R_k  = LMSRMathLib.expRatioOverB(self.b[marketId], dU_k - dU_rest);

        // -----------------------------
        // 3. Apply χ updates to state
        // -----------------------------

        // G' = G · χ_G
        self.G[marketId] = self.G[marketId].wmul(chi_G);

        // R_k' = R_k · χ_R_k
        int256 Ri_new = Ri_old.wmul(chi_R_k);
        self.R[marketId][slot] = Ri_new;

        // S' = S - R_k + R_k'

        self.S[marketId] = self.S[marketId] - Ri_old + Ri_new;
        require(self.S[marketId] > 0, "S <= 0");
        require(self.R_reserve[marketId] >= 0, "reserve < 0");


        if (!self.isExpanding[marketId]) {
            // Safety: S must remain > 0 for valid pricing
            require(self.S[marketId] > 0, "S underflow");
        }

        // NOTE: R_reserve is untouched; its price moves through the denominator.
    }
}
