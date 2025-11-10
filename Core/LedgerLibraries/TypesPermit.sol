
// TypesPermit.sol
pragma solidity ^0.8.20;

library TypesPermit {
    struct EIP2612Permit {
        uint256 value;
        uint256 deadline;
        uint8 v; bytes32 r; bytes32 s;
    }

    // Minimal Permit2 single permit (Uniswap Permit2)
    struct Permit2Single {
        address owner;
        address token;
        uint160 amount;
        uint48  expiration;
        uint48  nonce;
        uint256 sigDeadline;
        bytes   signature; // 65 bytes ECDSA
    }
}
