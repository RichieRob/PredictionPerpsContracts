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
///  2. BEST-CASE CLAIM (redeemability) –
///       netAlloc >= redeemable
///     BUT in your design this is only enforced for:
///       - the DMM account
///       - on NON-resolving markets.
library SolvencyLib {
    struct State {
        int256 realMin;     // realMinShares
        int256 effMin;      // effectiveMinShares (with ISC for DMM)
        int256 netAlloc;    // spent - redeemed
        int256 redeemable;  // best-case claimable full sets (DMM + non-res only)
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
    /// NOTE: in practice we only *use* this for the DMM on NON-resolving markets.
    function computeRedeemable(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) internal view returns (int256) {
        (int256 maxTilt, ) = HeapLib.getMaxTilt(account, marketId);
        return -s.layOffset[account][marketId] - int256(maxTilt);
    }

    // -----------------------------------------------------------------------
    // State loading
    // -----------------------------------------------------------------------

    /// @dev Load all solvency state in one go so we don't re-hit heaps / mappings.
    ///      Redeemability is only computed for the DMM on NON-resolving markets.
    function _loadState(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) private view returns (State memory st) {
        st.isDMM = MarketManagementLib.isDMM(account, marketId);
        bool isResolvingMarket = s.doesResolve[marketId];

        // realMin and netAlloc
        (int256 minTilt, ) = HeapLib.getMinTilt(account, marketId);
        int256 layOffset   = s.layOffset[account][marketId];
        st.netAlloc        = _netUSDCAllocationSigned(s, account, marketId);
        st.realMin         = st.netAlloc + layOffset + int256(minTilt);

        // effMin with ISC if DMM
        uint256 isc = st.isDMM ? s.syntheticCollateral[marketId] : 0;
        st.effMin   = st.realMin + int256(isc);

        // redeemable (best-case full sets) – only for DMM on NON-resolving markets
        if (st.isDMM && !isResolvingMarket) {
            (int256 maxTilt, ) = HeapLib.getMaxTilt(account, marketId);
            st.redeemable = -layOffset - int256(maxTilt);
        } else {
            st.redeemable = 0; // traders & resolving markets: no redeemability constraint
        }
    }

    // -----------------------------------------------------------------------
    // Core rebalance math (pure, shared by view + write paths)
    // -----------------------------------------------------------------------

    /// @dev Core rebalance logic over an in-memory State.
    /// @param allowAllocate   whether we're allowed to push capital into the market
    /// @param allowDeallocate whether we're allowed to pull capital back out
    /// @return alloc  amount that should be allocated into the market
    /// @return dealloc amount that should be deallocated from the market
    function _rebalanceCore(
        State memory st,
        bool allowAllocate,
        bool allowDeallocate
    ) private pure returns (uint256 alloc, uint256 dealloc) {
        alloc = 0;
        dealloc = 0;

        // ---------------------------------------------------------
        // 1) SOLVENCY: effMin >= 0
        // ---------------------------------------------------------
        if (allowAllocate && st.effMin < 0) {
            uint256 shortfall = uint256(-st.effMin);

            alloc       += shortfall;
            st.realMin  += int256(shortfall);
            st.effMin   += int256(shortfall);
            st.netAlloc += int256(shortfall);
        }

        // ---------------------------------------------------------
        // 2) REDEEMABILITY: netAlloc >= redeemable
        //    (only relevant if st.redeemable > 0, i.e. DMM + non-res)
        // ---------------------------------------------------------
        if (allowAllocate && st.redeemable > 0) {
            int256 netAllocAfter = st.netAlloc; // after any allocation above
            if (netAllocAfter < st.redeemable) {
                uint256 diff = uint256(st.redeemable - netAllocAfter);

                alloc       += diff;
                st.realMin  += int256(diff);
                st.effMin   += int256(diff);
                st.netAlloc += int256(diff);
            }
        }

        // ---------------------------------------------------------
        // 3) DEALLOCATE EXCESS (if allowed)
        // ---------------------------------------------------------
        if (!allowDeallocate) {
            return (alloc, dealloc);
        }

        if (st.effMin <= 0) {
            return (alloc, dealloc);
        }

        uint256 amount = uint256(st.effMin);

        // Redeemability constraint: netAlloc >= redeemable
        // Only does anything where st.redeemable > 0 (DMM + non-res)
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
            dealloc     += amount;
            st.realMin  -= int256(amount);
            st.effMin   -= int256(amount);
            st.netAlloc -= int256(amount);
        }
    }





    /// @notice Full rebalance as a dry-run: first allocate if needed, then deallocate any safe excess.
    /// @dev VIEW-ONLY: does not modify storage.
    /// @return allocDelta   >= 0 amount that would be allocated
    /// @return deallocDelta <= 0 negative amount representing what would be deallocated
    function rebalanceFullView(
        address account,
        uint256 marketId
    ) internal view returns (int256 allocDelta, int256 deallocDelta) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        State memory st = _loadState(s, account, marketId);

        (uint256 alloc, uint256 dealloc) = _rebalanceCore(st, true, true);

        allocDelta   = int256(alloc);          // >= 0
        deallocDelta = -int256(dealloc);       // <= 0
    }

    // -----------------------------------------------------------------------
    // Small helpers
    // -----------------------------------------------------------------------

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
