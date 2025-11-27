// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LMSRStorageLib.sol";
import "./LMSRMathLib.sol";
import "./ILedgerPositions.sol";

/// @title LMSRInitLib
/// @notice Market initialisation for LMSR (no expansion logic here).
/// @dev All heavy init logic is here; the main contract should only call this
///      from a small wrapper function.
library LMSRInitLib {
    uint256 internal constant WAD            = 1e18;
    int256  internal constant DUST_TOLERANCE = 1e10; // ~1e-8% tolerance

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionListed(
        uint256 indexed ledgerPositionId,
        uint256 slot,
        int256  priorR
    );

    /*//////////////////////////////////////////////////////////////
                            INPUT STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct InitialPosition {
        uint256 positionId;
        int256  r; // caller scale; positive; will be normalised
    }

    /*//////////////////////////////////////////////////////////////
                           MARKET INITIALISATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialise a new LMSR market (once per marketId).
    /// @param s                Global LMSR state.
    /// @param ledger           Ledger interface (for position existence checks).
    /// @param marketId         Market identifier shared with the ledger.
    /// @param initialPositions Array of {positionId, r} priors.
    /// @param liabilityUSDC    Max AMM liability in raw USDC (1e6).
    /// @param reserve0         Initial reserve mass (caller-scale; usually 1e18).
    /// @param isExpanding      Whether the market can split from reserve later.
    function initMarket(
        LMSRStorageLib.State storage s,
        ILedgerPositions      ledger,
        uint256               marketId,
        InitialPosition[] memory initialPositions,
        uint256               liabilityUSDC,
        int256                reserve0,
        bool                  isExpanding
    ) internal {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);

        require(!m.initialized, "LMSR: already initialized");

        // We’ll refer to length directly to avoid an extra local.
        require(initialPositions.length >= 1 && initialPositions.length <= 4096, "LMSR: bad n");

        // Store liability (upscaled) and compute depth b.
        m.maxLiabilityUpscaled = int256(uint256(liabilityUSDC)) * int256(WAD);

        uint256 effectiveN = isExpanding ? initialPositions.length + 1 : initialPositions.length;
        m.b = _calculateB(liabilityUSDC, effectiveN);
        require(m.b > 0, "LMSR: invalid b");

        // Neutral G
        m.G = int256(WAD);

        // Normalise priors + reserve to sum to 1e18 with dust tolerance (in-place)
        int256 reserveScaled =
            _normalizeToWadTotal(initialPositions, reserve0, isExpanding);

        int256 sumTradables = 0;

        // Store listings and priors
        for (uint256 i = 0; i < initialPositions.length; i++) {
            InitialPosition memory ip = initialPositions[i];
            uint256 posId = ip.positionId;

            // Check the ledger actually knows this position.
            require(
                ledger.positionExists(marketId, posId),
                "LMSR: ledger position !exists"
            );

            // Prevent duplicate mapping.
            require(m.slotOf[posId] == 0, "LMSR: duplicate id");

            int256 ri = ip.r;
            m.R[i] = ri;
            sumTradables += ri;

            m.slotOf[posId]     = i + 1; // 1-based
            m.ledgerIdOfSlot[i] = posId;

            emit PositionListed(posId, i, ri);
        }

        m.S           = sumTradables + reserveScaled;
        m.R_reserve   = reserveScaled;
        m.numOutcomes = initialPositions.length;
        m.isExpanding = isExpanding;
        m.initialized = true;

        require(m.S > 0, "LMSR: S=0");
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev b = (liabilityUSDC * 1e18) / ln(n)  (still ~1e6-scale as sd59x18).
    function _calculateB(
        uint256 liabilityUSDC,
        uint256 effectivePositions
    ) internal pure returns (int256 _b) {
        int256 numWad = int256(effectivePositions) * int256(WAD); // n * 1e18
        int256 lnNWad = LMSRMathLib.lnWad(numWad);                // ln(n) * 1e18
        require(lnNWad > 0, "LMSR: ln(n)<=0");

        int256 num = int256(uint256(liabilityUSDC)) * int256(WAD); // liability * 1e18
        _b = num / lnNWad;                                         // ~1e6
    }

    /// @dev Normalise priors + reserve to total 1e18; uses dust tolerance.
    /// @notice Mutates `positions` in-place; returns only reserveScaled.
    function _normalizeToWadTotal(
        InitialPosition[] memory positions,
        int256 reserve0,
        bool   isExpanding
    ) internal pure returns (int256 reserveScaled) {
        uint256 n = positions.length;
        require(n > 0, "LMSR: no positions");

        if (isExpanding) require(reserve0 > 0, "LMSR: reserve0=0 expanding");
        else require(reserve0 == 0, "LMSR: reserve0!=0 fixed");

        int256 total = reserve0;
        for (uint256 i = 0; i < n; i++) {
            require(positions[i].r > 0, "LMSR: prior<=0");
            total += positions[i].r;
        }
        require(total > 0, "LMSR: total=0");

        // Short-circuit if caller already gave us sum==1e18.
        if (total == int256(WAD)) {
            if (isExpanding) require(reserve0 > 0, "LMSR: reserve_scaled=0");
            else require(reserve0 == 0, "LMSR: reserve_scaled!=0 fixed");
            return reserve0;
        }

        int256 sumListed = 0;

        // Scale in-place
        for (uint256 i = 0; i < n; i++) {
            int256 scaled = (positions[i].r * int256(WAD)) / total; // floor
            require(scaled > 0, "LMSR: R_scaled=0");
            positions[i].r = scaled;
            sumListed += scaled;
        }

        reserveScaled = (reserve0 * int256(WAD)) / total; // floor
        if (isExpanding) require(reserveScaled > 0, "LMSR: reserve_scaled=0");
        else require(reserveScaled == 0, "LMSR: reserve_scaled!=0 fixed");

        int256 sumTotal = sumListed + reserveScaled;
        int256 diff     = sumTotal - int256(WAD);
        if (diff < 0) diff = -diff;
        require(diff <= DUST_TOLERANCE, "LMSR: sum!=1e18 (dust)");

        return reserveScaled;
    }
}
