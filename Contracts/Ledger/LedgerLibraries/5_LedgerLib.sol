// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./3_HeapLib.sol";
import "./2_MarketManagementLib.sol";
import "./4_SolvencyLib.sol";

// There are two distinct "share" notions:
//
// 1. Full capacity shares (getFullCapacityShares)
//    - realFreeCollateral  (convertible into new full sets)
//    - + ISC (if DMM)
//    - + marketExposure
//    - + tilt
//    → This represents the *maximum number of shares* the account could
//      possibly support/sell on this position if it allocated all resources.
//
// 2. Created shares (getCreatedShares)
//    - ISC (if DMM)
//    - + marketExposure
//    - + tilt
//    → This represents the number of shares that actually *exist* for
//      this account on this outcome.
//    → This is the number used for the ERC20 mirror (balanceOf/totalSupply).
//    → It is simply “full capacity shares minus the part backed by realFreeCollateral”.

library LedgerLib {
    function getPositionLiquidity(
        address account,
        uint256 marketId,
        uint256 positionId
    )
        internal
        view
        returns (
            uint256 realFreeCollateral,
            int256  marketExposure,
            int256  tilt,
            uint256 amountOfISCForThisAccountAndMarket
        )
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // adding the ISC to freeCollateral if the account is the DMM
        uint256 isc = MarketManagementLib.isDMM(account, marketId)
            ? s.syntheticCollateral[marketId]
            : 0;

        amountOfISCForThisAccountAndMarket = isc;

        realFreeCollateral = s.realFreeCollateral[account];

        int256 netAlloc =
            SolvencyLib._netUSDCAllocationSigned(s, account, marketId);

        marketExposure = netAlloc + s.layOffset[account][marketId];

        tilt = s.tilt[account][marketId][positionId];
    }

    function getFullCapacityShares(
        address account,
        uint256 marketId,
        uint256 positionId
    )
        internal
        view
        returns (int256)
    {
        (
            uint256 freeCollateral,
            int256  marketExposure,
            int256  tilt,
            uint256 isc
        ) = getPositionLiquidity(account, marketId, positionId);

        return int256(freeCollateral) + marketExposure + int256(tilt) + int256(isc);
    }

    function getCreatedShares(
        address account,
        uint256 marketId,
        uint256 positionId
    )
        internal
        view
        returns (int256)
    {
        // ISC balance included logically in the created side for the DMM.
        ( , int256 marketExposure, int256 tilt, uint256 isc ) =
            getPositionLiquidity(account, marketId, positionId);

        return marketExposure + int256(tilt) + int256(isc);
    }

    function getMinTilt(
        address account,
        uint256 marketId
    )
        internal
        view
        returns (int256 minTilt, uint256 minPositionId)
    {
        return HeapLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(
        address account,
        uint256 marketId
    )
        internal
        view
        returns (int256 maxTilt, uint256 maxPositionId)
    {
        return HeapLib.getMaxTilt(account, marketId);
    }

    /// @notice Canonical Back / Lay balances for an account on a position.
    /// @dev MUST match the semantics of ERC20BridgeLib.erc20BalanceOf.
    function getBackAndLayBalances(
        address account,
        uint256 marketId,
        uint256 positionId
    )
        internal
        view
        returns (uint256 backBalance, uint256 layBalance)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // After resolution, mirrors report 0 balances.
        if (s.marketResolved[marketId]) {
            return (0, 0);
        }

        // BACK MIRROR = created shares clamped at 0
        int256 created = getCreatedShares(account, marketId, positionId);
        if (created > 0) {
            backBalance = uint256(created);
        }

        // LAY MIRROR = only min-tilt leg has non-zero balance
        (, uint256 minPosId) = HeapLib.getMinTilt(account, marketId);
        if (minPosId != positionId) {
            // Not the min-tilt leg → no lay balance.
            return (backBalance, 0);
        }

        int256 delta = HeapLib._getMinTiltDelta(account, marketId);
        if (delta > 0) {
            layBalance = uint256(delta);
        }

        return (backBalance, layBalance);
    }
}
