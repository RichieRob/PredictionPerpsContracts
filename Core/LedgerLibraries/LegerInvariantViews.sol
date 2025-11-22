// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./SolvencyLib.sol";
import "./MarketManagementLib.sol";

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

    /// @notice Effective minimum available shares for account in marketId.
    /// @dev effMin = realMinShares + syntheticCollateral (for DMM).
    function effectiveMinShares(address account, uint256 marketId)
        internal
        view
        returns (int256 effMin)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        int256 realMin = SolvencyLib.computeRealMinShares(s, account, marketId);
        effMin = SolvencyLib.computeEffectiveMinShares(s, account, marketId, realMin);
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

        address dmm = s.marketToDMM[marketId];
        int256 realMin = SolvencyLib.computeRealMinShares(s, dmm, marketId);
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

   

    /*//////////////////////////////////////////////////////////////
                 9. TVL vs aUSDC BALANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare totalValueLocked against aUSDC balance held by the ledger.
    /// @dev Invariant target: tvl == aUSDC.balanceOf(address(this)).
    function tvlAccounting()
        internal
        view
        returns (uint256 tvl, uint256 aUSDCBalance)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        tvl           = s.totalValueLocked; // or recompute as TotalMarketsValue + totalFreeCollateral
        aUSDCBalance  = s.aUSDC.balanceOf(address(this));
    }
}
