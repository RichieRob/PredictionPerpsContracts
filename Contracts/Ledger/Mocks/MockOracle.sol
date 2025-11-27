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
