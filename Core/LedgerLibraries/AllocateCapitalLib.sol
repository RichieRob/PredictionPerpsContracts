
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./freeCollateralLib.sol";

library AllocateCapitalLib {
    function allocate(address account, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[account] >= amount, "Insufficient free collateral");
        
        // reduce the amount of free capital the account has
        FreeCollateralEventsLib.decreaseFreeCollateralWithEvent(account, amount)

        
        // allocate that to this marketId in terms of USDC spent
        s.USDCSpent[account][marketId] += amount;
        s.MarketUSDCSpent[marketId] += amount;

        // increase the value of the market appropriately
        s.marketValue[marketId] += amount;
        s.TotalMarketsValue += amount;  
    }

    function deallocate(address account, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[account] + amount <= type(uint256).max, "Free collateral overflow");
        require(s.marketValue[marketId] >= amount, "Insufficient market value");
        
        // increase the amount of free capital the account has
        FreeCollateralEventsLib.increaseFreeCollateralWithEvent(account, amount)

        // increase the amount of redemptions made
        s.redeemedUSDC[account][marketId] += amount;
        s.Redemptions[marketId] += amount;

        //dececrease the value of the market appropriately 
        s.marketValue[marketId] -= amount;
        s.TotalMarketsValue -= amount;
    }
}
