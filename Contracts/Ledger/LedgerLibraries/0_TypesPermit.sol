
// T0_TypesPermit.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library TypesPermit {
    struct EIP2612Permit {
        uint256 value;
        uint256 deadline;
        uint8 v; bytes32 r; bytes32 s;
    }
}