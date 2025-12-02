// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "hardhat/console.sol"; // Add this

import "./1_StorageLib.sol";
import "./2_FreeCollateralLib.sol";

library AllocateCapitalLib {
    function allocate(address account, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.realFreeCollateral[account] >= amount, "Insufficient free collateral");
        
        console.log("Allocating %s for %s in market %s", amount, account, marketId);

        // reduce the amount of free capital the account has
        FreeCollateralLib.burnPpUSDC(account, amount);

        
        // allocate that to this marketId in terms of USDC spent
        s.USDCSpent[account][marketId] += amount;
        s.MarketUSDCSpent[marketId] += amount;

        // increase the value of the market appropriately
        s.marketValue[marketId] += amount;
        s.TotalMarketsValue += amount;  
    }

    function deallocate(address account, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.marketValue[marketId] >= amount, "Insufficient market value");
        
        console.log("Deallocating %s for %s in market %s", amount, account, marketId);
        console.log("Pre-dealloc marketValue = %s, TotalMarketsValue = %s", s.marketValue[marketId], s.TotalMarketsValue);

        // increase the amount of free capital the account has
        FreeCollateralLib.mintPpUSDC(account, amount);

        // increase the amount of redemptions made
        s.redeemedUSDC[account][marketId] += amount;
        s.Redemptions[marketId] += amount;

        //decrease the value of the market appropriately 
        s.marketValue[marketId] -= amount;
        s.TotalMarketsValue -= amount;
    }
}