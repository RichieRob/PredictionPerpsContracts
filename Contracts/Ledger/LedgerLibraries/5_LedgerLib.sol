
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




library 5_LedgerLib {
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

    uint256 isc = 2_MarketManagementLib.isDMM(account, marketId)
        ? s.syntheticCollateral[marketId]
        : 0;
    
    amountOfISCForThisAccountAndMarket = isc;

    realFreeCollateral = s.realFreeCollateral[account];

    int256 netAlloc = 4_SolvencyLib._netUSDCAllocationSigned(s, account, marketId);

    marketExposure = netAlloc + s.layOffset[account][marketId];

    tilt = s.tilt[account][marketId][positionId];
}



function getFullCapacityShares(address account, uint256 marketId, uint256 positionId)
    internal
    view
    returns (int256)
{

    (uint256 freeCollateral, int256 marketExposure, int256 tilt, uint256 isc) =
        getPositionLiquidity(account, marketId, positionId);

    return int256(freeCollateral) + marketExposure + int256(tilt) + int256(isc);
}


function getCreatedShares(address account, uint256 marketId, uint256 positionId)
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
        return 3_HeapLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(address account, uint256 marketId) internal view returns (int256 maxTilt, uint256 maxPositionId) {
        return 3_HeapLib.getMaxTilt(account, marketId);
    }
}
