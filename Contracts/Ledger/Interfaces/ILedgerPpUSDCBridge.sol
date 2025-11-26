// ILedgerPpUSDCBridge.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILedgerPpUSDCBridge {
    function effectiveTotalFreeCollateral() external view returns (uint256);
    function effectiveFreeCollateral(address account) external view returns (uint256);
    function ppUSDCTransfer(address from, address to, uint256 amount) external;
}
