// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./Types.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./ERC20BridgeLib.sol"; // 👈 add this



library MarketManagementLib {

    using Clones for address;

    event MarketCreated(uint256 indexed marketId, string name, string ticker);
    event PositionCreated(uint256 indexed marketId, uint256 indexed positionId, address token, string name, string ticker);
    event SyntheticLiquidityCreated(uint256 indexed marketId, uint256 amount, address dmm);
    event MarketLocked(uint256 indexed marketId);

    // -------------------------------------------------------------
    //  CREATE MARKET / POSITION
    // -------------------------------------------------------------
    function createMarket(
    string memory name,
    string memory ticker,
    address dmm,
    uint256 iscAmount
) internal returns (uint256 marketId) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(s.allowedDMMs[dmm], "DMM not allowed");

    marketId = s.nextMarketId++;
    s.allMarkets.push(marketId);

    // ✅ use our own metadata
    s.marketNames[marketId]   = name;
    s.marketTickers[marketId] = ticker;

    s.marketToDMM[marketId] = dmm;
    s.syntheticCollateral[marketId] = iscAmount;

    emit MarketCreated(marketId, name, ticker);
    emit SyntheticLiquidityCreated(marketId, iscAmount, dmm);

    s.isExpanding[marketId] = true;
}


   function createPosition(
        uint256 marketId,
        string memory name,
        string memory ticker
    )
        internal
        returns (uint256 positionId, address token)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        require(s.isExpanding[marketId], "Market locked");

        // 1. Allocate new positionId
        positionId = s.nextPositionId[marketId]++;
        s.marketPositions[marketId].push(positionId);

        // 2. Store meta centrally
        s.positionNames[marketId][positionId]   = name;
        s.positionTickers[marketId][positionId] = ticker;

        // 3. Clone the shared ERC20 implementation
        address impl = s.positionERC20Implementation;
        require(impl != address(0), "ERC20 impl not set");

        token = impl.clone(); // EIP-1167 minimal proxy

        // 4. Register with ERC20 mapping (Back-only)
        ERC20BridgeLib.registerBackPositionERC20(token, marketId, positionId);

        emit PositionCreated(marketId, positionId, token, name, ticker);
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

    function isDMM(address account, uint256 marketId)
        internal
        view
        returns (bool)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.marketToDMM[marketId] == account;
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

