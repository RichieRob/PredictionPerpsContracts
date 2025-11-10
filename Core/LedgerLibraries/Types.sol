// SPDX-License-License-Identifier: MIT
pragma solidity ^0.8.20;

library Types {
    uint256 constant BLOCK_SIZE = 16;

struct BlockData {
    uint256 minId;
    int128  minVal;
}


    struct TokenData {
        uint64 marketId;
        uint64 positionId;
        bool isBack;
    }
}
