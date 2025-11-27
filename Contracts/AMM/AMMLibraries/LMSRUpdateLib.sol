// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LMSRStorageLib.sol";
import "./LMSRMathLib.sol";

/// @title LMSRUpdateLib
/// @notice O(1) state update for LMSR markets.
/// @dev This is where the multiplicative χ factors are actually applied:
///
///      χ_G     = e^{ΔU_rest / b}
///      χ_R_k   = e^{(ΔU_k - ΔU_rest) / b}
///
///      G'      = G  · χ_G
///      R_k'    = R_k · χ_R_k
///      S'      = S - R_k + R_k'
///
/// Mapping from action → (ΔU_rest, ΔU_k):
///   BACK buy:  (0, +t)
///   BACK sell: (0, -t)
///   LAY  buy:  (+t, 0)
///   LAY  sell: (-t, 0)
library LMSRUpdateLib {
    using LMSRMathLib for int256;

    /// @notice Internal O(1) state update for trades.
    /// @param s         Root LMSR state.
    /// @param marketId  Market identifier.
    /// @param slot      0-based outcome slot index.
    /// @param isBack    True for BACK(i), false for true LAY(not-i).
    /// @param isBuy     True for buy, false for sell.
    /// @param t         Trade size in 1e6 “tokens” (USDC units).
    function applyUpdateInternal(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 slot,
        bool    isBack,
        bool    isBuy,
        uint256 t
    ) internal {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");
        require(slot < m.numOutcomes, "LMSR: bad slot");

        int256 RiOld = m.R[slot];

        // -------------------------
        // 1. Compute ΔU components
        // -------------------------
        int256 dU_rest = 0;
        int256 dU_k    = 0;
        int256 dt      = isBuy ? int256(uint256(t)) : -int256(uint256(t));

        if (isBack) {
            // BACK modifies local slot k
            dU_k = dt;
        } else {
            // LAY modifies “rest of market”
            dU_rest = dt;
        }

        // -----------------------------------------------------
        // 2. Compute χ factors via exp(ΔU / b)
        // -----------------------------------------------------
        //
        // χ_G   = e^{ΔU_rest / b}
        // χ_R_k = e^{(ΔU_k - ΔU_rest) / b}
        //
        int256 chi_G   = LMSRMathLib.expRatioOverB(m.b, dU_rest);
        int256 chi_R_k = LMSRMathLib.expRatioOverB(m.b, dU_k - dU_rest);

        // -----------------------------
        // 3. Apply χ updates to state
        // -----------------------------

        // G' = G · χ_G
        m.G = m.G.wmul(chi_G);

        // R_k' = R_k · χ_R_k
        int256 RiNew = RiOld.wmul(chi_R_k);
        m.R[slot] = RiNew;

        // S' = S - R_k + R_k'
        m.S = m.S - RiOld + RiNew;

        // Safety: S must remain positive for valid pricing
        require(m.S > 0, "LMSR: S<=0");

        // Reserve mass is untouched; its price moves via the S denominator.
        // If you want extra paranoia, you can assert non-negative reserve:
        if (m.isExpanding) {
            require(m.R_reserve >= 0, "LMSR: reserve<0");
        }
    }
}
