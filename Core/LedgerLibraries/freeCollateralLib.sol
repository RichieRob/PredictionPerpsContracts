// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";

/// @title FreeCollateralLib
/// @notice Helpers to adjust freeCollateral and totalFreeCollateral
///         and mirror those changes as ppUSDC mint/burn events.
library FreeCollateralLib {

      /// @dev Internal helper: emit a ppUSDC mint event via the ppUSDC contract.
    function emitPpUSDCMint(address to, uint256 amount) internal {
    if (amount == 0) return;
    StorageLib.Storage storage s = StorageLib.getStorage();
    IPpUSDCEvents(address(s.ppUSDC)).externalMint(to, amount);
}

    function emitPpUSDCBurn(address from, uint256 amount) internal {
    if (amount == 0) return;
    StorageLib.Storage storage s = StorageLib.getStorage();
    IPpUSDCEvents(address(s.ppUSDC)).externalBurn(from, amount);
    }


    /// @notice Increase freeCollateral for an account and emit ppUSDC mint event.
    /// @dev Assumes caller has already decided this increase is valid.
    function increaseFreeCollateralWithEvent(address account, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        s.freeCollateral[account] += amount;
        s.totalFreeCollateral     += amount;

        // Mirror as ppUSDC mint
        emitPpUSDCMint(account, amount);
    }

    /// @notice Decrease freeCollateral for an account and emit ppUSDC burn event.
    /// @dev Reverts if freeCollateral would underflow.
    function decreaseFreeCollateralWithEvent(address account, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[account] >= amount, "Insufficient free collateral");

        s.freeCollateral[account] -= amount;
        s.totalFreeCollateral     -= amount;

        // Mirror as ppUSDC burn
        emitPpUSDCBurn(account, amount);
    }

    /// @notice Internal ppUSDC/freeCollateral transfer with NO events.
    function transferFreeCollateral(address from, address to, uint256 amount) internal {
        if (amount == 0 || from == to) return;
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.freeCollateral[from] >= amount, "Insufficient free collateral");
        s.freeCollateral[from] -= amount;
        s.freeCollateral[to]   += amount;
        // totalFreeCollateral unchanged
    }
}
