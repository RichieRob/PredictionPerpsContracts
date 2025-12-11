// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";

/// @title ERC20NamingLib
/// @notice Centralised logic for ERC20 names/symbols for Back/Lay mirrors.
library ERC20NamingLib {
    using StorageLib for StorageLib.Storage;

    // ------------------------------------------------------------
    // Base helpers (no Back/Lay prefix)
    // ------------------------------------------------------------

    function baseName(uint256 marketId, uint256 positionId)
        internal
        view
        returns (string memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        string memory marketName   = s.marketNames[marketId];
        string memory positionName = s.positionNames[marketId][positionId];

        return string.concat(positionName, " in ", marketName);
    }

    function baseSymbol(uint256 marketId, uint256 positionId)
        internal
        view
        returns (string memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        string memory marketTicker   = s.marketTickers[marketId];
        string memory positionTicker = s.positionTickers[marketId][positionId];

        // e.g. "YES-ELEC25"
        return string.concat(positionTicker, "-", marketTicker);
    }

    // ------------------------------------------------------------
    // With Back / Lay prefix (by ids)
    // ------------------------------------------------------------

    function nameForSide(
        uint256 marketId,
        uint256 positionId,
        bool    isBack
    ) internal view returns (string memory) {
        string memory base = baseName(marketId, positionId);
        return isBack
            ? string.concat("Back ", base)
            : string.concat("Lay ", base);
    }

    function symbolForSide(
        uint256 marketId,
        uint256 positionId,
        bool    isBack
    ) internal view returns (string memory) {
        string memory base = baseSymbol(marketId, positionId);
        return isBack
            ? string.concat("B-", base)
            : string.concat("L-", base);
    }

    // ------------------------------------------------------------
    // Look up by ERC20 token address
    // ------------------------------------------------------------

    function nameByToken(address token)
        internal
        view
        returns (string memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        if (!s.erc20Registered[token]) {
            return "Unregistered Position";
        }

        uint256 marketId   = s.erc20MarketId[token];
        uint256 positionId = s.erc20PositionId[token];
        bool    isBack     = s.erc20IsBack[token];

        return nameForSide(marketId, positionId, isBack);
    }

    function symbolByToken(address token)
        internal
        view
        returns (string memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        if (!s.erc20Registered[token]) {
            return "UNREG";
        }

        uint256 marketId   = s.erc20MarketId[token];
        uint256 positionId = s.erc20PositionId[token];
        bool    isBack     = s.erc20IsBack[token];

        return symbolForSide(marketId, positionId, isBack);
    }
}
