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
    // NEW: split writers
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
                s.realFreeCollateral[account] -= uint256(-d.realFreeCollateralAccount);
            }
        }

        // USDCSpent[account][marketId]
        if (d.usdcSpent != 0) {
            if (d.usdcSpent > 0) {
                s.USDCSpent[account][marketId] += uint256(d.usdcSpent);
            } else {
                s.USDCSpent[account][marketId] -= uint256(-d.usdcSpent);
            }
        }

        // redeemedUSDC[account][marketId]
        if (d.redeemedUSDC != 0) {
            if (d.redeemedUSDC > 0) {
                s.redeemedUSDC[account][marketId] += uint256(d.redeemedUSDC);
            } else {
                s.redeemedUSDC[account][marketId] -= uint256(-d.redeemedUSDC);
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
                s.realTotalFreeCollateral -= uint256(-d.realTotalFreeCollateral);
            }
        }

  

        // marketValue[marketId]
        if (d.marketValue != 0) {
            if (d.marketValue > 0) {
                s.marketValue[marketId] += uint256(d.marketValue);
            } else {
                s.marketValue[marketId] -= uint256(-d.marketValue);
            }
        }

        // TotalMarketsValue
        if (d.totalMarketsValue != 0) {
            if (d.totalMarketsValue > 0) {
                s.TotalMarketsValue += uint256(d.totalMarketsValue);
            } else {
                s.TotalMarketsValue -= uint256(-d.totalMarketsValue);
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

    // ─────────────────────────────────────────────
    // Existing allocate/deallocate still work
    // ─────────────────────────────────────────────

    function allocate(
        address account,
        uint256 marketId,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        CapitalDeltas memory d = _capitalDeltasView(amount, true);

        // Original semantics preserved:
        _applyCapitalDeltas(s, account, marketId, d);
    }

    function deallocate(
        address account,
        uint256 marketId,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        CapitalDeltas memory d = _capitalDeltasView(amount, false);

        _applyCapitalDeltas(s, account, marketId, d);
    }
}
