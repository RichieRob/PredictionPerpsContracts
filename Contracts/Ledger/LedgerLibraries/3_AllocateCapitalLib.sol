// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";

library AllocateCapitalLib {
    struct CapitalDeltas {
        int256 realFreeCollateralAccount; // Δ realFreeCollateral[account]
        int256 realTotalFreeCollateral;   // Δ realTotalFreeCollateral

        int256 usdcSpent;                 // Δ USDCSpent[account][marketId]
        int256 redeemedUSDC;              // Δ redeemedUSDC[account][marketId]

        int256 marketValue;               // Δ marketValue[marketId]
        int256 totalMarketsValue;         // Δ TotalMarketsValue
    }

    function _capitalDeltasView(
        uint256 amount,
        bool isAllocate
    ) internal pure returns (CapitalDeltas memory d) {
        int256 a = int256(amount);

        if (isAllocate) {
            d.realFreeCollateralAccount = -a;
            d.realTotalFreeCollateral   = -a;

            d.usdcSpent       =  a;

            d.marketValue       = a;
            d.totalMarketsValue = a;
        } else {
            d.realFreeCollateralAccount =  a;
            d.realTotalFreeCollateral   =  a;

            d.redeemedUSDC =  a;

            d.marketValue       = -a;
            d.totalMarketsValue = -a;
        }
    }

    // ─────────────────────────────────────────────
    // Split writers (with underflow guards)
    // ─────────────────────────────────────────────

    function _applyAccountDeltas(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        CapitalDeltas memory d
    ) internal {
        // realFreeCollateral[account]
        if (d.realFreeCollateralAccount != 0) {
            if (d.realFreeCollateralAccount > 0) {
                s.realFreeCollateral[account] += uint256(d.realFreeCollateralAccount);
            } else {
                uint256 abs = uint256(-d.realFreeCollateralAccount);
                uint256 cur = s.realFreeCollateral[account];
                s.realFreeCollateral[account] = cur - abs;
            }
        }

        // USDCSpent[account][marketId]
        if (d.usdcSpent != 0) {
            if (d.usdcSpent > 0) {
                s.USDCSpent[account][marketId] += uint256(d.usdcSpent);
            } else {
                uint256 abs = uint256(-d.usdcSpent);
                uint256 cur = s.USDCSpent[account][marketId];
                s.USDCSpent[account][marketId] = cur - abs;
            }
        }

        // redeemedUSDC[account][marketId]
        if (d.redeemedUSDC != 0) {
            if (d.redeemedUSDC > 0) {
                s.redeemedUSDC[account][marketId] += uint256(d.redeemedUSDC);
            } else {
                uint256 abs = uint256(-d.redeemedUSDC);
                uint256 cur = s.redeemedUSDC[account][marketId];
                s.redeemedUSDC[account][marketId] = cur - abs;
            }
        }
    }

    function _applyGlobalDeltas(
        StorageLib.Storage storage s,
        uint256 marketId,
        CapitalDeltas memory d
    ) internal {
        // realTotalFreeCollateral
        if (d.realTotalFreeCollateral != 0) {
            if (d.realTotalFreeCollateral > 0) {
                s.realTotalFreeCollateral += uint256(d.realTotalFreeCollateral);
            } else {
                uint256 abs = uint256(-d.realTotalFreeCollateral);
                uint256 cur = s.realTotalFreeCollateral;
                s.realTotalFreeCollateral = cur - abs;
            }
        }

        // marketValue[marketId]
        if (d.marketValue != 0) {
            if (d.marketValue > 0) {
                s.marketValue[marketId] += uint256(d.marketValue);
            } else {
                uint256 abs = uint256(-d.marketValue);
                uint256 cur = s.marketValue[marketId];
                s.marketValue[marketId] = cur - abs;
            }
        }

        // TotalMarketsValue
        if (d.totalMarketsValue != 0) {
            if (d.totalMarketsValue > 0) {
                s.TotalMarketsValue += uint256(d.totalMarketsValue);
            } else {
                uint256 abs = uint256(-d.totalMarketsValue);
                uint256 cur = s.TotalMarketsValue;
                s.TotalMarketsValue = cur - abs;
            }
        }
    }

    /// Backwards-compatible helper: apply both account + global parts.
    function _applyCapitalDeltas(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        CapitalDeltas memory d
    ) internal {
        _applyAccountDeltas(s, account, marketId, d);
        _applyGlobalDeltas(s, marketId, d);
    }
}
