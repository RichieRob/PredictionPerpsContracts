// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./5_LedgerLib.sol";

/// @title ClaimsLib
/// @notice Handles:
///  - Auto "pull pending winnings" on user actions (soft + hard mode)
///  - Explicit batch-claim flows for a given list of marketIds
///
///  CONCEPTUAL SPLIT:
///  - Per-market primitive:
///        _pullMarketWinnings(user, marketId)
///        → updates per-market state (tilt / marketValue / userMarkets/etc)
///        → returns winnings for that market
///        → does NOT touch global deltas or freeCollateral.
///  - Auto path:
///        autoPullAndCreditForShortfall(user, shortfall)
///        → repeated bounded chunks over userMarkets[user].
///  - Janitor path:
///        batchPullAndCredit(user, marketIds)
///        → only touches the explicit list of marketIds.
library ClaimsLib {
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // One "chunk" of work (used for both soft path and hard rounds)
    uint256 internal constant SOFT_MAX_SCANS    = 10;
    uint256 internal constant SOFT_MAX_RESOLVED = 4;

    // Hard route = re-running the same soft chunk up to this many times.
    // 1 soft pass + up to 19 extra rounds ≈ up to 80 resolved per call up to 200 markets scanned (in the worst case).
    uint256 internal constant HARD_MAX_ROUNDS   = 19;

    /*//////////////////////////////////////////////////////////////
                     PER-MARKET PULL (NO CREDIT)
    //////////////////////////////////////////////////////////////*/

    /// @dev Core primitive for a single market:
    ///       - If the market is resolved:
    ///           * compute user's winning exposure
    ///           * update tilt[user][marketId][winner]
    ///           * update marketValue[marketId]
    ///           * remove this market from userMarkets[user]
    ///
    ///       - DOES NOT:
    ///           * touch global aggregates (TotalMarketsValue, effectiveTotalFreeCollateralDelta)
    ///           * credit realFreeCollateral
    ///
    ///       Returns: winnings for this market (0 if none).
    function _pullMarketWinnings(address user, uint256 marketId)
        internal
        returns (uint256 winnings)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Not resolved → nothing to do
        if (!s.marketResolved[marketId]) return 0;

        uint256 winner   = s.winningPositionId[marketId];
        int256  exposure = LedgerLib.getCreatedShares(user, marketId, winner);

        // Only positive exposure pays out & touches market-level accounting
        if (exposure > 0) {
            winnings = uint256(exposure);

            // 1) Remove winning exposure so it can't be claimed again
            s.tilt[user][marketId][winner] -= exposure;

            // 2) Update market-level accounting (this market only)
            require(
                s.marketValue[marketId] >= winnings,
                "Resolution: insufficient market value"
            );
            s.marketValue[marketId] -= winnings;
        }

        // 3) ALWAYS swap-remove this resolved market from user's list (if present),
        //    regardless of win or loss. Once processed, it's never scanned again.
        uint256 rawIdx = s.userMarketIndex[user][marketId];
        if (rawIdx != 0) {
            uint256 idx     = rawIdx - 1;
            uint256 lastIdx = s.userMarkets[user].length - 1;

            if (idx != lastIdx) {
                uint256 lastMarket = s.userMarkets[user][lastIdx];
                s.userMarkets[user][idx] = lastMarket;
                s.userMarketIndex[user][lastMarket] = idx + 1;
            }

            s.userMarkets[user].pop();
            s.userMarketIndex[user][marketId] = 0;
        }

        // Note: NO global deltas, NO freeCollateral here.
        return winnings;
    }

    /*//////////////////////////////////////////////////////////////
                     SOFT CHUNK (BOUNDED WORK)
    //////////////////////////////////////////////////////////////*/

    /// @dev One bounded "chunk" of auto-claim work for a single user:
    ///      - Scans up to SOFT_MAX_SCANS entries in userMarkets[user]
    ///      - Processes up to SOFT_MAX_RESOLVED resolved markets
    ///      - Applies global accounting for that chunk
    ///
    ///      Returns winnings realised in this chunk (no credit yet).
    function _pullSoftChunkPendingWinnings(address user)
        internal
        returns (uint256 chunkWinnings)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage markets = s.userMarkets[user];

        if (markets.length == 0) {
            return 0;
        }

        uint256 scans    = 0;
        uint256 resolved = 0;
        uint256 i        = 0;

        while (
            i < markets.length &&
            scans < SOFT_MAX_SCANS &&
            resolved < SOFT_MAX_RESOLVED
        ) {
            uint256 marketId = markets[i];
            scans++;

            if (s.marketResolved[marketId]) {
                uint256 w = _pullMarketWinnings(user, marketId);
                if (w > 0) {
                    chunkWinnings += w;
                }
                resolved++;
                // _pullMarketWinnings may swap-remove markets[i], so don't ++i here.
            } else {
                unchecked { ++i; }
            }
        }

        if (chunkWinnings > 0) {
            // Apply global aggregates once for this chunk:
            //   TotalMarketsValue                 -= chunkWinnings
            //   effectiveTotalFreeCollateralDelta -= chunkWinnings
            require(
                s.effectiveTotalFreeCollateralDelta >= chunkWinnings,
                "Resolution: delta underflow"
            );
            s.effectiveTotalFreeCollateralDelta -= chunkWinnings;
            s.TotalMarketsValue                 -= chunkWinnings;
        }
    }

    /*//////////////////////////////////////////////////////////////
       AUTO PATH: SOFT ALWAYS, HARD = REPEAT SOFT IN ROUNDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Unified helper for actions that might need extra collateral.
    ///
    ///  - SOFT chunk:
    ///      * ALWAYS runs once per call (UX hygiene).
    ///      * Uses _pullSoftChunkPendingWinnings (10 scans, 4 resolved).
    ///
    ///  - If `shortfall == 0`:
    ///      * we stop after the soft chunk.
    ///
    ///  - If `shortfall > 0`:
    ///      * if soft chunk >= shortfall → stop.
    ///      * else:
    ///           HARD route:
    ///           - up to HARD_MAX_ROUNDS additional soft-chunk passes
    ///           - after each extra round:
    ///                · credit that round’s winnings
    ///                · stop if we've covered the shortfall
    ///                · break early if the round realised 0 (no more claimable funds).
    ///
    ///  Returns total winnings credited (soft + hard).
    function autoPullAndCreditForShortfall(
        address user,
        uint256 shortfall
    ) internal returns (uint256 totalCredited) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // 1) SOFT chunk – ALWAYS run (hygiene)
        uint256 softWinnings = _pullSoftChunkPendingWinnings(user);
        if (softWinnings > 0) {
            s.realFreeCollateral[user]  += softWinnings;
            s.realTotalFreeCollateral   += softWinnings;
        }

        totalCredited = softWinnings;

        // No shortfall? Just hygiene.
        if (shortfall == 0) {
            return totalCredited;
        }

        // Soft covered it? Done.
        if (softWinnings >= shortfall) {
            return totalCredited;
        }

        // 2) HARD route – re-run same soft chunk up to HARD_MAX_ROUNDS times.
        for (uint256 round = 0; round < HARD_MAX_ROUNDS; ++round) {
            uint256 roundWinnings = _pullSoftChunkPendingWinnings(user);

            if (roundWinnings == 0) {
                // No more claimable stuff where we're currently scanning.
                break;
            }

            s.realFreeCollateral[user]  += roundWinnings;
            s.realTotalFreeCollateral   += roundWinnings;
            totalCredited               += roundWinnings;

            if (totalCredited >= shortfall) {
                // We've now covered the requested shortfall.
                break;
            }
        }

        return totalCredited;
    }

    /*//////////////////////////////////////////////////////////////
                 JANITOR / EXPLICIT CLEANUP (BY IDS)
    //////////////////////////////////////////////////////////////*/

    /// @dev UX-facing janitor: "claim these marketIds" for this user.
    ///
    ///      Behaviour:
    ///        - Loops the provided `marketIds` only (does NOT sweep userMarkets[user])
    ///        - For each:
    ///             · _pullMarketWinnings(user, marketId)
    ///        - Applies global accounting once on totalWinnings
    ///        - Credits winnings into freeCollateral.
    function batchPullAndCredit(
        address user,
        uint256[] calldata marketIds
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 totalWinnings = 0;

        // 1) Per-market pulls (no globals, no credit)
        for (uint256 i = 0; i < marketIds.length; ++i) {
            totalWinnings += _pullMarketWinnings(user, marketIds[i]);
        }

        if (totalWinnings == 0) {
            return;
        }

        // 2) Global accounting for this batch
        require(
            s.effectiveTotalFreeCollateralDelta >= totalWinnings,
            "Resolution: delta underflow"
        );
        s.effectiveTotalFreeCollateralDelta -= totalWinnings;
        s.TotalMarketsValue                 -= totalWinnings;

        // 3) Credit winnings to the user
        s.realFreeCollateral[user]  += totalWinnings;
        s.realTotalFreeCollateral   += totalWinnings;
    }


    //NEW FUNCTION TO SHORTCUT REPEATED ROUTINE

       function ensureFreeCollateralFor(
        address user,
        uint256 required
    ) internal returns (uint256 newBalance) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        uint256 cur = s.realFreeCollateral[user];
        uint256 shortfall = 0;

        if (required > cur) {
            shortfall = required - cur;
        }

        // This does:
        //  - one soft chunk always (hygiene)
        //  - extra rounds if shortfall > 0 and there is claimable value
        autoPullAndCreditForShortfall(user, shortfall);

        // Reload after credit
        newBalance = s.realFreeCollateral[user];
    }
}
