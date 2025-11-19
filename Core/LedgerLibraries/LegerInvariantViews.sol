// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./SolvencyLib.sol";
import "./MarketManagementLib.sol";
import "../../Interfaces/IPositionToken1155.sol";

/// @title LedgerInvariantViews
/// @notice Pure view helpers to reconstruct and check high-level ledger invariants
///         in tests (and optionally via external wrappers on MarketMakerLedger).
library LedgerInvariantViews {
    /*//////////////////////////////////////////////////////////////
                         1. MARKET ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare stored marketValue vs (MarketUSDCSpent - Redemptions).
    /// @dev Invariant target: marketValue == MarketUSDCSpent - Redemptions.
    function marketAccounting(uint256 marketId)
        internal
        view
        returns (uint256 lhs, uint256 rhs)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        lhs = s.marketValue[marketId];
        rhs = s.MarketUSDCSpent[marketId] - s.Redemptions[marketId];
    }

    /*//////////////////////////////////////////////////////////////
                       2. EFFECTIVE MIN SHARES
    //////////////////////////////////////////////////////////////*/

    /// @notice Effective minimum available shares for mmId in marketId.
    /// @dev effMin = realMinShares + syntheticCollateral (for DMM).
    function effectiveMinShares(uint256 mmId, uint256 marketId)
        internal
        view
        returns (int256 effMin)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        int256 realMin = SolvencyLib.computeRealMinShares(s, mmId, marketId);
        effMin = SolvencyLib.computeEffectiveMinShares(s, mmId, marketId, realMin);
    }

    /*//////////////////////////////////////////////////////////////
                      3. SYNTHETIC USAGE (ISC SPENT)
    //////////////////////////////////////////////////////////////*/

    /// @notice Conceptual "ISC needed" for this market: how far below zero the DMM's
    ///         real min-shares would be without any synthetic collateral.
    /// @dev
    ///   realMinShares = netUSDCAllocation + layOffset + minTilt
    ///   iscSpent      = max(0, -realMinShares)
    ///
    ///   This is intentionally *not* clamped by syntheticCollateral[marketId]:
    ///   if iscSpent > syntheticCollateral, that indicates an invariant breach,
    ///   which tests / off-chain checks should surface.
    function iscSpent(uint256 marketId) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        uint256 dmmId = s.marketToDMM[marketId];
        int256 realMin = SolvencyLib.computeRealMinShares(s, dmmId, marketId);
        if (realMin >= 0) return 0;
        return uint256(-realMin);
    }

    /*//////////////////////////////////////////////////////////////
                        4. SYSTEM FULL SETS (E)
    //////////////////////////////////////////////////////////////*/

    /// @notice System-wide full sets E = marketValue + iscSpent.
    function totalFullSets(uint256 marketId) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 mv  = s.marketValue[marketId];
        uint256 isc = iscSpent(marketId);
        return mv + isc;
    }

    /*//////////////////////////////////////////////////////////////
                         5. TOKEN-SIDE HELPERS
    //////////////////////////////////////////////////////////////*/

    function backSupply(uint256 marketId, uint256 positionId) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 backTokenId = StorageLib.encodeTokenId(
            uint64(marketId),
            uint64(positionId),
            true // isBack
        );
        return IPositionToken1155(s.positionToken1155).totalSupply(backTokenId);
    }

    function laySupply(uint256 marketId, uint256 positionId) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 layTokenId = StorageLib.encodeTokenId(
            uint64(marketId),
            uint64(positionId),
            false // isBack
        );
        return IPositionToken1155(s.positionToken1155).totalSupply(layTokenId);
    }

    /// @notice User exposure to outcome i:
    ///         UserExposure_i = B_i + sum_{j != i} L_j
    function userExposure(uint256 marketId, uint256 positionId) internal view returns (int256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage positions = s.marketPositions[marketId];

        // Back(i)
        uint256 B = backSupply(marketId, positionId);

        // Sum of Lay(j) for j != i
        uint256 L_not_i = 0;
        for (uint256 k = 0; k < positions.length; k++) {
            uint256 pid = positions[k];
            if (pid == positionId) continue;
            L_not_i += laySupply(marketId, pid);
        }

        return int256(B + L_not_i);
    }

    /// @notice Users' redeemable full sets: min_i B_i.
    function fullSetsUser(uint256 marketId) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage positions = s.marketPositions[marketId];

        if (positions.length == 0) {
            return 0;
        }

        uint256 minB = type(uint256).max;
        for (uint256 i = 0; i < positions.length; i++) {
            uint256 B = backSupply(marketId, positions[i]);
            if (B < minB) {
                minB = B;
            }
        }
        if (minB == type(uint256).max) return 0;
        return minB;
    }

    /*//////////////////////////////////////////////////////////////
                       6. USER FUNDING INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks fullSetsUser <= totalFullSets (E).
    function checkUserFundingInvariant(uint256 marketId)
        internal
        view
        returns (bool ok, uint256 fullUser, uint256 fullSystem)
    {
        fullUser   = fullSetsUser(marketId);
        fullSystem = totalFullSets(marketId);
        ok = (fullUser <= fullSystem);
    }

    /*//////////////////////////////////////////////////////////////
                   7. PER-POSITION EXPOSURE E_i (SYSTEM)
    //////////////////////////////////////////////////////////////*/

    /// @notice Total system exposure for outcome i (positionId):
    ///         E_i = UserExposure_i + mmExposure_i
    /// where
    ///         mmExposure_i = netUSDCAllocation + iscSpent + layOffset + tilt[i].
    function exposureForPosition(uint256 marketId, uint256 positionId)
        internal
        view
        returns (int256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        uint256 dmmId = s.marketToDMM[marketId];

        // User side
        int256 userExp = userExposure(marketId, positionId);

        // MM side baseline: netUSDCAllocation + layOffset
        int256 netAlloc = SolvencyLib._netUSDCAllocationSigned(s, dmmId, marketId);
        int256 base     = netAlloc + s.layOffset[dmmId][marketId];

        // Synthetic usage and local tilt
        uint256 isc  = iscSpent(marketId);
        int128  tilt = s.tilt[dmmId][marketId][positionId];

        // E_i = userExposure_i + (netUSDCAllocation + iscSpent + layOffset + tilt[i])
        return userExp + base + int256(uint256(isc)) + int256(tilt);
    }

    /*//////////////////////////////////////////////////////////////
                 8. BALANCED EXPOSURE ACROSS OUTCOMES
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks that E_i == E_j for all positions in a market.
    /// @return ok         True if all E_i equal.
    /// @return reference  The E value for the first position.
    /// @return positions  The list of positionIds used in the check.
    function checkBalancedExposure(uint256 marketId)
        internal
        view
        returns (bool ok, int256 reference, uint256[] memory positions)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        positions = s.marketPositions[marketId];
        if (positions.length == 0) {
            return (true, 0, positions); // vacuously true
        }

        reference = exposureForPosition(marketId, positions[0]);
        for (uint256 i = 1; i < positions.length; i++) {
            int256 Ei = exposureForPosition(marketId, positions[i]);
            if (Ei != reference) {
                return (false, reference, positions);
            }
        }
        return (true, reference, positions);
    }
}
