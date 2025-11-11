
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";

library AllocateCapitalLib {
    function allocate(uint256 mmId, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[mmId] >= amount, "Insufficient free collateral");
        s.freeCollateral[mmId] -= amount;
        s.totalFreeCollateral -= amount;
        s.USDCSpent[mmId][marketId] += int256(amount);
        s.MarketUSDCSpent[marketId] += amount;
        s.marketValue[marketId] += amount;
        s.TotalMarketsValue += amount;  
    }

    function deallocate(uint256 mmId, uint256 marketId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[mmId] + amount <= type(uint256).max, "Free collateral overflow");
        require(s.marketValue[marketId] >= amount, "Insufficient market value");
        s.freeCollateral[mmId] += amount;
        s.totalFreeCollateral += amount;
        s.USDCSpent[mmId][marketId] -= int256(amount);
        s.MarketUSDCSpent[marketId] -= amount;
        s.marketValue[marketId] -= amount;
        s.TotalMarketsValue -= amount;
    }
}
