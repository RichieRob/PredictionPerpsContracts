// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./3_HeapLib.sol";

library TiltRouterLib {
    function updateTilt(
        address account,
        uint256 marketId,
        uint256 positionId,
        int256  delta
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.tilt[account][marketId][positionId] += delta;

        if (!s.isSmallMarket[marketId]) {
            HeapLib.updateTilt(account, marketId, positionId, 0); 
            // Slight tweak: change HeapLib.updateTilt to read tilt[...]+delta inside
            // or pass newTilt explicitly. Point is: call heap only for big markets.
        }
    }

    function getMinTilt(address account, uint256 marketId)
        internal
        view
        returns (int256 minTilt, uint256 minPositionId)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        if (!s.isSmallMarket[marketId]) {
            return HeapLib.getMinTilt(account, marketId);
        }

        // small market: scan all positions
        uint256[] storage positions = s.marketPositions[marketId];
        if (positions.length == 0) return (0, 0);

        int256 best = type(int256).max;
        uint256 bestId = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            int256 v = s.tilt[account][marketId][posId];
            if (v < best) {
                best = v;
                bestId = posId;
            }
        }

        if (s.isExpanding[marketId] && best > 0) {
            return (0, 0);
        }

        return (best, bestId);
    }

    function getMaxTilt(address account, uint256 marketId)
        internal
        view
        returns (int256 maxTilt, uint256 maxPositionId)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        if (!s.isSmallMarket[marketId]) {
            return HeapLib.getMaxTilt(account, marketId);
        }

        uint256[] storage positions = s.marketPositions[marketId];
        if (positions.length == 0) return (0, 0);

        int256 best = type(int256).min;
        uint256 bestId = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            uint256 posId = positions[i];
            int256 v = s.tilt[account][marketId][posId];
            if (v > best) {
                best = v;
                bestId = posId;
            }
        }

        if (s.isExpanding[marketId] && best < 0) {
            return (0, 0);
        }

        return (best, bestId);
    }
}
