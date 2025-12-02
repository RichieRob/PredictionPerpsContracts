// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./3_HeapLib.sol";
import "./3_AllocateCapitalLib.sol";
import "./2_MarketManagementLib.sol";

/// @title SolvencyLib
/// @notice All the "mathy" rules that keep an account solvent in a market.
/// @dev Two constraints:
///  1. WORST-CASE LIABILITY (solvency):
///       effMin >= 0
///  2. BEST-CASE CLAIM (redeemability):
///       netAlloc >= redeemable
library SolvencyLib {

    struct State {
        int256 realMin;     // realMinShares
        int256 effMin;      // effectiveMinShares (with ISC for DMM)
        int256 netAlloc;    // spent - redeemed
        int256 redeemable;  // best-case claimable full sets
        bool   isDMM;
    }

    // -----------------------------------------------------------------------
    // Core helpers
    // -----------------------------------------------------------------------

    /// @notice Signed "real capital" the account has in this market.
    ///         netAlloc = spent - redeemed.
    function _netUSDCAllocationSigned(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) internal view returns (int256) {
        uint256 spent    = s.USDCSpent[account][marketId];
        uint256 redeemed = s.redeemedUSDC[account][marketId];
        return int256(spent) - int256(redeemed);
    }

    /// @notice Worst-case number of full sets this account might have to pay
    ///         if the market goes against them, ignoring any synthetic line.
    /// realMinShares = netAlloc + layOffset + minTilt.
    function computeRealMinShares(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) internal view returns (int256) {
        (int256 minTilt, ) = HeapLib.getMinTilt(account, marketId);
        int256 netAlloc    = _netUSDCAllocationSigned(s, account, marketId);
        return netAlloc + s.layOffset[account][marketId] + int256(minTilt);
    }

    /// @notice Effective min shares after adding the synthetic line for the DMM.
    /// For normal accounts: effMin = realMinShares.
    /// For the DMM in this market: effMin = realMinShares + syntheticCollateral[marketId].
    function computeEffectiveMinShares(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        int256 realMinShares
    ) internal view returns (int256) {
        uint256 isc = MarketManagementLib.isDMM(account, marketId)
            ? s.syntheticCollateral[marketId]
            : 0;
        return realMinShares + int256(isc);
    }

    /// @notice Best-case number of full sets an account can redeem from this market.
    /// redeemable = -layOffset - maxTilt.
    function computeRedeemable(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) internal view returns (int256) {
        (int256 maxTilt, ) = HeapLib.getMaxTilt(account, marketId);
        return -s.layOffset[account][marketId] - int256(maxTilt);
    }

    // -----------------------------------------------------------------------
    // State loading + shared rebalance
    // -----------------------------------------------------------------------

    /// @dev Load all solvency state in one go so we don't re-hit heaps / mappings.
    function _loadState(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) private view returns (State memory st) {
        st.isDMM    = MarketManagementLib.isDMM(account, marketId);

        // realMin and netAlloc
        (int256 minTilt, ) = HeapLib.getMinTilt(account, marketId);
        st.netAlloc = _netUSDCAllocationSigned(s, account, marketId);
        st.realMin  = st.netAlloc + s.layOffset[account][marketId] + int256(minTilt);

        // effMin with ISC if DMM
        uint256 isc = st.isDMM ? s.syntheticCollateral[marketId] : 0;
        st.effMin   = st.realMin + int256(isc);

        // redeemable (best-case full sets)
        (int256 maxTilt, ) = HeapLib.getMaxTilt(account, marketId);
        st.redeemable = -s.layOffset[account][marketId] - int256(maxTilt);
    }

    /// @dev Internal shared rebalance. Depending on flags, it:
    ///  - can allocate into the market (fix effMin < 0 and/or netAlloc < redeemable)
    ///  - can deallocate excess capital (if effMin > 0, within redeemability & DMM constraints).
    function _rebalance(
        address account,
        uint256 marketId,
        bool allowAllocate,
        bool allowDeallocate
    ) private {
        StorageLib.Storage storage s = StorageLib.getStorage();
        State memory st = _loadState(s, account, marketId);

        // ---------------------------------------------------------
        // 1) SOLVENCY: effMin >= 0
        // ---------------------------------------------------------
        if (allowAllocate && st.effMin < 0) {
            uint256 shortfall = uint256(-st.effMin);
            AllocateCapitalLib.allocate(account, marketId, shortfall);

            // keep State in sync without re-reading:
            st.realMin  += int256(shortfall);
            st.effMin   += int256(shortfall);
            st.netAlloc += int256(shortfall);
        }

        // ---------------------------------------------------------
        // 2) REDEEMABILITY: netAlloc >= redeemable
        // ---------------------------------------------------------
        if (allowAllocate && st.redeemable > 0) {
            int256 netAlloc = st.netAlloc; // after any allocation above
            if (netAlloc < st.redeemable) {
                uint256 diff = uint256(st.redeemable - netAlloc);
                AllocateCapitalLib.allocate(account, marketId, diff);

                st.realMin  += int256(diff);
                st.effMin   += int256(diff);
                st.netAlloc += int256(diff);
            }
        }

        // ---------------------------------------------------------
        // 3) DEALLOCATE EXCESS (if allowed)
        // ---------------------------------------------------------
        if (!allowDeallocate) {
            return;
        }

        // Recompute effMin/netAlloc/redeemable from state (already updated).
        if (st.effMin <= 0) {
            return;
        }

        uint256 amount = uint256(st.effMin);

        // Redeemability constraint: netAlloc >= redeemable
        if (st.redeemable > 0) {
            int256 margin = st.netAlloc - st.redeemable;
            if (margin > 0) {
                amount = _min(amount, uint256(margin));
            } else {
                amount = 0;
            }
        }

        // DMM constraint: if the DMM is leaning on ISC (realMin < 0),
        // they must not deallocate more than their remaining real stake.
        if (st.isDMM && st.realMin < 0) {
            if (st.netAlloc > 0) {
                amount = _min(amount, uint256(st.netAlloc));
            } else {
                amount = 0;
            }
        }

        if (amount > 0) {
            AllocateCapitalLib.deallocate(account, marketId, amount);
        }
    }

    // -----------------------------------------------------------------------
    // Public-facing entrypoints (same API as before)
    // -----------------------------------------------------------------------

    /// @notice Main guard: ensure an account is solvent and redeemable for a market.
    /// @dev This can only move real capital *into* the market (allocate).
    ///
    /// After running:
    ///      effMin >= 0
    ///      netAlloc >= redeemable
    function ensureSolvency(address account, uint256 marketId) internal {
        _rebalance(account, marketId, true, false);
    }

    /// @notice Try to pull real capital back out of this market into freeCollateral.
    /// @dev Only safe if BOTH:
    ///         effMin >= 0
    ///         netAlloc >= redeemable
    ///      and, for the DMM, we don't end up purely on ISC.
    function deallocateExcess(address account, uint256 marketId) internal {
        _rebalance(account, marketId, false, true);
    }

    /// @notice Full rebalance: first allocate if needed, then deallocate any safe excess.
    /// @dev This is what you eventually want to call once per account instead of
    ///      `ensureSolvency` + `deallocateExcess` separately.
    function rebalanceFull(address account, uint256 marketId) internal {
        _rebalance(account, marketId, true, true);
    }

    // -----------------------------------------------------------------------
    // Small helpers
    // -----------------------------------------------------------------------

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
