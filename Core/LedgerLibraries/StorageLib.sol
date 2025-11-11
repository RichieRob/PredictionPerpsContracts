
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Types.sol"; // <-- needed for BlockData and TokenData

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

library StorageLib {
    struct Storage {
        // Core tokens/protocols
        IERC20 usdc;
        IERC20 aUSDC;
        IAavePool aavePool;
        address owner;

        // MM registry
        mapping(uint256 => address) mmIdToAddress;
        uint256 nextMMId;

        // Collateral & accounting
        mapping(uint256 => uint256) freeCollateral; // per mmId
        mapping(uint256 => mapping(uint256 => int256)) USDCSpent; // mmId => marketId => int256 (can be negative)
        mapping(uint256 => mapping(uint256 => int256)) layOffset; // mmId => marketId => int256 (net Lay flow)
        mapping(uint256 => uint256) MarketUSDCSpent;
        mapping(uint256 => uint256) Redemptions;
        mapping(uint256 => uint256) marketValue;
        uint256 TotalMarketsValue;
        uint256 totalFreeCollateral;
        uint256 totalValueLocked;

        // Heap mapping (min-heap)
        mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) heapIndex; // mmId => marketId => blockId => index+1 (0 = not present)

        // Risk / tilt
        mapping(uint256 => mapping(uint256 => mapping(uint256 => int128))) tilt; // mmId => marketId => positionId
        mapping(uint256 => mapping(uint256 => mapping(uint256 => Types.BlockData))) blockData; // mmId => marketId => blockId => {minId, minVal}
        mapping(uint256 => mapping(uint256 => uint256[])) topHeap; // mmId => marketId => heap array

        // Markets
        address positionToken1155;
        uint256 nextMarketId;
        uint256[] allMarkets;
        mapping(uint256 => uint256) nextPositionId;
        mapping(uint256 => uint256[]) marketPositions;

        // Permits
        address permit2; // optional, set if using Permit2

        // NEW: Synthetic Liquidity (ISC)
        mapping(uint256 => uint256) marketToDMM; // marketId => mmId (immutable)
        mapping(uint256 => uint256) syntheticCollateral; // marketId => ISC amount (immutable)
        mapping(uint256 => bool) isExpanding; // allows additional positions for expanding markets, ensures MMs solvent in "Other" position

        // NEW: Max-heap structures (symmetric to min-heap)
        mapping(uint256 => mapping(uint256 => mapping(uint256 => Types.BlockData))) blockDataMax; // mmId => marketId => blockId => {maxId, maxVal}
        mapping(uint256 => mapping(uint256 => uint256[])) topHeapMax; // mmId => marketId => heap array
        mapping(uint256 => mapping(uint256 => uint256)) heapIndexMax; // mmId => marketId => blockId => index+1 (0 = not present)

        //allowed DMM mapping
        mapping(uint256 => bool) allowedDMMs; // mmId => is allowed as DMM

        //Fee skimming
        address feeRecipient;          // where fees go
        uint16  feeBps;                // e.g. 3 = 0.03%
        bool    feeEnabled;            // on/off

    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = keccak256("MarketMakerLedger.storage");
        assembly { s.slot := position }
    }

    function encodeTokenId(uint64 marketId, uint64 positionId, bool isBack) internal pure returns (uint256) {
        return (uint256(marketId) << 64) | (uint256(positionId) << 1) | (isBack ? 1 : 0);
    }

    function decodeTokenId(uint256 tokenId) internal pure returns (Types.TokenData memory) {
        return Types.TokenData({
            marketId: uint64(tokenId >> 64),
            positionId: uint64((tokenId >> 1) & ((1 << 64) - 1)),
            isBack: (tokenId & 1) == 1
        });
    }
}
