// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Types {
    uint256 constant BLOCK_SIZE = 16;

    /// @notice Generic per-block extremum data.
    /// Used for both:
    ///   - minBlockData (min-heap)  → (id, val) = (minId, minTilt)
    ///   - blockDataMax (max-heap) → (id, val) = (maxId, maxTilt)
    struct BlockData {
        uint256 id;
        int256  val;
    }

    struct TokenData {
        uint64 marketId;
        uint64 positionId;
        bool   isBack;
    }
}