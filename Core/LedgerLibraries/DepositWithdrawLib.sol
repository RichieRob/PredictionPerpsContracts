// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "../../Interfaces/IERC20Permit.sol";
import "../../Interfaces/IPermit2.sol";
import "./TypesPermit.sol";
import "./ProtocolFeeLib.sol";

/// @title DepositWithdrawLib
/// @notice Handles trader deposits and withdrawals to/from Aave,
///         integrating optional protocol fee skimming via aUSDC.
library DepositWithdrawLib {
    using TypesPermit for *;

    // -----------------------------------------------------------------------
    // Deposit using native EIP-2612 permit (USDC with permit)
    // -----------------------------------------------------------------------
    function depositFromTraderWithEIP2612(
        uint256 mmId,
        address trader,
        uint256 amount,
        uint256 minUSDCDeposited,
        TypesPermit.EIP2612Permit memory p
    ) internal returns (uint256 recordedAmount) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // 1. Approve ledger via permit (gasless approval)
        IERC20Permit(address(s.usdc)).permit(
            trader,
            address(this),
            p.value,
            p.deadline,
            p.v,
            p.r,
            p.s
        );

        // 2. Pull USDC from trader
        require(s.usdc.transferFrom(trader, address(this), amount), "USDC pull fail");

        // 3. Supply to Aave
        s.usdc.approve(address(s.aavePool), amount);
        uint256 a0 = s.aUSDC.balanceOf(address(this));
        s.aavePool.supply(address(s.usdc), amount, address(this), 0);
        uint256 a1 = s.aUSDC.balanceOf(address(this));
        uint256 aReceived = a1 - a0;

        // 4. Skim protocol fee (if enabled)
        recordedAmount = ProtocolFeeLib.skimOnAaveSupply(aReceived);

        require(recordedAmount >= minUSDCDeposited, "Deposit below minimum");

        // 5. Credit net collateral to MM
        s.freeCollateral[mmId] += recordedAmount;
        s.totalFreeCollateral += recordedAmount;
        s.totalValueLocked += recordedAmount;
    }

    // -----------------------------------------------------------------------
    // Deposit using Permit2 (e.g. across-chain compatible permit system)
    // -----------------------------------------------------------------------
    function depositFromTraderWithPermit2(
        uint256 mmId,
        address trader,
        uint256 amount,
        uint256 minUSDCDeposited,
        bytes calldata permit2Calldata
    ) internal returns (uint256 recordedAmount) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.permit2 != address(0), "Permit2 not set");

        // 1. Permit2 transfer to ledger
        IPermit2(s.permit2).permitTransferFrom(
            permit2Calldata,
            trader,
            address(this),
            amount
        );

        // 2. Supply to Aave
        s.usdc.approve(address(s.aavePool), amount);
        uint256 a0 = s.aUSDC.balanceOf(address(this));
        s.aavePool.supply(address(s.usdc), amount, address(this), 0);
        uint256 a1 = s.aUSDC.balanceOf(address(this));
        uint256 aReceived = a1 - a0;

        // 3. Skim protocol fee (if enabled)
        recordedAmount = ProtocolFeeLib.skimOnAaveSupply(aReceived);

        require(recordedAmount >= minUSDCDeposited, "Deposit below minimum");

        // 4. Credit net collateral to MM
        s.freeCollateral[mmId] += recordedAmount;
        s.totalFreeCollateral += recordedAmount;
        s.totalValueLocked += recordedAmount;
    }

    // -----------------------------------------------------------------------
    // Withdraw directly to recipient (no fee)
    // -----------------------------------------------------------------------
    function withdrawTo(uint256 mmId, uint256 amount, address to) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.mmIdToAddress[mmId] == msg.sender, "Invalid MMId");
        require(s.freeCollateral[mmId] >= amount, "Insufficient free collateral");
        require(to != address(0), "Invalid recipient");

        // Update accounting before external call
        s.freeCollateral[mmId] -= amount;
        s.totalFreeCollateral -= amount;
        s.totalValueLocked -= amount;

        // Withdraw from Aave directly to recipient
        s.aavePool.withdraw(address(s.usdc), amount, to);
    }

    // -----------------------------------------------------------------------
    // Owner interest skim (no double-transfer risk)
    // -----------------------------------------------------------------------
    function withdrawInterest(address sender) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(sender == s.owner, "Only owner");
        uint256 interest = getInterest();
        if (interest > 0) {
            s.aavePool.withdraw(address(s.usdc), interest, s.owner);
        }
    }

    function getInterest() internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.aUSDC.balanceOf(address(this)) - s.totalValueLocked;
    }
}
