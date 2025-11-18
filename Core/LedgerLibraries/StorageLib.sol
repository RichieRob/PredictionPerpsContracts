
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

        // --- Collateral & Accounting ---

        // Free collateral (per MM): unallocated USDC available to a marketmaker for new trades or withdrawl.
        // Increased on deposit, decreased on allocation. Mirrors totalFreeCollateral.
        mapping(uint256 => uint256) freeCollateral; // mmId => amount

        // Net USDC movement between each MM and each market.
        // Positive = capital spent on market; negative = profit from market
        mapping(uint256 => mapping(uint256 => int256)) USDCSpent; // mmId => marketId => int256

       

        // Net Lay token flow for each MM in each market.
        // Positive = more Lay issued than received; negative = more Lay redeemed than issued.
        mapping(uint256 => mapping(uint256 => int256)) layOffset; // mmId => marketId => int256

        // Total real USDC spent into each market (sum of all MMs).
        mapping(uint256 => uint256) MarketUSDCSpent; // marketId => total allocated

        // Total sets redeemed (burned) per market. Equal to the amount of USDC taken out of a market through redemptions.
        mapping(uint256 => uint256) Redemptions; // marketId => total redeemed

        // Market's current value in USDC (capital allocated and still active).  This is effectively MarketUSDCSpent - Redemptions, but currently its updated in parallel rather enforced
        mapping(uint256 => uint256) marketValue; // marketId => current market value

        // Global total across all markets (Σ marketValue[marketId]).
        // Increases when MMs allocate, decreases when they deallocate or redeem.
        uint256 TotalMarketsValue;

        // Global free collateral across all MMs (Σ freeCollateral[mmId]).
        // Increases on deposits and deallocations, decreases on allocations and withdrawals.
        uint256 totalFreeCollateral;

        // Total principal actually held in Aave (baseline TVL, excluding interest).
        // Used as reference when skimming yield: interest = aUSDC.balanceOf(this) - totalValueLocked.
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
