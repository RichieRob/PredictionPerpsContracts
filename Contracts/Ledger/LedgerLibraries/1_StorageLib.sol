
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./0_Types.sol"; // <-- needed for BlockData and TokenData

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IPpUSDCEvents {
    function externalMint(address to, uint256 amount) external;
    function externalBurn(address from, uint256 amount) external;
}

library StorageLib {

      struct IntentState {
        uint256 filledPrimary; // how many tokens have been filled so far
        bool    cancelled;     // explicit kill switch
    }

    struct Storage {
        // Core tokens/protocols
        IERC20 usdc;
        IERC20 aUSDC;
        IAavePool aavePool;
        address owner;
        IERC20 ppUSDC;



        // --- Collateral & Accounting ---


        // Invariants (per account, per marketId):
        //
        // netUSDCAllocation(account, marketId) = USDCSpent[account][marketId]
        //                                   - redeemedUSDC[account][marketId]
        //
        // For any operation, we maintain:
        //   - USDCSpent and redeemedUSDC are MONOTONE increasing (never decrease).
        //   - freeCollateral[account] >= 0 at all times.
        //   - where H_k are the available shares the market maker has for position k
        //   - realminShares =
        //          + netUSDCAllocation(account, marketId)
        //          + layOffset[account][marketId]
        //          + tilt[account][marketId][k]
        //     and we enforce min_k realMinShares >= 0 via the heap (min-tilt) logic.

        //   - For the designated DMM in a market with ISC, effective min shares is
        // effective minshares = realminshares + syntheticCollateral[marketId]
        //     in solvency checks (see SolvencyLib / Synthetic Liquidity docs).



        
        
        // Profit and loss that a market maker makes on a specific market or otherwise is not recorded directly in the ledger.
        // Why is the profit and loss not recorded? 
        // Well In a sense it is not a meaningful quantity of the ledger, exactly how the market maker is managing it's own funds
        // is not the concern of the ledger, 
        // - the market maker may not be sending all the USDC paid by the user to to ledger
        // - the market maker may be accepting other tokens not tracked by the leger as payment


        //  - the principal concern of the ledger is solvency
        
        
        // Free collateral (per MM): unallocated USDC available to a marketmaker for new trades or withdrawl.
        // Increased on deposit, decreased on allocation. Mirrors realTotalFreeCollateral but specific to market maker.
        mapping(address => uint256) realFreeCollateral; // account => amount

        // Cumulative USDC this MM has ever allocated into this market.
        // Monotone increasing; never decreased.
        mapping(address => mapping(uint256 => uint256)) USDCSpent; // account => marketId => total allocated

        // Cumulative USDC this MM has ever deallocated / redeemed *from* this market.
        // Monotone increasing; never decreased.
        mapping(address => mapping(uint256 => uint256)) redeemedUSDC; // account => marketId => total deallocated

        // Yes this one makes sesne we are just increasing this up and down instead of touching all the individual tilts
        // Net Lay token flow for each MM in each market.
        // Positive = more Lay received than issued; negative = more Lay issued than received.
        mapping(address => mapping(uint256 => int256)) layOffset; // account => marketId => int256

        
        // Total real USDC ever allocated into each market (sum of all MMs).
        // Monotone increasing.
        mapping(uint256 => uint256) MarketUSDCSpent; // marketId => cumulative allocated

        // Total USDC ever removed from this market’s “active pot”.
        // Includes:
        //   - MM deallocations (moving capital back to freeCollateral), and
        //   - user full-set redemptions (burning complete baskets for USDC).
        // Monotone increasing.
        mapping(uint256 => uint256) Redemptions; // marketId => total “taken out of the market”

        // Current active real capital in the market:
        // marketValue[marketId] = MarketUSDCSpent[marketId] - Redemptions[marketId] (INTENTION)
        // Always kept >= 0.
        mapping(uint256 => uint256) marketValue; // marketId => current market value


         // Global sum of all marketValue[marketId].
        // Invariant: TotalMarketsValue = Σ_m marketValue[m].
        uint256 TotalMarketsValue;

        // Global free collateral across all MMs (Σ freeCollateral[account]).
        // Increases on deposits and deallocations, decreases on allocations and withdrawals.
        
        uint256 realTotalFreeCollateral;

        // Total principal actually held in Aave (baseline TVL, excluding interest).
        // Used as reference when skimming yield: interest = aUSDC.balanceOf(this) - totalValueLocked.
        uint256 totalValueLocked;

        //tilt
        mapping(address => mapping(uint256 => mapping(uint256 => int256))) tilt; // account => marketId => positionId

        // Min-heap over block minima (for solvency).
        // For each (account, marketId):
        //   - positions are grouped into blocks of 16, each BlockData stores:
        //       minId  = positionId with smallest tilt in block
        //       minVal = that smallest tilt
        //   - mintTopHeap[account][marketId][0] indexes the block with GLOBAL min tilt.
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) minHeapIndex; // account => marketId => blockId => index+1 (0 = not present)        
        mapping(address => mapping(uint256 => mapping(uint256 => Types.BlockData))) minBlockData; // account => marketId => blockId => {minId, minVal}
        mapping(address => mapping(uint256 => uint256[])) minTopHeap; // account => marketId => heap array

        // Max-heap over block maxima (for redemption constraint when ISC is active).
        // Mirrors the min-heap structure, but tracking max tilt per block.
        mapping(address => mapping(uint256 => mapping(uint256 => Types.BlockData))) blockDataMax; // account => marketId => blockId => {maxId, maxVal}
        mapping(address => mapping(uint256 => uint256[])) topHeapMax; // account => marketId => heap array
        mapping(address => mapping(uint256 => mapping(uint256 => uint256))) heapIndexMax; // account => marketId => blockId => index+1 (0 = not present)



        // Markets
        uint256 nextMarketId;
        uint256[] allMarkets;
        mapping(uint256 => uint256) nextPositionId;
        mapping(uint256 => uint256[]) marketPositions;

        // Permits
        address permit2; // optional, set if using Permit2

        // Synthetic Liquidity (ISC) configuration.
        //
        // Invariants:
        //   - If syntheticCollateral[marketId] > 0:
        //       * marketToDMM[marketId] is the ONLY account allowed to draw ISC.
        //       * allowedDMMs[marketToDMM[marketId]] == true.
        //   - syntheticCollateral[marketId] is set once at market creation and never mutated.
        //   - ISC is never transferred or withdrawn; it only appears virtually in solvency checks.
        mapping(uint256 => address) marketToDMM; // marketId => account (immutable)
        mapping(uint256 => uint256) syntheticCollateral; // marketId => ISC amount (immutable)
        mapping(uint256 => bool) isExpanding; // allows additional positions for expanding markets, ensures MMs solvent in "Other" position

        
        //allowed DMM mapping
        mapping(address => bool) allowedDMMs; // account => is allowed as DMM

        // Protocol fee configuration.
        // Invariants:
        //   - feeBps is in basis points, expected to satisfy feeBps <= 000 (100%).
        //   - If feeEnabled == false, core flows must not skim any fee.
        address feeRecipient;          // where fees go
        uint16  feeBps;                // e.g. 3 = 0.03%
        bool    feeEnabled;            // on/off


// --- Market / Position metadata (central registry) ---

// Market-level metadata
mapping(uint256 => string) marketNames;    // marketId => name
mapping(uint256 => string) marketTickers;  // marketId => ticker

// Position-level metadata (scoped by marketId)
mapping(uint256 => mapping(uint256 => string)) positionNames;   // marketId => positionId => name
mapping(uint256 => mapping(uint256 => string)) positionTickers; // marketId => positionId => ticker


    // ERC20 implementation (shared logic)
    address positionERC20Implementation;


// --- ERC20 mirrors ---
// Only BACK positions get native ERC20 wrappers.
// Lay is always purely ledger-native (tilt + layOffset) and *never* ERC20.
mapping(address => bool)    erc20Registered;  // token => has mapping
mapping(address => uint256) erc20MarketId;    // token => marketId
mapping(address => uint256) erc20PositionId;  // token => positionId

// 🔁 reverse lookup: (marketId, positionId) -> back-position ERC20 token
mapping(uint256 => mapping(uint256 => address)) positionERC20; 
// marketId => positionId => token


mapping(bytes32 => IntentState) intentStates;
// key = IntentLib.hashIntent(intent)


// For market resolution 
mapping(uint256 => bool) marketResolved; // flag resolved markets
mapping(uint256 => bool) doesResolve; // flag markets which CAN resolve
mapping(uint256 => address) marketOracle; // Oracle (only allowed for resolving markets otherwise address(0))
mapping(uint256 => bytes) marketOracleParams; // Market -> Oracle params anything info oracle might need about the market
mapping(uint256 => uint256) winningPositionId; // for resolved markets gives the position of the winning outcome
mapping(address => uint256[]) userMarkets; // The non claimed from markets that the user has touched. Array 
mapping(address => mapping (uint256 => uint256)) userMarketIndex; // position of a market in the userMarkets array  // using 1 for raw index 0

// Delta between realTotalFreeCollateral and effective total
// (which includes unclaimed winnings in resolved markets).
// Invariant:
//   effectiveTotalFreeCollateral = realTotalFreeCollateral + effectiveDelta.
//
// - On resolve(market):  effectiveDelta += marketValue[marketId].
// - On claim(winnings):  effectiveDelta -= winnings. // because the realFreeCollateral is increased

uint256 effectiveTotalFreeCollateralDelta;

    




    }

    function getStorage() internal pure returns (Storage storage s) {
        bytes32 position = keccak256("MarketMakerLedger.storage");
        assembly { s.slot := position }
    }

}
