
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./HeapLib.sol";
import "./MarketManagementLib.sol";
import "./SolvencyLib.sol";


library LedgerLib {
    function getPositionLiquidity(
    address account,
    uint256 marketId,
    uint256 positionId
)
    internal
    view
    returns (
        uint256 freeCollateral,
        int256  marketExposure,
        int256  tilt
    )
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256 isc = MarketManagementLib.isDMM(account, marketId)
        ? s.syntheticCollateral[marketId]
        : 0;

    freeCollateral = s.freeCollateral[account] + isc;

    int256 netAlloc = SolvencyLib._netUSDCAllocationSigned(s, account, marketId);

    marketExposure = netAlloc + s.layOffset[account][marketId];

    tilt = s.tilt[account][marketId][positionId];
}



function getAvailableShares(address account, uint256 marketId, uint256 positionId)
    internal
    view
    returns (int256)
{
    (uint256 freeCollateral, int256 marketExposure, int256 tilt) =
        getPositionLiquidity(account, marketId, positionId);

    return int256(freeCollateral) + marketExposure + int256(tilt);
}


    function getMinTilt(address account, uint256 marketId) internal view returns (int256 minTilt, uint256 minPositionId) {
        return HeapLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(address account, uint256 marketId) internal view returns (int256 maxTilt, uint256 maxPositionId) {
        return HeapLib.getMaxTilt(account, marketId);
    }
}
