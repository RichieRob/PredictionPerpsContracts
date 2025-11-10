
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";
import "./LMSRMathLib.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRUpdateLib
/// @notice Library for state update functions in LMSRMarketMaker.
library LMSRUpdateLib {
    using LMSRMathLib for int256;

    /// @notice Internal O(1) state update for trades.
    // Mapping from action -> (ΔU_rest, ΔU_k):
    // BACK buy:  (0, +t)
    // BACK sell: (0, -t)
    // LAY  buy:  (+t, 0)   // true LAY(not-k)
    // LAY  sell: (-t, 0)
    function applyUpdateInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 slot,
        bool isBack,
        bool isBuy,
        uint256 t
    ) internal {
        int256 Ri_old = self.R[marketId][slot];

        // ΔU in 1e6
        int256 dU_rest = 0;
        int256 dU_k    = 0;
        int256 dt      = isBuy ? int256(uint256(t)) : -int256(uint256(t));
        if (isBack) dU_k = dt;
        else        dU_rest = dt;

        // e^{ΔU/b}
        int256 e_rest  = LMSRMathLib.expRatioOverB(self.b[marketId], dU_rest);
        int256 e_local = LMSRMathLib.expRatioOverB(self.b[marketId], dU_k - dU_rest);

        // Update G and R_k, then S_tradables
        self.G[marketId] = self.G[marketId].wmul(e_rest);

        int256 Ri_new = Ri_old.wmul(e_local);
        self.R[marketId][slot] = Ri_new;

        self.S_tradables[marketId] = self.S_tradables[marketId] - Ri_old + Ri_new;

        if (!self.isExpanding[marketId]) {
            // Safety: Prevent underflow (S should always be >0)
            require(self.S_tradables[marketId] > 0, "S underflow");
        }
        // NOTE: R_reserve is untouched; its price moves via the denominator.
    }
}