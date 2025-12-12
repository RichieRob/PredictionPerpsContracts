// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Interfaces/IOracle.sol";

contract MockOracle is IOracle {
    bool public resolved;
    uint256 public winner;

    function pushResolution(uint256 marketId, uint256 _winner) external {
        resolved = true;
        winner = _winner;
    }

    function getResolutionData(uint256 marketId, bytes calldata)
        external view
        returns (bool, uint256)
    {
        return (resolved, winner);
    }
}


//Updated needed - For markets that have an indefinite number of positions - they are expanding and have a bucked for other positons
//Currently there is no way for the Oracle to resolve those markets
// Suggestion is that we have a function which 1) Creates a new position on the ledger and then resolves to that position. We can do this in one transaction.