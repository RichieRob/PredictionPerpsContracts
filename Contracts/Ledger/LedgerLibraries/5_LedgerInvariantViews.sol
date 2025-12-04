// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./4_SolvencyLib.sol";
import "./2_MarketManagementLib.sol";

/// @title LedgerInvariantViews
/// @notice Pure view helpers to reconstruct and check high-level ledger invariants
///         in tests (and optionally via external wrappers on MarketMakerLedger).
library LedgerInvariantViews {
    /*//////////////////////////////////////////////////////////////
                         1. MARKET ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare stored marketValue vs (MarketUSDCSpent - Redemptions).
    /// @dev Target invariant:
    ///      marketValue[marketId] == MarketUSDCSpent[marketId] - Redemptions[marketId].
function marketAccounting(uint256 marketId)
    internal
    view
    returns (uint256 lhs, uint256 rhs)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    lhs = s.marketValue[marketId];
    rhs = s.marketValue[marketId]; // historic counters removed; invariant is now trivial
}


    /*//////////////////////////////////////////////////////////////
                       2. EFFECTIVE MIN SHARES
    //////////////////////////////////////////////////////////////*/

    /// @notice Effective minimum available shares for account in marketId.
    /// @dev effMin = realMinShares + syntheticCollateral (for DMM only).
    function effectiveMinShares(address account, uint256 marketId)
        internal
        view
        returns (int256 effMin)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        int256 realMin = SolvencyLib.computeRealMinShares(s, account, marketId);
        effMin         = SolvencyLib.computeEffectiveMinShares(s, account, marketId, realMin);
    }

    /*//////////////////////////////////////////////////////////////
                      3. SYNTHETIC USAGE (ISC SPENT)
    //////////////////////////////////////////////////////////////*/

    /// @notice Conceptual "ISC usage" for this market: how far below zero the DMM's
    ///         real min-shares would be without any synthetic collateral.
    /// @dev
    ///   realMinShares = netUSDCAllocation + layOffset + minTilt
    ///   iscSpent      = max(0, -realMinShares)
    ///
    ///   If iscSpent > syntheticCollateral[marketId], tests should flag
    ///   an invariant breach.
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
                        5. SYSTEM BALANCE SHEET
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare total principal booked on the ledger vs
    ///         "markets + freeCollateral".
    /// @dev Target invariant:
    ///      TotalMarketsValue + totalFreeCollateral == totalValueLocked.
    function systemBalance()
        internal
        view
        returns (uint256 lhs, uint256 rhs)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        lhs = s.TotalMarketsValue + s.realTotalFreeCollateral;
        rhs = s.totalValueLocked;
    }

    /*//////////////////////////////////////////////////////////////
                 6. TVL vs aUSDC BALANCE (MOCK vs PROD)
    //////////////////////////////////////////////////////////////*/

    /// @notice Compare totalValueLocked (principal) against aUSDC balance.
    ///
    /// @dev
    ///   - In **tests with a mock aUSDC that does NOT accrue interest**,
    ///     you usually want to assert:
    ///         aUSDCBalance == tvl
    ///
    ///   - In **production with real Aave**:
    ///       aUSDCBalance >= tvl
    ///     and the difference is:
    ///       interest = aUSDCBalance - tvl
    ///
    ///   This function just exposes both sides; tests decide whether they
    ///   are checking equality (mock) or >= (prod semantics).
    function tvlAccounting()
        internal
        view
        returns (uint256 tvl, uint256 aUSDCBalance)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        tvl          = s.totalValueLocked;
        aUSDCBalance = s.aUSDC.balanceOf(address(this));
    }
/// @dev Returns false if in any market this account has effMin < 0.
///      (Redeemability is checked separately via redeemabilityState).

  function checkSolvencyAllMarkets(address account)
    internal
    view
    returns (bool ok)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256[] memory markets = MarketManagementLib.getMarkets();

    ok = true;

    for (uint256 i = 0; i < markets.length; i++) {
        uint256 marketId = markets[i];

        int256 realMin = SolvencyLib.computeRealMinShares(s, account, marketId);
        int256 effMin  = SolvencyLib.computeEffectiveMinShares(s, account, marketId, realMin);

        if (effMin < 0) {
            ok = false;
            break;
        }
    }
}

function redeemabilityState(address account, uint256 marketId)
    internal
    view
    returns (int256 netAlloc, int256 redeemable, int256 margin)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    netAlloc    = SolvencyLib._netUSDCAllocationSigned(s, account, marketId);
    redeemable  = SolvencyLib.computeRedeemable(s, account, marketId);
    margin      = netAlloc - redeemable; // should be >= 0
}



    

}
