// SPDX-License-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./TokenOpsLib.sol";


// need to check this
//need to include redeem pair

library RedemptionLib {
    event Redeemed(uint256 indexed marketId, uint256 amount);

    function redeemSet(uint256 marketId, uint256[] memory positionIds, uint256 amount, address to) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.marketValue[marketId] >= amount, "Insufficient market value");
        require(s.aUSDC.balanceOf(address(this)) >= amount, "Insufficient aUSDC balance");

        if (positionIds.length == 0) {
            require(s.marketPositions[marketId].length == 1, "Single position market required");
            uint256 positionId = s.marketPositions[marketId][0];
            uint256[] memory tokenIds = new uint256[](2);
            uint256[] memory amounts = new uint256[](2);
            bool[] memory isBacks = new bool[](2);
            uint256[] memory marketIds = new uint256[](2);
            marketIds[0] = marketId;
            marketIds[1] = marketId;
            positionIds = new uint256[](2);
            positionIds[0] = positionId;
            positionIds[1] = positionId;
            isBacks[0] = true;
            isBacks[1] = false;
            amounts[0] = amount;
            amounts[1] = amount;
            TokenOpsLib.batchBurn(marketIds, positionIds, isBacks, amounts, msg.sender);
        } else {
            require(positionIds.length == s.marketPositions[marketId].length, "Full set of positions required");
            uint256[] memory tokenIds = new uint256[](positionIds.length);
            uint256[] memory amounts = new uint256[](positionIds.length);
            bool[] memory isBacks = new bool[](positionIds.length);
            uint256[] memory marketIds = new uint256[](positionIds.length);
            for (uint256 i = 0; i < positionIds.length; i++) {
                marketIds[i] = marketId;
                isBacks[i] = true;
                amounts[i] = amount;
            }
            TokenOpsLib.batchBurn(marketIds, positionIds, isBacks, amounts, msg.sender);
        }

        s.Redemptions[marketId] += amount;
        s.marketValue[marketId] -= amount;
        s.TotalMarketsValue -= amount;
        s.totalValueLocked -= amount;
        s.aavePool.withdraw(address(s.usdc), amount, to);
        emit Redeemed(marketId, amount);
    }
}
