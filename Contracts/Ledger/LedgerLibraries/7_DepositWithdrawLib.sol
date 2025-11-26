// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "../Interfaces/IERC20Permit.sol";
import "../Interfaces/IPermit2.sol";
import "./0_TypesPermit.sol";
import "./2_FreeCollateralLib.sol";
import "./2_ProtocolFeeLib.sol";
import "./6_ResolutionLib.sol";

/// @title DepositWithdrawLib
/// @notice Handles trader deposits and withdrawals to/from Aave,
///         integrating optional protocol fee skimming via aUSDC.
library DepositWithdrawLib {
    using TypesPermit for *;

    // mode constants for unified deposit
    // 0 = allowance (transferFrom)
    // 1 = EIP-2612 permit
    // 2 = Permit2
    uint8 internal constant MODE_ALLOWANCE = 0;
    uint8 internal constant MODE_EIP2612  = 1;
    uint8 internal constant MODE_PERMIT2  = 2;

    // -----------------------------------------------------------------------
    // Core internal deposit
    // -----------------------------------------------------------------------
    /// @dev Pulls USDC from `from` (if non-zero), supplies to Aave, skims fees,
    ///      credits freeCollateral for `to`, updates TVL and returns recordedAmount.
    function _internalDeposit(
        address from,
        address to,
        uint256 amount,
        uint256 minUSDCDeposited
    ) internal returns (uint256 recordedAmount) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // 1. Pull from user if requested (for Permit2 we can pass from = address(0))
        if (from != address(0)) {
            require(s.usdc.transferFrom(from, address(this), amount), "USDC pull fail");
        }

        // 2. Supply to Aave
        s.usdc.approve(address(s.aavePool), amount);
        uint256 a0 = s.aUSDC.balanceOf(address(this));
        s.aavePool.supply(address(s.usdc), amount, address(this), 0);
        uint256 a1 = s.aUSDC.balanceOf(address(this));
        uint256 aReceived = a1 - a0;

        // 3. Skim protocol fee (if enabled)
        recordedAmount = ProtocolFeeLib.skimOnAaveSupply(aReceived);
        require(recordedAmount >= minUSDCDeposited, "Deposit below minimum");

        // 4. Credit net collateral to `to` (and emit ppUSDC Mint event)
        FreeCollateralLib.mintPpUSDC(to, recordedAmount);

        // 5. Track TVL principal
        s.totalValueLocked += recordedAmount;

     // apply winnings; process `to` always, and `from` only if distinct & non-zero
    ResolutionLib._applyPendingWinnings(to);
    if (from != address(0) && from != to) {
    ResolutionLib._applyPendingWinnings(from);
}

    }

    /// @notice Simple direct deposit from msg.sender → msg.sender with no min.
    function simpleDeposit(uint256 amount) internal returns (uint256 recordedAmount) {
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
        recordedAmount = _internalDeposit(trader, account, amount, minUSDCDeposited);
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
        recordedAmount = _internalDeposit(trader, account, amount, minUSDCDeposited);
    }

    // -----------------------------------------------------------------------
    // 3) Deposit using Permit2
    // -----------------------------------------------------------------------
    function depositFromTraderWithPermit2(
        address account,
        address trader,
        uint256 amount,
        uint256 minUSDCDeposited,
        bytes calldata permit2Calldata
    ) internal returns (uint256 recordedAmount) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.permit2 != address(0), "Permit2 not set");

        // 1. Permit2 transfer to ledger (this already pulls tokens)
        IPermit2(s.permit2).permitTransferFrom(
            permit2Calldata,
            trader,
            address(this),
            amount
        );

        // 2. Shared internalDeposit, but skip transferFrom (from = address(0))
        recordedAmount = _internalDeposit(address(0), account, amount, minUSDCDeposited);
    }

    // -----------------------------------------------------------------------
    // Unified 3-way helper
    // -----------------------------------------------------------------------
    /// @notice Unified entry: choose between allowance / EIP-2612 / Permit2.
    /// @param account            Ledger account to credit.
    /// @param trader             Address paying USDC (usually msg.sender).
    /// @param amount             Nominal USDC to move.
    /// @param minUSDCDeposited   Min credited after fees.
    /// @param mode               0=allowance, 1=EIP-2612, 2=Permit2.
    /// @param eipPermit          Only used if mode==1.
    /// @param permit2Calldata    Only used if mode==2.
    function depositFromTraderUnified(
        address account,
        address trader,
        uint256 amount,
        uint256 minUSDCDeposited,
        uint8  mode,
        TypesPermit.EIP2612Permit memory eipPermit,
        bytes calldata permit2Calldata
    ) internal returns (uint256 recordedAmount) {
        if (mode == MODE_ALLOWANCE) {
            // simple allowance + transferFrom path
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
        } else if (mode == MODE_PERMIT2) {
            recordedAmount = depositFromTraderWithPermit2(
                account,
                trader,
                amount,
                minUSDCDeposited,
                permit2Calldata
            );
        } else {
            revert("Deposit: invalid mode");
        }
    }

    // -----------------------------------------------------------------------
    // Withdraw directly to recipient (no fee)
    // -----------------------------------------------------------------------
    function withdrawWithoutClaims(address account, uint256 amount, address to) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(account == msg.sender, "Invalid account");
        require(to != address(0), "Invalid recipient");

        // This will revert internally if freeCollateral[account] < amount
        FreeCollateralLib.burnPpUSDC(account, amount);
        s.totalValueLocked -= amount;

        // Withdraw from Aave directly to recipient
        s.aavePool.withdraw(address(s.usdc), amount, to);
    }

    /// @notice User withdraws and we first realise any pending winnings.
    function withdrawWithClaims(address account, uint256 amount, address to) internal {
        // 1. Realise pending winnings (may mint more freeCollateral).
        ResolutionLib._applyPendingWinnings(account);

        // 2. Do the actual accounting + Aave withdraw in ONE place.
        withdrawWithoutClaims(account, amount, to);
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
