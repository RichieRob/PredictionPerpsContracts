// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    /**
     * @notice Returns the resolution outcome for a market.
     * @param marketId The market ID to resolve.
     * @param params Custom parameters stored at market creation (e.g., query ID, feed key).
     * @return isResolved True if data is ready.
     * @return winningPositionId The winning position ID (or 0 if invalid/not ready).
     */
    function getResolutionData(uint256 marketId, bytes calldata params) external view returns (bool isResolved, uint256 winningPositionId);
}