
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

    realFreeCollateral = s.freeCollateral[account];

    int256 netAlloc = SolvencyLib._netUSDCAllocationSigned(s, account, marketId);

    marketExposure = netAlloc + s.layOffset[account][marketId];

    tilt = s.tilt[account][marketId][positionId];
}



function getFullAvailableShares(address account, uint256 marketId, uint256 positionId)
    internal
    view
    returns (int256)
{

    (uint256 freeCollateral, int256 marketExposure, int256 tilt, uint256 isc) =
        getPositionLiquidity(account, marketId, positionId);

    return int256(freeCollateral) + marketExposure + int256(tilt) + int256(isc);
}


function getAllocatedAvailableShares(address account, uint256 marketId, uint256 positionId)
    internal
    view
    returns (int256)
{
    //ISC balance included in freeCollateral for DMM

    ( , int256 marketExposure, int256 tilt, uint256 isc ) =
        getPositionLiquidity(account, marketId, positionId);

    return marketExposure + int256(tilt) + int256(isc);
}




    function getMinTilt(address account, uint256 marketId) internal view returns (int256 minTilt, uint256 minPositionId) {
        return HeapLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(address account, uint256 marketId) internal view returns (int256 maxTilt, uint256 maxPositionId) {
        return HeapLib.getMaxTilt(account, marketId);
    }
}
