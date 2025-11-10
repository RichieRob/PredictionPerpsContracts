# SolvencyLib.sol – Refactored Version

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./HeapLib.sol";
import "./AllocateCapitalLib.sol";
import "./MarketManagementLib.sol";

library SolvencyLib {
    function computeRealMinShares(StorageLib.Storage storage s, uint256 mmId, uint256 marketId) internal view returns (int256) {
        (int128 minTilt, ) = HeapLib.getMinTilt(mmId, marketId);
        return s.USDCSpent[mmId][marketId] + s.layOffset[mmId][marketId] + int256(minTilt);
    }

    function computeEffectiveMinShares(StorageLib.Storage storage s, uint256 mmId, uint256 marketId, int256 realMinShares) internal view returns (int256) {
        uint256 isc = MarketManagementLib.isDMM(mmId, marketId) ? s.syntheticCollateral[marketId] : 0;
        return realMinShares + int256(isc);
    }

    function computeRedeemable(StorageLib.Storage storage s, uint256 mmId, uint256 marketId) internal view returns (int256) {
        (int128 maxTilt, ) = HeapLib.getMaxTilt(mmId, marketId);
        return -s.layOffset[mmId][marketId] - int256(maxTilt);
    }

    function ensureSolvency(uint256 mmId, uint256 marketId) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        int256 realMin = computeRealMinShares(s, mmId, marketId);
        int256 effMin = computeEffectiveMinShares(s, mmId, marketId, realMin);
        if (effMin < 0) {
            uint256 shortfall = uint256(-effMin);
            AllocateCapitalLib.allocate(mmId, marketId, shortfall);
        }
        int256 redeemable = computeRedeemable(s, mmId, marketId);
        if (redeemable > 0 && s.USDCSpent[mmId][marketId] < redeemable) {
            uint256 diff = uint256(redeemable - s.USDCSpent[mmId][marketId]);
            AllocateCapitalLib.allocate(mmId, marketId, diff);
        }
    }

    function deallocateExcess(uint256 mmId, uint256 marketId) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        int256 realMin = computeRealMinShares(s, mmId, marketId);
        int256 effMin = computeEffectiveMinShares(s, mmId, marketId, realMin);
        if (effMin > 0) {
            uint256 amount = uint256(effMin);
            int256 redeemable = computeRedeemable(s, mmId, marketId);
            if (redeemable > 0) {
                amount = _min(amount, uint256(s.USDCSpent[mmId][marketId] - redeemable));
            }
            if (MarketManagementLib.isDMM(mmId, marketId) && realMin < 0) {
                amount = _min(amount, uint256(s.USDCSpent[mmId][marketId]));
            }
            if (amount > 0) {
                AllocateCapitalLib.deallocate(mmId, marketId, amount);
            }
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
