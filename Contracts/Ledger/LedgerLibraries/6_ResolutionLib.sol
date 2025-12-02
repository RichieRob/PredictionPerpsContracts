// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./2_FreeCollateralLib.sol";
import "./2_MarketManagementLib.sol";
import "./5_LedgerLib.sol";
import "../Interfaces/IOracle.sol";

library ResolutionLib {
    event MarketResolved(uint256 indexed marketId, uint256 winningPositionId);

    /*//////////////////////////////////////////////////////////////
                            RESOLUTION
    //////////////////////////////////////////////////////////////*/

    // ------------------------------------------------------------
    // Core resolver with ALL fundamental restrictions
    // ------------------------------------------------------------
    function _resolveMarketCore(uint256 marketId, uint256 winningPositionId)
    internal
{
    StorageLib.Storage storage s = StorageLib.getStorage();

    require(s.doesResolve[marketId], "Market does not resolve");
    require(!s.marketResolved[marketId], "Already resolved");
    require(
        MarketManagementLib.positionExists(marketId, winningPositionId),
        "Invalid winner"
    );
    require(
        s.marketToDMM[marketId] == address(0),
        "Resolving market cannot have DMM"
    );
    require(
        s.syntheticCollateral[marketId] == 0,
        "Resolving market cannot have ISC"
    );

    s.marketResolved[marketId]    = true;
    s.winningPositionId[marketId] = winningPositionId;

    // 🔢 bump global resolved counter
    s.totalResolvedMarkets += 1;

    // add the current market value to effectiveTotalFreeCollateralDelta
    uint256 mv = s.marketValue[marketId];
    if (mv > 0) {
        s.effectiveTotalFreeCollateralDelta += mv;
    }

    emit MarketResolved(marketId, winningPositionId);
}

    // ------------------------------------------------------------
    // Oracle-driven resolution
    // ------------------------------------------------------------
    function resolveFromOracle(uint256 marketId) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.doesResolve[marketId], "Market does not resolve");
        require(!s.marketResolved[marketId], "Already resolved");
        require(s.marketOracle[marketId] != address(0), "No oracle set");

        IOracle oracle = IOracle(s.marketOracle[marketId]);
        (bool isResolved, uint256 winningPositionId) =
            oracle.getResolutionData(marketId, s.marketOracleParams[marketId]);

        require(isResolved, "Oracle data not ready");

        _resolveMarketCore(marketId, winningPositionId);
    }

    /*//////////////////////////////////////////////////////////////
                         CLAIMING WINNINGS
    //////////////////////////////////////////////////////////////*/

    /// @dev Claims winnings for a single market and removes it from the user's list.
    ///      Returns the winnings amount for this market (0 if none).
    function _claimForMarket(address user, uint256 marketId)
        internal
        returns (uint256 winnings)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        if (!s.marketResolved[marketId]) return 0;

        uint256 winner = s.winningPositionId[marketId];
        int256 exposure = LedgerLib.getCreatedShares(user, marketId, winner);

        // Only positive exposure pays out
        if (exposure <= 0) {
            return 0;
        }

        winnings = uint256(exposure);

        // 1) Remove the winning exposure so it can't be claimed again
        s.tilt[user][marketId][winner] -= exposure;

        // 2) Update market-level accounting
        require(
            s.marketValue[marketId] >= winnings,
            "Resolution: insufficient market value"
        );

        s.Redemptions[marketId] += winnings;
        s.marketValue[marketId] -= winnings;
        s.TotalMarketsValue     -= winnings;

        // 3) Effective total collateral delta shrinks by the same amount
        require(
            s.effectiveTotalFreeCollateralDelta >= winnings,
            "Resolution: delta underflow"
        );
        s.effectiveTotalFreeCollateralDelta -= winnings;

        // 4) Swap-remove this market from user's list (if present)
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

        return winnings;
    }

    /// @dev Walk all markets the user has touched and realise any pending winnings.
    ///      Uses swap-remove, so we need the `while` loop pattern.
function _applyPendingWinnings(address user) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256[] storage markets = s.userMarkets[user];

    // 0) If this user has never touched a resolving market, nothing to do.
    if (markets.length == 0) {
        // Keep their marker in sync so we don't re-scan unnecessarily later.
        s.userLastResolvedSeen[user] = s.totalResolvedMarkets;
        return;
    }

    // 1) If no *new* market has resolved since we last scanned this user,
    //    we know there can't be new winnings to claim.
    if (s.userLastResolvedSeen[user] == s.totalResolvedMarkets) {
        return;
    }

    uint256 totalWinnings = 0;
    uint256 i = 0;

    while (i < markets.length) {
        uint256 marketId = markets[i];

        if (s.marketResolved[marketId]) {
            uint256 w = _claimForMarket(user, marketId);
            totalWinnings += w;
            // _claimForMarket may swap-remove markets[i], so don't ++i here.
        } else {
            unchecked { ++i; }
        }
    }

    if (totalWinnings > 0) {
        FreeCollateralLib.mintPpUSDC(user, totalWinnings);
    }

    // 2) Record that we've scanned up to the current global resolution count.
    s.userLastResolvedSeen[user] = s.totalResolvedMarkets;
}


    /// @dev Batch claim for an explicit list of markets (e.g. UI 'claim all for these').
    function _batchClaimWinnings(address user, uint256[] calldata marketIds)
        internal
    {
        uint256 totalWinnings = 0;

        for (uint256 i = 0; i < marketIds.length; ++i) {
            uint256 marketId = marketIds[i];
            totalWinnings += _claimForMarket(user, marketId);
        }

        if (totalWinnings > 0) {
            FreeCollateralLib.mintPpUSDC(user, totalWinnings);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           FREE COLLATERAL VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice "Claims-aware" free collateral view:
    ///         base minted line + unclaimed resolved winnings.
    function effectiveFreeCollateral(address account)
        internal
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 base = s.realFreeCollateral[account];
        uint256[] memory markets = s.userMarkets[account];

        for (uint256 i = 0; i < markets.length; ++i) {
            uint256 marketId = markets[i];
            if (!s.marketResolved[marketId]) continue;

            uint256 winner = s.winningPositionId[marketId];
            int256 exposure = s.tilt[account][marketId][winner];
            if (exposure > 0) {
                base += uint256(exposure);
            }
        }

        return base;
    }

    /// @notice "Raw minted line only" – ignores any unclaimed winnings.
    function realFreeCollateral(address account)
        internal
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.realFreeCollateral[account];
    }
}
