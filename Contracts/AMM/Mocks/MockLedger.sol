// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../AMMLibraries/ILedgerPositions.sol";

/// @title MockLedger
/// @notice Minimal mock implementing ILedgerPositions for LMSR tests.
///         Lets tests "seed" positions so positionExists(...) returns true.
contract MockLedger is ILedgerPositions {
    // marketId => positionId => exists?
    mapping(uint256 => mapping(uint256 => bool)) private _positionExists;

    /// @notice Test helper: mark a (marketId, positionId) as existing.
    function seedPosition(uint256 marketId, uint256 positionId) external {
        _positionExists[marketId][positionId] = true;
    }

    /// @inheritdoc ILedgerPositions
    function positionExists(
        uint256 marketId,
        uint256 positionId
    ) external view override returns (bool) {
        return _positionExists[marketId][positionId];
    }
}
