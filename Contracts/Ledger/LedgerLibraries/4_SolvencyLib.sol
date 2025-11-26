// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./3_HeapLib.sol";
import "./3_AllocateCapitalLib.sol";
import "./2_MarketManagementLib.sol";

/// @title SolvencyLib
/// @notice All the "mathy" rules that keep an account solvent in a market.
/// @dev There are really two constraints:
///
///  1. WORST-CASE LIABILITY (solvency):
///       - "How many full sets could the account be forced to pay in
///          the worst outcome of this market?"
///       - This is `realMinShares` (ignoring ISC) and `effMinShares`
///         (including the DMM's synthetic line).
///       - We enforce: `effectiveMinShares >= 0`.
///
///  2. BEST-CASE CLAIM (redeemability):
///       - "How many full sets could the account *redeem* if it pushes
///          its most favourable position to the limit?"
///       - This is `redeemable`.
///       - We enforce: `netUSDCAllocation >= redeemable`.
///
///       For the DMM this is essential:
///         → the DMM must **never** end up in a state where it has issued
///            more *redeemable* full sets to others than the real USDC it has
///            actually allocated into the market.  
///
///  The two public entrypoints are:
///       - ensureSolvency()    → may ALLOCATE capital into the market
///       - deallocateExcess()  → may DEALLOCATE capital back to freeCollateral
///
///  Both are written so that if they run after any operation, the account
///  ends up satisfying both constraints.
library SolvencyLib {

    /// @notice Signed "real capital" the account has in this market.
    /// @dev
    ///   spent    = total USDC ever allocated into this market  
    ///   redeemed = total USDC ever deallocated / redeemed out  
    ///
    ///   netAlloc = spent - redeemed  
    ///
    /// For normal flows this will be >= 0. It is signed mainly to make
    /// algebra convenient.
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
    /// @dev
    ///   realMinShares = netAlloc + layOffset + minTilt
    ///
    ///   - netAlloc    = spent - redeemed   (real USDC tied to this market)
    ///   - layOffset   = net Lay exposure (more Lay received than sent)
    ///   - minTilt     = worst (minimum) position tilt over all outcomes
    ///
    /// This is the “pure real” liability, before we grant the DMM any ISC.
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
    /// @dev
    ///  For normal accounts:
    ///      effMin = realMinShares.
    ///
    ///  For the DMM in this market:
    ///      effMin = realMinShares + syntheticCollateral[marketId].
    ///
    ///  The key solvency condition is: effMin >= 0.
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

    /// @notice Best-case number of full sets the account can redeem from this market.
    /// @dev
    ///   - maxTilt = the *maximum* tilt across positions (most favourable leg)
    ///   - layOffset = net Lay flow
    ///
    ///   We derive:
    ///       redeemable = -layOffset - maxTilt
    ///
    ///   For the DMM this value represents:
    ///       → the number of full sets the world could *claim* from the DMM
    ///         in the best-case outcome for everyone else.
    ///
    ///   And enforce:
    ///       netUSDCAllocation >= redeemable
    ///
    ///   Preventing the DMM from ever issuing more redeemable full sets
    ///   than it has real USDC backing the market.
    function computeRedeemable(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) internal view returns (int256) {
        (int256 maxTilt, ) = HeapLib.getMaxTilt(account, marketId);
        return -s.layOffset[account][marketId] - int256(maxTilt);
    }

    /// @notice Main guard: ensure an account is solvent and redeemable for a market.
    /// @dev This can only move real capital *into* the market (allocate).
    ///
    /// After running:
    ///      effMin >= 0  
    ///      netAlloc >= redeemable  
    function ensureSolvency(address account, uint256 marketId) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        int256 realMin = computeRealMinShares(s, account, marketId);
        int256 effMin  = computeEffectiveMinShares(s, account, marketId, realMin);

        // ---------------------------------------------------------
        // 1) SOLVENCY: effMin >= 0
        // ---------------------------------------------------------
        if (effMin < 0) {
            uint256 shortfall = uint256(-effMin);
            AllocateCapitalLib.allocate(account, marketId, shortfall);
        }

        // ---------------------------------------------------------
        // 2) REDEEMABILITY: netAlloc >= redeemable
        // ---------------------------------------------------------
        //
        // "redeemable" = best-case number of full sets that could be
        // claimed *against* this account.
        //
        // For the DMM this condition ensures:
        //   → the DMM never issues more redeemable full sets than it has
        //     real USDC actually backing the market (netAlloc).
        int256 redeemable = computeRedeemable(s, account, marketId);
        if (redeemable > 0) {
            int256 netAlloc = _netUSDCAllocationSigned(s, account, marketId);
            if (netAlloc < redeemable) {
                uint256 diff = uint256(redeemable - netAlloc);
                AllocateCapitalLib.allocate(account, marketId, diff);
            }
        }
    }

    /// @notice Try to pull real capital back out of this market into freeCollateral.
    /// @dev Only safe if BOTH:
    ///         effMin >= 0
    ///         netAlloc >= redeemable
    ///
    /// And for the DMM:
    ///         must also not end up "floating" purely on ISC.
    function deallocateExcess(address account, uint256 marketId) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        int256 realMin = computeRealMinShares(s, account, marketId);
        int256 effMin  = computeEffectiveMinShares(s, account, marketId, realMin);

        if (effMin <= 0) return;

        int256 netAlloc = _netUSDCAllocationSigned(s, account, marketId);
        if (netAlloc <= 0) return; // No real capital to pull out

        uint256 amount = uint256(effMin);

        // Redeemability constraint: netAlloc >= redeemable
        int256 redeemable = computeRedeemable(s, account, marketId);
        if (redeemable > 0) {
            int256 margin = netAlloc - redeemable;
            if (margin > 0) {
                amount = _min(amount, uint256(margin));
            } else {
                amount = 0;
            }
        }

        // DMM constraint: if the DMM is leaning on ISC (realMin < 0),
        // they must not deallocate more than their remaining real stake.
        if (MarketManagementLib.isDMM(account, marketId) && realMin < 0) {
            if (netAlloc > 0) {
                amount = _min(amount, uint256(netAlloc));
            } else {
                amount = 0;
            }
        }

        if (amount > 0) {
            AllocateCapitalLib.deallocate(account, marketId, amount);
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
