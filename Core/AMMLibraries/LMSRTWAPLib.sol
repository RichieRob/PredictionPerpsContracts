// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LMSRTwapO1Lib
/// @notice O(1) time-weighted average price (TWAP) accumulator for LMSR markets.
///
/// @dev
/// This library maintains a running **sum of price × Δt** for each position,
/// allowing any off-chain system to calculate a time-weighted average price (TWAP)
/// using only two snapshots. The updates are fully O(1): constant gas regardless
/// of the number of outcomes in the market.
///
/// The update sequence has two steps:
///   1️⃣ `updateBeforePriceChange` — called **before** a price mutation (e.g. a trade)
///       to accumulate elapsed time into the global and per-slot sums.
///   2️⃣ `updateAfterPriceChange` — called **after** the O(1) price update to
///       set new baselines for that slot and the global timer.
///
/// ---
///
/// ### How It Works
///
/// Each market stores:
/// - `twapCum[marketId][slot]` — total ∑(price × Δt)
/// - `twapJ[marketId]`         — global elapsed-time anchor
/// - `twapJ_slot[marketId][slot]` — per-slot offset (time at last sync)
/// - `twapLastTs[marketId]`    — last timestamp of global update
///
/// On every trade:
/// - Global clock advances by `(now − lastTs)`
/// - Each affected slot’s cumulative sum increments by its price × Δt
///
/// Because the global time anchor is shared, this update costs constant gas
/// and does not depend on the number of listed positions.
///
/// ---
///
/// ### Off-Chain TWAP Calculation
///
/// On-chain, only the **current cumulative values** are stored.
/// Off-chain systems (e.g. indexers or UIs) compute the TWAP between any
/// two timestamps as:
///
/// ```text
/// TWAP = (cum1 − cum0) / (ts1 − ts0)
/// ```
///
/// where `(cumX, tsX)` are successive samples read from
/// `LMSRTwapO1Lib.currentCumulative(...)`.
///
/// ---
///
/// ### Complexity
/// - Update cost: **O(1)**
/// - Storage per slot: **3 words**
/// - Storage per market: **2 words**
///
/// This approach provides perpetual, time-weighted pricing for any LMSR market
/// with no history arrays or per-trade snapshots.
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRTwapO1Lib
/// @notice O(1) TWAP tracker for LMSR markets
library LMSRTwapO1Lib {
    /*//////////////////////////////////////////////////////////////
                               BEFORE PRICE CHANGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Called before any price mutation (buy/sell/list/split)
    ///      Accrues global TWAP integral and settles the current slot’s accumulator.
    function updateBeforePriceChange(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 slot
    ) internal {
        // --- Accrue global TWAP integral ---
        uint32 last = self.twapLastTs[marketId];
        uint32 nowTs = uint32(block.timestamp);
        if (last == 0) {
            // first-ever call for this market
            self.twapLastTs[marketId] = nowTs;
            self.twapJ_slot[marketId][slot] = self.twapJ[marketId];
            return;
        }

        uint256 J = self.twapJ[marketId];
        if (nowTs > last) {
            int256 denom = LMSRHelpersLib.denom(self, marketId); // 1e18
            uint256 dJ = uint256((int256(uint256(nowTs - last)) * int256(1e18)) / denom);
            J += dJ;
            self.twapJ[marketId] = J;
            self.twapLastTs[marketId] = nowTs;
        }

        // --- Lazy per-slot settlement ---
        uint256 Ji = self.twapJ_slot[marketId][slot];
        if (J != Ji) {
            int256 Ri = self.R[marketId][slot];
            if (Ri > 0) {
                uint256 add = (uint256(int256(Ri)) * (J - Ji)) / 1e18;
                self.twapCum[marketId][slot] += add;
            }
            self.twapJ_slot[marketId][slot] = J;
        }
    }

    /*//////////////////////////////////////////////////////////////
                               AFTER PRICE CHANGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Called immediately after a price mutation (trade or split).
    ///      This updates the slot’s anchor for the new price level.
    function updateAfterPriceChange(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 slot
    ) internal {
        uint256 J = self.twapJ[marketId];
        self.twapJ_slot[marketId][slot] = J;
    }

    /*//////////////////////////////////////////////////////////////
                                    VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice View cumulative (1e18*seconds) up to now.
    function currentCumulative(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId
    ) internal view returns (uint256 cumulativeWadSeconds, uint32 timestamp) {
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        uint32 last = self.twapLastTs[marketId];
        uint32 nowTs = uint32(block.timestamp);
        uint256 Jnow = self.twapJ[marketId];
        if (nowTs > last) {
            int256 denom = LMSRHelpersLib.denom(self, marketId);
            uint256 dJ = uint256((int256(uint256(nowTs - last)) * int256(1e18)) / denom);
            Jnow += dJ;
        }

        uint256 Ci = self.twapCum[marketId][slot];
        uint256 Ji = self.twapJ_slot[marketId][slot];
        int256 Ri = self.R[marketId][slot];
        if (Jnow > Ji && Ri > 0) {
            Ci += (uint256(int256(Ri)) * (Jnow - Ji)) / 1e18;
        }
        return (Ci, nowTs);
    }

    /// @notice Compute TWAP between two checkpoints.
    function consultFromCheckpoints(
        uint256 cumStart,
        uint32 tStart,
        uint256 cumEnd,
        uint32 tEnd
    ) internal pure returns (uint256 avgPriceWad) {
        require(tEnd > tStart, "twap: bad window");
        avgPriceWad = (cumEnd - cumStart) / uint256(tEnd - tStart);
    }
}
