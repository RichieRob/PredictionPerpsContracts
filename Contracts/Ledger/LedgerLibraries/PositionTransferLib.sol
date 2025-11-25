// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./SolvencyLib.sol";
import "./HeapLib.sol";
import "./MarketManagementLib.sol";

library PositionTransferLib {

/*//////////////////////////////////////////////////////////////
                       EVENTS
//////////////////////////////////////////////////////////////*/

event PositionTransfer(
    address indexed from,
    address indexed to,
    uint256 indexed marketId,
    uint256 positionId,
    bool    isBack,
    uint256 amount
);

    /*//////////////////////////////////////////////////////////////
                              CORE PRIMITIVES
    //////////////////////////////////////////////////////////////*/




    function _receiveBack(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        // H_k += amount  via tilt
        HeapLib.updateTilt(account, marketId, positionId, int256(amount));

        // If this made the account "over-collateralised" we can free some capital
        SolvencyLib.deallocateExcess(account, marketId);
    }

    function _receiveLay(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Lay received: layOffset += amount, tilt -= amount
        s.layOffset[account][marketId] += int256(amount);
        HeapLib.updateTilt(account, marketId, positionId, -int256(amount));

        // Again, receiving exposure can relax the tightest constraint
        SolvencyLib.deallocateExcess(account, marketId);
    }

    function _emitBack(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        // Sending Back: H_k -= amount via tilt
        HeapLib.updateTilt(account, marketId, positionId, -int256(amount));

        // Check we are still solvent after lowering H_k
        SolvencyLib.ensureSolvency(account, marketId);
    }

    function _emitLay(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Sending Lay: layOffset -= amount, tilt += amount
        s.layOffset[account][marketId] -= int256(amount);
        HeapLib.updateTilt(account, marketId, positionId, int256(amount));

        // Check we remain solvent after changing offsets
        SolvencyLib.ensureSolvency(account, marketId);
    }

    /*//////////////////////////////////////////////////////////////
                        HIGH-LEVEL TRANSFER HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal Back transfer: from -> to, same market/position.
    /// @dev Caller (ledger) is responsible for checking token balances etc.
    function transferBack(
        address from,
        address to,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        require(amount > 0, "zero amount");
        require(MarketManagementLib.positionExists(marketId, positionId), "Position !exists");

        if (from != address(0)) {
            _emitBack(from, marketId, positionId, amount);
        }
        if (to != address(0)) {
            _receiveBack(to, marketId, positionId, amount);
        }
    }

    /// @notice Internal Lay transfer: from -> to, same market/position.
    function transferLay(
        address from,
        address to,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        require(amount > 0, "zero amount");
        require(MarketManagementLib.positionExists(marketId, positionId), "Position !exists");

        if (from != address(0)) {
            _emitLay(from, marketId, positionId, amount);
        }
        if (to != address(0)) {
            _receiveLay(to, marketId, positionId, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       GENERIC POSITION TRANSFER SWITCH
    //////////////////////////////////////////////////////////////*/

    function transferPosition(
        address from,
        address to,
        uint256 marketId,
        uint256 positionId,
        bool isBack,
        uint256 amount
    ) internal {
        if (isBack) {
            transferBack(from, to, marketId, positionId, amount);
        } else {
            transferLay(from, to, marketId, positionId, amount);
        }
        emit PositionTransfer(from, to, marketId, positionId, isBack, amount);

    }
}
