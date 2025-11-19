
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";

library AllocateCapitalLib {
    function allocate(uint256 mmId, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[mmId] >= amount, "Insufficient free collateral");
        
        // reduce the amount of free capital the mmId has
        s.freeCollateral[mmId] -= amount;
        s.totalFreeCollateral -= amount;
        
        // allocate that to this marketId in terms of USDC spent
        s.USDCSpent[mmId][marketId] += amount;
        s.MarketUSDCSpent[marketId] += amount;

        // increase the value of the market appropriately
        s.marketValue[marketId] += amount;
        s.TotalMarketsValue += amount;  
    }

    function deallocate(uint256 mmId, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[mmId] + amount <= type(uint256).max, "Free collateral overflow");
        require(s.marketValue[marketId] >= amount, "Insufficient market value");
        
        // increase the amount of free capital the mmId has
        s.freeCollateral[mmId] += amount;
        s.totalFreeCollateral += amount;

        // increase the amount of redemptions made
        s.redeemedUSDC[mmId][marketId] += amount;
        s.Redemptions[marketId] += amount;

        //dececrease the value of the market appropriately 
        s.marketValue[marketId] -= amount;
        s.TotalMarketsValue -= amount;
    }
}
