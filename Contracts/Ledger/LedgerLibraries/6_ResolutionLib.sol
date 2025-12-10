// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./2_MarketManagementLib.sol";
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
}
