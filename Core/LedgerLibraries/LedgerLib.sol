
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./HeapLib.sol";
import "./MarketManagementLib.sol";

library LedgerLib {
    function getPositionLiquidity(uint256 mmId, uint256 marketId, uint256 positionId)
        internal
        view
        returns (
            uint256 freeCollateral,
            int256 virtualOffset,
            int128 tilt
        )
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 isc = MarketManagementLib.isDMM(mmId, marketId) ? s.syntheticCollateral[marketId] : 0;
        freeCollateral = s.freeCollateral[mmId] + isc;
        
        // virtualOffset = USDCSpent + layOffset
        virtualOffset = s.USDCSpent[mmId][marketId] + s.layOffset[mmId][marketId];
        
        tilt = s.tilt[mmId][marketId][positionId];
    }

    function getAvailableShares(uint256 mmId, uint256 marketId, uint256 positionId)
        internal view
        returns (int256)
    {
        (uint256 freeCollateral, int256 virtualOffset, int128 tilt) = getPositionLiquidity(mmId, marketId, positionId);
        return int256(freeCollateral) + virtualOffset + int256(tilt);
    }

    function getMinTilt(uint256 mmId, uint256 marketId) internal view returns (int128 minTilt, uint256 minPositionId) {
        return HeapLib.getMinTilt(mmId, marketId);
    }

    function getMaxTilt(uint256 mmId, uint256 marketId) internal view returns (int128 maxTilt, uint256 maxPositionId) {
        return HeapLib.getMaxTilt(mmId, marketId);
    }
}
