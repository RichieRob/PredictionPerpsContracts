// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LMSRStorageLib.sol";

/// @title LMSRTwapO1Lib
/// @notice O(1) TWAP tracker for LMSR markets (price × time accumulator).
/// @dev Works purely on LMSRStorageLib.State so the main contract just
///      forwards calls with tiny wrappers.
library LMSRTwapLib {
    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                          INTERNAL SLOT HELPER
    //////////////////////////////////////////////////////////////*/

    function _requireListed(
        LMSRStorageLib.Market storage m,
        uint256               ledgerPositionId
    ) private view returns (uint256 slot) {
        uint256 v = m.slotOf[ledgerPositionId]; // 1-based (0 = not listed)
        require(v != 0, "LMSR: not listed");
        slot = v - 1;
    }

    /*//////////////////////////////////////////////////////////////
                         BEFORE PRICE CHANGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Called before any price mutation (trade / split / list)
    ///      to advance the global clock and settle this slot’s accumulator.
    function updateBeforePriceChange(
        LMSRStorageLib.State storage s,
        uint256               marketId,
        uint256               slot
    ) internal {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");

        uint32 last  = m.twapLastTs;
        uint32 nowTs = uint32(block.timestamp);

        if (last == 0) {
            // First-ever TWAP update for this market
            m.twapLastTs         = nowTs;
            m.twapJ_slot[slot]   = m.twapJ;
            return;
        }

        uint256 J = m.twapJ;

        if (nowTs > last && m.S > 0) {
            uint256 S = uint256(m.S);
            // dJ has units (seconds / S) in 1e18 scale
            uint256 dJ = (uint256(nowTs - last) * WAD) / S;
            J += dJ;
            m.twapJ      = J;
            m.twapLastTs = nowTs;
        }

        // Lazy per-slot settlement
        uint256 Ji = m.twapJ_slot[slot];
        if (J != Ji) {
            int256 Ri = m.R[slot];
            if (Ri > 0) {
                uint256 add = (uint256(Ri) * (J - Ji)) / WAD;
                m.twapCum[slot] += add;
            }
            m.twapJ_slot[slot] = J;
        }
    }

    /*//////////////////////////////////////////////////////////////
                         AFTER PRICE CHANGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Called immediately after price mutation to set new anchor
    ///      for the updated price level.
    function updateAfterPriceChange(
        LMSRStorageLib.State storage s,
        uint256               marketId,
        uint256               slot
    ) internal {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");

        uint256 J = m.twapJ;
        m.twapJ_slot[slot] = J;
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current cumulative (price × seconds) for a position, plus timestamp.
    /// @dev This is what off-chain callers sample to compute TWAP between
    ///      two checkpoints: (cum1 - cum0) / (t1 - t0).
    function currentCumulative(
        LMSRStorageLib.State storage s,
        uint256               marketId,
        uint256               ledgerPositionId
    ) internal view returns (uint256 cumulativeWadSeconds, uint32 timestamp) {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");

        uint256 slot = _requireListed(m, ledgerPositionId);

        uint32 last  = m.twapLastTs;
        uint32 nowTs = uint32(block.timestamp);

        uint256 Jnow = m.twapJ;
        if (nowTs > last && m.S > 0) {
            uint256 S  = uint256(m.S);
            uint256 dJ = (uint256(nowTs - last) * WAD) / S;
            Jnow += dJ;
        }

        uint256 Ci = m.twapCum[slot];
        uint256 Ji = m.twapJ_slot[slot];
        int256  Ri = m.R[slot];

        if (Jnow > Ji && Ri > 0) {
            Ci += (uint256(Ri) * (Jnow - Ji)) / WAD;
        }

        return (Ci, nowTs);
    }

    /// @notice Pure helper to compute TWAP between two checkpoints.
    function consultFromCheckpoints(
        uint256 cumStart,
        uint32  tStart,
        uint256 cumEnd,
        uint32  tEnd
    ) internal pure returns (uint256 avgPriceWad) {
        require(tEnd > tStart, "LMSR: bad TWAP window");
        avgPriceWad = (cumEnd - cumStart) / uint256(tEnd - tStart);
    }
}
