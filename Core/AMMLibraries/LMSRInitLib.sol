// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";
import "../LMSRMarketMaker.sol";

/// @title LMSRInitLib
/// @notice Library for market initialization in LMSRMarketMaker.
library LMSRInitLib {
    struct InitialPosition {
        uint256 positionId;
        int256 r;
    }

    /// @notice Internal implementation to initialize a market.
    /// @dev Sets up per-market state, listings, and priors. Validates inputs and ensures no re-initialization.
    ///      Computes b from liabilityUSDC to set market liquidity parameter.
    ///      Initializes with neutral state where prices are uniform if initialR are equal.
    function initMarketInternal(
        LMSRMarketMaker self,
        uint256 _marketId,
        InitialPosition[] memory initialPositions,
        uint256 liabilityUSDC,
        int256 reserve0,
        bool _isExpanding
    ) internal {
        require(!self.initialized[_marketId], "already initialized");
        uint256 _numInitial = initialPositions.length;
        // Ensure at least two initial positions (to avoid ln(1)=0 div-zero in b calc) and cap to prevent gas exhaustion in loop; 4096 is a safe power-of-2 limit.
        require(_numInitial >= 2 && _numInitial <= 4096, "bad n");

        int256 _b = calculateB(liabilityUSDC, _numInitial);
        self.b[_marketId] = _b;

        // Init global factor
        self.G[_marketId] = int256(LMSRMarketMaker.WAD);

        // Load priors + map listings
        // Initialize neutral state: U_all=0, u_i=0 => G=1, R_i=1, S=n
        self.R[_marketId] = new int256[](_numInitial);
        int256 sum = initializeListings(self, _marketId, initialPositions);
        self.S_tradables[_marketId] = sum;

        if (_isExpanding) {
            require(reserve0 > 0, "reserve0=0 expanding");
            self.R_reserve[_marketId] = reserve0;
        } else {
            require(reserve0 == 0, "reserve0!=0 fixed");
            self.R_reserve[_marketId] = 0;
        }

        self.numOutcomes[_marketId] = _numInitial;
        self.isExpanding[_marketId] = _isExpanding;

        self.initialized[_marketId] = true;
    }

    /// @dev Computes b from liabilityUSDC: b = liability / ln(_numInitial), scaled appropriately (both 1e6)
    ///      This sets the market's liquidity parameter such that the maximum loss is bounded by liabilityUSDC.
    function calculateB(uint256 liabilityUSDC, uint256 _numInitial) internal pure returns (int256 _b) {
        int256 numWad = int256(_numInitial) * int256(LMSRMarketMaker.WAD);
        int256 lnNWad = PRBMathSD59x18.ln(numWad);
        _b = (int256(liabilityUSDC) * int256(LMSRMarketMaker.WAD)) / lnNWad;
        require(_b > 0, "invalid b");
    }

    /// @dev Initializes listings loop: sets R, computes sum, updates mappings, emits events.
    ///      Processes each positionId-r pair, validating and mapping them to AMM slots.
    function initializeListings(
        LMSRMarketMaker self,
        uint256 _marketId,
        InitialPosition[] memory initialPositions
    ) internal returns (int256 sum) {
        uint256 _numInitial = initialPositions.length;
        for (uint256 i = 0; i < _numInitial; i++) {
            uint256 lid = initialPositions[i].positionId;
            int256 ri = initialPositions[i].r;
            require(ri > 0, "prior <= 0");
            require(self.slotOf[_marketId][lid] == 0, "dup id");

            // Strong sanity-check existence in ledger
            require(self.ledger.positionExists(_marketId, lid), "ledger: position !exists");

            self.R[_marketId][i] = ri;
            sum += ri;

            self.slotOf[_marketId][lid] = i + 1;          // store 1-based
            self.ledgerIdOfSlot[_marketId][i] = lid;

            emit LMSRMarketMaker.PositionListed(lid, i, ri);
        }
    }
}
