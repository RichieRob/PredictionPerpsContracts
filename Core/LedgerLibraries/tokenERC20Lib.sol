// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./TokenTransferLib.sol";
import "./MarketManagementLib.sol";
import "./LedgerLib.sol";  // 👈 new import

library TokenERC20Lib {
    event PositionERC20Registered(
        address indexed token,
        uint256 indexed marketId,
        uint256 indexed positionId
    );

    function registerBackPositionERC20(
        address token,
        uint256 marketId,
        uint256 positionId
    ) internal {
        require(token != address(0), "TokenERC20Lib: token=0");
        require(
            MarketManagementLib.positionExists(marketId, positionId),
            "TokenERC20Lib: position !exists"
        );

        StorageLib.Storage storage s = StorageLib.getStorage();

        require(!s.erc20Registered[token], "TokenERC20Lib: already registered");

        s.erc20Registered[token] = true;
        s.erc20MarketId[token]   = marketId;
        s.erc20PositionId[token] = positionId;

        emit PositionERC20Registered(token, marketId, positionId);
    }

    function erc20PositionTransfer(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        require(amount > 0, "TokenERC20Lib: zero amount");

        StorageLib.Storage storage s = StorageLib.getStorage();
        require(msg.sender == token, "TokenERC20Lib: only token");
        require(s.erc20Registered[token], "TokenERC20Lib: unregistered token");

        uint256 marketId   = s.erc20MarketId[token];
        uint256 positionId = s.erc20PositionId[token];

        require(
            MarketManagementLib.positionExists(marketId, positionId),
            "TokenERC20Lib: position gone"
        );

        TokenTransferLib.transferPosition(
            from,
            to,
            marketId,
            positionId,
            true,   // BACK by design
            amount
        );
    }

    function getERC20PositionMeta(address token)
        internal
        view
        returns (uint256 marketId, uint256 positionId, bool registered)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        registered = s.erc20Registered[token];
        marketId   = s.erc20MarketId[token];
        positionId = s.erc20PositionId[token];
    }

    // ============================================
    // NEW: totalSupply / balanceOf for ERC20 views
    // ============================================

    /// @notice ERC20 totalSupply for any Back-position mirror:
    ///         marketValue[marketId] + syntheticCollateral[marketId].
    ///         Same for all positions in this market.
    function erc20TotalSupply(address token) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.erc20Registered[token], "TokenERC20Lib: unregistered token");

        uint256 marketId = s.erc20MarketId[token];

        uint256 mv  = s.marketValue[marketId];
        uint256 isc = s.syntheticCollateral[marketId]; // full ISC line

        return mv + isc;
    }

    /// @notice ERC20 balanceOf as "available shares" for a Back position,
    ///         clamped at 0. Includes ISC for the DMM automatically.
    function erc20BalanceOf(address token, address account)
        internal
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.erc20Registered[token], "TokenERC20Lib: unregistered token");

        uint256 marketId   = s.erc20MarketId[token];
        uint256 positionId = s.erc20PositionId[token];

        int256 avail = LedgerLib.getAvailableShares(account, marketId, positionId);

        if (avail <= 0) return 0;
        return uint256(avail);
    }
}
