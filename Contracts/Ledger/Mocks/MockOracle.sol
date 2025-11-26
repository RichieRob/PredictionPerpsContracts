// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockOracle {
    mapping(uint256 => bool) public isResolved;
    mapping(uint256 => uint256) public winningPositionId;

    function setResolution(uint256 marketId, uint256 _winningPositionId) external {
        isResolved[marketId] = true;
        winningPositionId[marketId] = _winningPositionId;
    }

    function getResolutionData(uint256 marketId, bytes calldata /*params*/) external view returns (bool, uint256) {
        return (isResolved[marketId], winningPositionId[marketId]);
    }
}