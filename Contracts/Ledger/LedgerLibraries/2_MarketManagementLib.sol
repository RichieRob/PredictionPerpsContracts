// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./0_Types.sol";
import "./2_FeeLib.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";

/// @title MarketManagementLib
/// @notice Handles:
///         - creating markets (including fee config)
///         - creating Back/Lay ERC20 mirrors per position
///         - locking markets from further expansion
///
/// NOTE: This library ONLY clones ERC20 implementations. It does NOT register
///       them. Ledger must call:
///          ERC20BridgeLib.registerBackPositionERC20(...)
///          ERC20BridgeLib.registerLayPositionERC20(...)
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
    //  CREATE MARKET (full: metadata + ISC + fees)
    // -------------------------------------------------------------
    /// @notice Full market creation. Permissionless; caller of the Ledger
    ///         decides who the `marketCreator` is (can be msg.sender or
    ///         some other address).
    ///
    /// @dev This:
    ///      - allocates a marketId
    ///      - stores name / ticker / oracle / ISC / DMM
    ///      - sets the market as expanding (positions can be added)
    ///      - initialises FeesConfig, including `creator`
    function createMarket(
        string memory name,
        string memory ticker,
        address dmm,
        uint256 iscAmount,
        bool    doesResolve,
        address oracle,
        bytes   calldata oracleParams,
        uint16  feeBps,
        address marketCreator,
        address[] memory feeWhitelistAccounts,
        bool    hasWhitelist
    ) internal returns (uint256 marketId) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Assign new market id
        marketId = s.allMarkets.length;
        s.allMarkets.push(marketId);

        // Basic metadata
        s.marketNames[marketId]   = name;
        s.marketTickers[marketId] = ticker;

        // DMM / synthetic collateral
        s.marketToDMM[marketId]         = dmm;
        s.syntheticCollateral[marketId] = iscAmount;

        // Resolution config
        s.doesResolve[marketId]        = doesResolve;
        s.marketOracle[marketId]       = oracle;
        s.marketOracleParams[marketId] = oracleParams;

        // Market starts in "expanding" mode so positions can be added
        s.isExpanding[marketId] = true;

        // Initialise fee config + creator + optional whitelist
        FeeLib.initMarketFees(
            marketId,
            feeBps,
            marketCreator,
            feeWhitelistAccounts,
            dmm,
            hasWhitelist
        );

        emit MarketCreated(marketId, name, ticker);

        // Informational: synthetic line for DMM, if any
        if (iscAmount > 0 && dmm != address(0)) {
            emit SyntheticLiquidityCreated(marketId, iscAmount, dmm);
        }
    }

    // -------------------------------------------------------------
    //  INTERNAL GUARD: only market creator
    // -------------------------------------------------------------
    function _onlyMarketCreator(StorageLib.Storage storage s, uint256 marketId) private view {
        address creator = s.feesConfig[marketId].creator;
        require(creator != address(0), "Market: no creator");
        require(msg.sender == creator, "Market: not creator");
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

        // Only the market creator can add positions
        _onlyMarketCreator(s, marketId);

        require(s.isExpanding[marketId], "Market locked");

        positionId = s.nextPositionId[marketId]++;
        s.marketPositions[marketId].push(positionId);

        s.positionNames[marketId][positionId]   = name;
        s.positionTickers[marketId][positionId] = ticker;

        address impl = s.positionERC20Implementation;
        require(impl != address(0), "ERC20 impl missing");

        // TWO clones here: Back + Lay mirrors
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

        // Only the market creator can lock
        _onlyMarketCreator(s, marketId);

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
