// AMMLibraries/ILedgerPositions.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILedgerPositions {
    function positionExists(uint256 marketId, uint256 positionId)
        external
        view
        returns (bool);
}
