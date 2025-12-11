// contracts/test/FeeLibHarness.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LedgerLibraries/1_StorageLib.sol";
import "./LedgerLibraries/2_FeeLib.sol";

contract FeeLibHarness {
    function setupConfig(
        uint256 marketId,
        uint16 feeBps,
        uint16 protocolShareBps,
        address creator,
        address owner_
    ) external {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.owner = owner_;
        s.feesConfig[marketId].feeBps           = feeBps;
        s.feesConfig[marketId].protocolShareBps = protocolShareBps;
        s.feesConfig[marketId].creator          = creator;
    }

    function setWhitelist(
        uint256 marketId,
        address account,
        bool isFree
    ) external {
        StorageLib.getStorage().feeWhiteList[marketId][account] = isFree;
    }

    function setNetAllocState(
        address account,
        uint256 marketId,
        uint256 spent,
        uint256 redeemed,
        uint256 prevHwm,
        uint256 realFree
    ) external {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.USDCSpent[account][marketId]  = spent;
        s.redeemedUSDC[account][marketId] = redeemed;
        s.netUSDCAllocationHighWatermark[account][marketId] = prevHwm;
        s.realFreeCollateral[account] = realFree;
    }

    function applyFee(address account, uint256 marketId) external {
        StorageLib.Storage storage s = StorageLib.getStorage();
        FeeLib.applyNetAllocationFee(s, account, marketId);
    }

    function realFree(address account) external view returns (uint256) {
        return StorageLib.getStorage().realFreeCollateral[account];
    }

    function hwm(address account, uint256 marketId) external view returns (uint256) {
        return StorageLib.getStorage().netUSDCAllocationHighWatermark[account][marketId];
    }
}
