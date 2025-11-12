// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";
import "../LMSRMarketMaker.sol";

/// @title LMSRInitLib
/// @notice Library for market initialization in LMSRMarketMaker.
library LMSRInitLib {
    struct InitialPosition {
        uint256 positionId;
        int256 r; // caller scale; expected WAD if already normalized
    }

    int256 constant WAD = 1e18;
    int256 constant DUST_TOLERANCE = 1e10; // ~1e-8% of total — negligible

    /// @notice Internal implementation to initialize a market.
    /// @dev If inputs already sum to 1e18 (including reserve), they are stored directly (after checks).
    ///      Otherwise they are normalized to 1e18 with a dust tolerance check (no dust patching).
    function initMarketInternal(
        LMSRMarketMaker self,
        uint256 _marketId,
        InitialPosition[] memory initialPositions,
        uint256 liabilityUSDC,
        int256 reserve0,
        bool _isExpanding
    ) internal {
        require(!self.initialized[_marketId], "already initialized");

        uint256 n = initialPositions.length;
        require(n >= 1 && n <= 4096, "bad n");

        // Depth parameter b
        int256 _b = calculateB(liabilityUSDC, n);
        require(_b > 0, "invalid b");
        self.b[_marketId] = _b;

        // Neutral global factor
        self.G[_marketId] = int256(LMSRMarketMaker.WAD);

        // Normalize (auto-skip if already sum==1e18)
        (InitialPosition[] memory normalisedInitialPositions, int256 reserve_final) =
            _normalizeToWadTotal(initialPositions, reserve0, _isExpanding);

        // Store listings and priors
        self.R[_marketId] = new int256[](n);
        int256 sumTradables = 0;

        for (uint256 i = 0; i < n; i++) {
            uint256 ledger_position_id = normalisedInitialPositions[i].positionId;

            // Strong sanity-check existence in ledger
            require(self.ledger.positionExists(_marketId, ledger_position_id ), "ledger: position !exists");
            //check that we havent already mapped this ledger id to a slot
            require(self.slotOf[_marketId][ledger_position_id ] == 0, "duplicate id supplied");

            int256 ri = normalisedInitialPositions[i].r; // already WAD (or normalized)
            self.R[_marketId][i] = ri;
            sumTradables += ri;

            self.slotOf[_marketId][ledger_position_id ] = i + 1;      // 1-based (functions like a combined boolean for if the listing already has a slot)
            self.ledgerIdOfSlot[_marketId][i] = ledger_position_id ;

            emit LMSRMarketMaker.PositionListed(ledger_position_id , i, ri);
        }

        self.S_tradables[_marketId] = sumTradables;
        self.R_reserve[_marketId]   = reserve_final;

        self.numOutcomes[_marketId] = n;
        self.isExpanding[_marketId] = _isExpanding;

        self.initialized[_marketId] = true;
    }

    /// @dev Computes b from liabilityUSDC: b = liability / ln(n), handling 1e6→1e18 scaling.
    function calculateB(uint256 liabilityUSDC, uint256 _numInitial) internal pure returns (int256 _b) {
        int256 numWad = int256(_numInitial) * int256(LMSRMarketMaker.WAD);  // n in 1e18
        int256 lnNWad = PRBMathSD59x18.ln(numWad);                          // ln(n) in 1e18
        _b = (int256(liabilityUSDC) * int256(LMSRMarketMaker.WAD)) / lnNWad; // (1e6 * 1e18 / 1e18) in sd59x18
    }

    /// @dev Normalizes to total 1e18 with short-circuit and dust tolerance.
    /// - Short-circuit returns inputs unchanged if sum == 1e18 (and reserve semantics valid).
    /// - Otherwise scales each r and reserve to WAD.
    /// - Reverts if any scaled r == 0, or if expanding reserve becomes 0.
    /// - Reverts if |sum - 1e18| > DUST_TOLERANCE (no dust patching).
    function _normalizeToWadTotal(
        InitialPosition[] memory positions,
        int256 reserve0,
        bool isExpanding
        ) internal pure returns (InitialPosition[] memory out, int256 reserve_scaled) {
        uint256 n = positions.length;
        require(n > 0, "no positions");

        // Reserve semantics (pre-check)
        if (isExpanding) require(reserve0 > 0, "reserve0=0 expanding");
        else require(reserve0 == 0, "reserve0!=0 fixed");

        // Sum in caller scale
        int256 total = reserve0;
        for (uint256 i = 0; i < n; i++) {
            require(positions[i].r > 0, "prior <= 0");
            total += positions[i].r;
        }
        require(total > 0, "total=0");

        // --- Short-circuit: already normalized ---
        if (total == WAD) {
            // If expanding, reserve must be positive; else must be zero.
            if (isExpanding) require(reserve0 > 0, "reserve_scaled=0");
            else require(reserve0 == 0, "reserve_scaled!=0 fixed");
            return (positions, reserve0);
        }

        // --- Normalize to WAD ---
        out = new InitialPosition[](n);
        int256 sumListed = 0;

        for (uint256 i = 0; i < n; i++) {
            out[i].positionId = positions[i].positionId;
            int256 scaled = (positions[i].r * WAD) / total; // floor
            require(scaled > 0, "R_scaled=0");
            out[i].r = scaled;
            sumListed += scaled;
        }

        reserve_scaled = (reserve0 * WAD) / total; // floor
        if (isExpanding) require(reserve_scaled > 0, "reserve_scaled=0");
        else require(reserve_scaled == 0, "reserve_scaled!=0 fixed");

        // --- Dust check only (no patching) ---
        int256 sumTotal = sumListed + reserve_scaled;
        int256 diff = sumTotal - WAD;
        if (diff < 0) diff = -diff; // abs
        require(diff <= DUST_TOLERANCE, "sum!=1e18 (dust too large)");

        return (out, reserve_scaled);
    }


}
