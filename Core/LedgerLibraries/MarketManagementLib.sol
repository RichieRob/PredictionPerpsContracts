// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./Types.sol";
import "../../Interfaces/IPositionToken1155.sol";

library MarketManagementLib {
    event MarketCreated(uint256 indexed marketId, string name, string ticker);
    event PositionCreated(uint256 indexed marketId, uint256 indexed positionId, string name, string ticker);
    event SyntheticLiquidityCreated(uint256 indexed marketId, uint256 amount, uint256 dmmId);
    event MarketLocked(uint256 indexed marketId);

    // -------------------------------------------------------------
    //  CREATE MARKET / POSITION
    // -------------------------------------------------------------
    function createMarket(
        string memory name,
        string memory ticker,
        uint256 dmmId,
        uint256 iscAmount
    ) internal returns (uint256 marketId) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.allowedDMMs[dmmId], "DMM not allowed");
        marketId = s.nextMarketId++;
        s.allMarkets.push(marketId);

        IPositionToken1155(s.positionToken1155).setMarketMetadata(marketId, name, ticker);
        s.marketToDMM[marketId] = dmmId;
        s.syntheticCollateral[marketId] = iscAmount;

        emit MarketCreated(marketId, name, ticker);
        emit SyntheticLiquidityCreated(marketId, iscAmount, dmmId);

        // By default, allow position expansion at creation
        s.isExpanding[marketId] = true;
    }

    function createPosition(
        uint256 marketId,
        string memory name,
        string memory ticker
    ) internal returns (uint256 positionId) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.isExpanding[marketId], "Market locked");
        require(s.positionToken1155 != address(0), "Position token not set");

        positionId = s.nextPositionId[marketId]++;
        s.marketPositions[marketId].push(positionId);

        uint256 backTokenId = StorageLib.encodeTokenId(uint64(marketId), uint64(positionId), true);
        uint256 layTokenId  = StorageLib.encodeTokenId(uint64(marketId), uint64(positionId), false);

        IPositionToken1155(s.positionToken1155).setPositionMetadata(backTokenId, name, ticker, true);
        IPositionToken1155(s.positionToken1155).setPositionMetadata(layTokenId, name, ticker, false);

        emit PositionCreated(marketId, positionId, name, ticker);
    }

    function lockMarketPositions(uint256 marketId) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.isExpanding[marketId], "Already locked");
        s.isExpanding[marketId] = false;
        emit MarketLocked(marketId);
    }

    // -------------------------------------------------------------
    //  VIEWS
    // -------------------------------------------------------------
    function getMarketPositions(uint256 marketId)
        internal
        view
        returns (uint256[] memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.marketPositions[marketId];
    }

    function getMarkets()
        internal
        view
        returns (uint256[] memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.allMarkets;
    }

    function isDMM(uint256 mmId, uint256 marketId)
        internal
        view
        returns (bool)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.marketToDMM[marketId] == mmId;
    }

    // -------------------------------------------------------------
    //  🆕 POSITION EXISTENCE CHECK
    // -------------------------------------------------------------
    /// @notice Checks if a positionId is registered under a given marketId.
    /// @dev Loops through s.marketPositions[marketId]; O(n), but fine for view checks.
    function positionExists(uint256 marketId, uint256 positionId)
        internal
        view
        returns (bool)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage positions = s.marketPositions[marketId];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i] == positionId) return true;
        }
        return false;
    }
}

