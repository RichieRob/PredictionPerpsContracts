# SolvencyLib.sol – Refactored Version

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./HeapLib.sol";
import "./AllocateCapitalLib.sol";
import "./MarketManagementLib.sol";

library SolvencyLib {

    function _netUSDCAllocationSigned(
    StorageLib.Storage storage s,
    address account,
    uint256 marketId
) internal view returns (int256) {
    uint256 spent    = s.USDCSpent[account][marketId];
    uint256 redeemed = s.redeemedUSDC[account][marketId];

    return int256(spent) - int256(redeemed);
}

  function computeRealMinShares(
    StorageLib.Storage storage s,
    address account,
    uint256 marketId
) internal view returns (int256) {
    (int256 minTilt, ) = HeapLib.getMinTilt(account, marketId);
    int256 netAlloc    = _netUSDCAllocationSigned(s, account, marketId);
    return netAlloc + s.layOffset[account][marketId] + int256(minTilt);
}


    function computeEffectiveMinShares(StorageLib.Storage storage s, address account, uint256 marketId, int256 realMinShares) internal view returns (int256) {
        uint256 isc = MarketManagementLib.isDMM(account, marketId) ? s.syntheticCollateral[marketId] : 0;
        return realMinShares + int256(isc);
    }

    function computeRedeemable(StorageLib.Storage storage s, address account, uint256 marketId) internal view returns (int256) {
        (int256 maxTilt, ) = HeapLib.getMaxTilt(account, marketId);
        return -s.layOffset[account][marketId] - int256(maxTilt);
    }

function ensureSolvency(address account, uint256 marketId) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();

    int256 realMin = computeRealMinShares(s, account, marketId);
    int256 effMin  = computeEffectiveMinShares(s, account, marketId, realMin);

    if (effMin < 0) {
        uint256 shortfall = uint256(-effMin);
        AllocateCapitalLib.allocate(account, marketId, shortfall);
    }

    int256 redeemable = computeRedeemable(s, account, marketId);
    if (redeemable > 0) {
        int256 netAlloc = _netUSDCAllocationSigned(s, account, marketId);
        if (netAlloc < redeemable) {
            uint256 diff = uint256(redeemable - netAlloc);
            AllocateCapitalLib.allocate(account, marketId, diff);
        }
    }
}


function deallocateExcess(address account, uint256 marketId) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();

    int256 realMin = computeRealMinShares(s, account, marketId);
    int256 effMin  = computeEffectiveMinShares(s, account, marketId, realMin);
    if (effMin <= 0) return;

    int256 netAlloc = _netUSDCAllocationSigned(s, account, marketId);
    if (netAlloc <= 0) return; // 🔒 nothing to deallocate by design

    uint256 amount = uint256(effMin);

    int256 redeemable = computeRedeemable(s, account, marketId);
    if (redeemable > 0) {
        int256 margin = netAlloc - redeemable;
        if (margin > 0) {
            amount = _min(amount, uint256(margin));
        } else {
            // margin <= 0 ⇒ no further deallocation headroom
            amount = 0;
        }
    }

    // For the DMM only:
// If realMin < 0, it means the DMM is leaning on its ISC line to stay solvent.
// In this state, we allow deallocation only up to the amount of *real* capital
// the DMM actually has in the market (netAlloc).  
//
// Reason:
//   - realMin < 0 ⇒ the DMM would be insolvent without ISC.
//   - We must not deallocate so much that realMin becomes even more negative,
//     because effectiveMin stays ≥ 0 only due to ISC.
//   - netAlloc is the DMM’s remaining real stake; that is the maximum amount
//     of capital that can safely be pulled out without violating solvency.
//
// Therefore:
//   * If netAlloc > 0: cap deallocation at netAlloc.
//   * If netAlloc ≤ 0: the DMM has no withdrawable real capital → amount = 0.


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
