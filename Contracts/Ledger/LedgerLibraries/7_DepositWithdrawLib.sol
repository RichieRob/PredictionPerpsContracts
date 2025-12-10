// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "../Interfaces/IERC20Permit.sol";
import "./0_TypesPermit.sol";
import "./6_ClaimsLib.sol";

interface INotify {
    function notifyTransfer(address from, address to, uint256 amount) external;
}

/// @title DepositWithdrawLib
/// @notice Handles trader deposits and withdrawals to/from Aave.
/// @dev No protocol fee is taken on deposit. All protocol/creator revenue
///      comes from FeeLib (HWM-based fees on net allocation).
library DepositWithdrawLib {
    using TypesPermit for *;

    // mode constants for unified deposit
    // 0 = allowance (transferFrom)
    // 1 = EIP-2612 permit
    uint8 internal constant MODE_ALLOWANCE = 0;
    uint8 internal constant MODE_EIP2612  = 1;

    // -----------------------------------------------------------------------
    // Core internal deposit
    // -----------------------------------------------------------------------
    /// @dev Pulls USDC from `from` (if non-zero), supplies to Aave,
    ///      credits freeCollateral for `to`, updates TVL and returns recordedAmount.
    ///      ppUSDC events here ONLY reflect the explicit deposit amount, not winnings.
    function _internalDeposit(
        address from,
        address to,
        uint256 amount,
        uint256 minUSDCDeposited
    ) internal returns (uint256 recordedAmount) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // 1. Pull from user if requested
        if (from != address(0)) {
            require(
                s.usdc.transferFrom(from, address(this), amount),
                "USDC pull fail"
            );
        }

        // 2. Supply to Aave
        s.usdc.approve(address(s.aavePool), amount);
        uint256 a0 = s.aUSDC.balanceOf(address(this));
        s.aavePool.supply(address(s.usdc), amount, address(this), 0);
        uint256 a1 = s.aUSDC.balanceOf(address(this));
        uint256 aReceived = a1 - a0;

        // 3. No protocol skim: full aReceived becomes user principal
        recordedAmount = aReceived;
        require(recordedAmount >= minUSDCDeposited, "Deposit below minimum");

        // 4. Credit net collateral to `to`
        s.realFreeCollateral[to]  += recordedAmount;
        s.realTotalFreeCollateral += recordedAmount;

        //    Mirror deposit as ppUSDC mint *based on credited amount*
        if (recordedAmount > 0) {
            INotify(address(s.ppUSDC)).notifyTransfer(
                address(0),
                to,
                recordedAmount
            );
        }

        // 5. Track TVL principal
        s.totalValueLocked += recordedAmount;

        // 6. Optional hygiene: soft pull of any pending winnings for `from`
        //    (required = 0 -> shortfall = 0 => "cheap claim if available")
        if (from != address(0)) {
            ClaimsLib.ensureFreeCollateralFor(from, 0);
        }
    }

    /// @notice Simple direct deposit from msg.sender → msg.sender with no min.
    function simpleDeposit(uint256 amount)
        internal
        returns (uint256 recordedAmount)
    {
        // from = msg.sender, to = msg.sender, minUSDCDeposited = 0
        recordedAmount = _internalDeposit(msg.sender, msg.sender, amount, 0);
    }

    // -----------------------------------------------------------------------
    // 1) Deposit via plain allowance/transferFrom
    // -----------------------------------------------------------------------
    function depositFromTraderWithAllowance(
        address account,
        address trader,
        uint256 amount,
        uint256 minUSDCDeposited
    ) internal returns (uint256 recordedAmount) {
        recordedAmount = _internalDeposit(
            trader,
            account,
            amount,
            minUSDCDeposited
        );
    }

    // -----------------------------------------------------------------------
    // 2) Deposit using native EIP-2612 permit (USDC with permit)
    // -----------------------------------------------------------------------
    function depositFromTraderWithEIP2612(
        address account,
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

        // 2. Use shared internalDeposit to pull from trader and credit `account`
        recordedAmount = _internalDeposit(
            trader,
            account,
            amount,
            minUSDCDeposited
        );
    }

    // -----------------------------------------------------------------------
    // Unified helper (2 modes)
    // -----------------------------------------------------------------------
    /// @notice Unified entry: choose between allowance / EIP-2612.
    /// @param account            Ledger account to credit.
    /// @param trader             Address paying USDC (usually msg.sender).
    /// @param amount             Nominal USDC to move.
    /// @param minUSDCDeposited   Min credited after deposit.
    /// @param mode               0=allowance, 1=EIP-2612.
    /// @param eipPermit          Only used if mode==1.
    function depositFromTraderUnified(
        address account,
        address trader,
        uint256 amount,
        uint256 minUSDCDeposited,
        uint8  mode,
        TypesPermit.EIP2612Permit memory eipPermit
    ) public returns (uint256 recordedAmount) {
        if (mode == MODE_ALLOWANCE) {
            recordedAmount = depositFromTraderWithAllowance(
                account,
                trader,
                amount,
                minUSDCDeposited
            );
        } else if (mode == MODE_EIP2612) {
            recordedAmount = depositFromTraderWithEIP2612(
                account,
                trader,
                amount,
                minUSDCDeposited,
                eipPermit
            );
        } else {
            revert("Deposit: invalid mode");
        }
    }

    // -----------------------------------------------------------------------
    // Withdraw directly to recipient (no fee)
    // -----------------------------------------------------------------------
    function withdrawWithoutClaims(
        address account,
        uint256 amount,
        address to
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(account == msg.sender, "Invalid account");
        require(to != address(0), "Invalid recipient");

        // This will revert on underflow if freeCollateral[account] < amount
        s.realFreeCollateral[account]  -= amount;
        s.realTotalFreeCollateral      -= amount;

        // Mirror user USDC-out as ppUSDC burn event
        if (amount > 0) {
            INotify(address(s.ppUSDC)).notifyTransfer(
                account,
                address(0),
                amount
            );
        }

        s.totalValueLocked -= amount;

        // Withdraw from Aave directly to recipient
        s.aavePool.withdraw(address(s.usdc), amount, to);
    }

    /// @notice User withdraws and we first realise any pending winnings
    ///         sufficient to cover the requested amount if possible.
    ///         Winnings are credited silently; the ppUSDC burn event only
    ///         reflects the explicit withdrawal amount.
    function withdrawWithClaims(
        address account,
        uint256 amount,
        address to
    ) public {
        // 1. Ensure account has at least `amount` free collateral
        //    (runs hygiene + hard rounds if needed)
        ClaimsLib.ensureFreeCollateralFor(account, amount);

        // 2. Now do the actual accounting + Aave withdraw in ONE place.
        //    If after claims there's still not enough freeCollateral,
        //    this will underflow and revert.
        withdrawWithoutClaims(account, amount, to);
    }

    // -----------------------------------------------------------------------
    // Owner interest skim (pure Aave yield)
    // -----------------------------------------------------------------------
    function withdrawInterest(address sender) public {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(sender == s.owner, "Only owner");
        uint256 interest = getInterest();
        if (interest > 0) {
            s.aavePool.withdraw(address(s.usdc), interest, s.owner);
        }
    }

    function getInterest() public view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.aUSDC.balanceOf(address(this)) - s.totalValueLocked;
    }
}
