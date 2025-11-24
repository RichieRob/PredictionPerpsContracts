
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal interface for Uniswap Permit2 `permitTransferFrom`.
///         In production, import the official interface/types.
interface IPermit2 {
    function permitTransferFrom(
        bytes calldata permit,  // encoded PermitTransferFrom struct
        address owner,
        address to,
        uint256 requestedAmount
    ) external;
}
