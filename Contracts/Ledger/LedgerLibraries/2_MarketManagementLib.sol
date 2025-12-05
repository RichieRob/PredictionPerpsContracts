// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./0_Types.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/// @title MarketManagementLib
/// @notice Deploys markets & creates *two* ERC20 position tokens per outcome:
///         - Back ERC20 mirror
///         - Lay ERC20 mirror
///
/// NOTE: This library ONLY clones ERC20 implementations. It does NOT register
///       them. Ledger must call:
///          ERC20BridgeLib.registerBackPositionERC20(...)
///          ERC20BridgeLib.registerLayPositionERC20(...)
///
/// This keeps ERC20s dumb and all logic inside Ledger.
library MarketManagementLib {
    using Clones for address;

    event MarketCreated(uint256 indexed marketId, string name, string ticker);
    event PositionCreated(
        uint256 indexed marketId,
        uint256 indexed positionId,
        address backToken,
        address layToken,
        string name,
        string ticker
    );
    event SyntheticLiquidityCreated(uint256 indexed marketId, uint256 amount, address dmm);
    event MarketLocked(uint256 indexed marketId);

    // -------------------------------------------------------------
    //  CREATE MARKET
    // -------------------------------------------------------------
    function createMarket(
        string memory name,
        string memory ticker,
        address dmm,
        uint256 iscAmount,
        bool doesResolve,
        address oracle,
        bytes calldata oracleParams
    ) internal returns (uint256 marketId) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        if (doesResolve) {
            require(dmm == address(0), "Resolving cannot use DMM");
            require(iscAmount == 0, "Resolving cannot mint ISC");
            require(oracle != address(0), "Resolving requires oracle");
        } else {
            require(s.allowedDMMs[dmm], "DMM not allowed");
            require(oracle == address(0), "Non-resolving cannot have oracle");
            require(oracleParams.length == 0, "Oracle params must be empty");
        }

        marketId = s.nextMarketId++;
        s.allMarkets.push(marketId);

        s.marketNames[marketId]   = name;
        s.marketTickers[marketId] = ticker;

        s.marketToDMM[marketId]       = dmm;
        s.syntheticCollateral[marketId] = iscAmount;
        s.doesResolve[marketId]       = doesResolve;
        s.marketOracle[marketId]      = oracle;
        s.marketOracleParams[marketId] = oracleParams;

        s.isExpanding[marketId] = true;

        emit MarketCreated(marketId, name, ticker);
        emit SyntheticLiquidityCreated(marketId, iscAmount, dmm);
    }

    // -------------------------------------------------------------
    //  CREATE POSITION (Back + Lay token clones)
    // -------------------------------------------------------------
    function createPosition(
        uint256 marketId,
        string memory name,
        string memory ticker
    )
        internal
        returns (
            uint256 positionId,
            address backToken,
            address layToken
        )
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.isExpanding[marketId], "Market locked");

        positionId = s.nextPositionId[marketId]++;
        s.marketPositions[marketId].push(positionId);

        s.positionNames[marketId][positionId]   = name;
        s.positionTickers[marketId][positionId] = ticker;

        address impl = s.positionERC20Implementation;
        require(impl != address(0), "ERC20 impl missing");

        // TWO clones here
        backToken = impl.clone();
        layToken  = impl.clone();

        emit PositionCreated(
            marketId,
            positionId,
            backToken,
            layToken,
            name,
            ticker
        );
    }

    // -------------------------------------------------------------
    //  CREATE MULTIPLE POSITIONS
    // -------------------------------------------------------------
    function createPositions(
        uint256 marketId,
        Types.PositionMeta[] memory positions
    )
        internal
        returns (
            uint256[] memory positionIds,
            address[] memory backTokens,
            address[] memory layTokens
        )
    {
        require(positions.length > 0, "No positions");

        positionIds = new uint256[](positions.length);
        backTokens  = new address[](positions.length);
        layTokens   = new address[](positions.length);

        for (uint256 i; i < positions.length; i++) {
            (
                uint256 pid,
                address backToken,
                address layToken
            ) = createPosition(marketId, positions[i].name, positions[i].ticker);

            positionIds[i] = pid;
            backTokens[i]  = backToken;
            layTokens[i]   = layToken;
        }
    }

    // -------------------------------------------------------------
    //  LOCK MARKET
    // -------------------------------------------------------------
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
        return StorageLib.getStorage().marketPositions[marketId];
    }

    function getMarkets()
        internal
        view
        returns (uint256[] memory)
    {
        return StorageLib.getStorage().allMarkets;
    }

    function isDMM(address account, uint256 marketId)
        internal
        view
        returns (bool)
    {
        return StorageLib.getStorage().marketToDMM[marketId] == account;
    }

    function positionExists(uint256 marketId, uint256 positionId)
        internal
        view
        returns (bool)
    {
        return positionId < StorageLib.getStorage().nextPositionId[marketId];
    }
}
