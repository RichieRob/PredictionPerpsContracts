// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LMSRStorageLib
/// @notice Centralised storage layout for LMSRMarketMaker.
/// @dev
/// - The main LMSR contract should declare:
///       LMSRStorageLib.State internal _ls;
/// - All logic libraries should take `LMSRStorageLib.State storage`
///   or `LMSRStorageLib.Market storage` as arguments, never the
///   full contract type, to avoid circular imports.
library LMSRStorageLib {
    /*//////////////////////////////////////////////////////////////
                               MARKET STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-market LMSR state.
    struct Market {
        // Core LMSR parameters
        int256 b;                     // depth param (1e6-ish in sd59x18 style)
        int256 maxLiabilityUpscaled;  // liabilityUSDC * 1e18
        int256 G;                     // global factor (1e18)
        int256 S;                     // sum of R_i + R_reserve (1e18)
        int256 R_reserve;             // reserve mass ("Other") (1e18)
        uint256 numOutcomes;          // number of listed outcomes (slots 0..n-1)
        bool isExpanding;             // true if reserve can be split into new outcomes
        bool initialized;             // one-shot init guard

        // Outcome weights (R_i) and mapping between ledger ids and slots
        mapping(uint256 => int256) R;             // slot -> R_i (1e18)
        mapping(uint256 => uint256) slotOf;       // ledgerPositionId -> slot+1 (0 = unlisted)
        mapping(uint256 => uint256) ledgerIdOfSlot; // slot -> ledgerPositionId

        // TWAP data (O(1) accumulator)
        uint32  twapLastTs;           // last timestamp of TWAP global update
        uint256 twapJ;                // global J anchor (time integral scaled)
        mapping(uint256 => uint256) twapJ_slot;   // slot -> J at last sync
        mapping(uint256 => uint256) twapCum;      // slot -> ∑(price * Δt) (1e18 * seconds)
    }

    /*//////////////////////////////////////////////////////////////
                                ROOT STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Root state container held by the main contract.
    struct State {
        mapping(uint256 => Market) markets; // marketId -> Market
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESSORS / SMALL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get a mutable reference to a market.
    function market(State storage s, uint256 marketId)
        internal
        view
        returns (Market storage m)
    {
        m = s.markets[marketId];
    }

    /// @notice Require that a ledger position is listed in this market.
    /// @dev Returns the 0-based AMM slot index.
    function requireListed(
        Market storage m,
        uint256 ledgerPositionId
    ) internal view returns (uint256 slot) {
        uint256 v = m.slotOf[ledgerPositionId]; // 1-based; 0 = unlisted
        require(v != 0, "LMSR: not listed");
        slot = v - 1;
    }
}
