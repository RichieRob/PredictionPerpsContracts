// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./7b_SettlementLib.sol";
import "./2_MarketManagementLib.sol";
import "./5_LedgerLib.sol";
import "./3_HeapLib.sol";

/// @title ERC20BridgeLib
/// @notice Bridges between ledger state and the PositionERC20 clones
///         for both Back and Lay mirrors.
library ERC20BridgeLib {
    event PositionERC20Registered(
        address indexed token,
        uint256 indexed marketId,
        uint256 indexed positionId,
        bool    isBack
    );

    // -------------------------------------------------------------
    // REGISTER (BACK / LAY)
    // -------------------------------------------------------------

    function _registerPositionERC20(
        address token,
        uint256 marketId,
        uint256 positionId,
        bool    isBack
    ) internal {
        require(token != address(0), "ERC20BridgeLib: token=0");
        require(
            MarketManagementLib.positionExists(marketId, positionId),
            "ERC20BridgeLib: position !exists"
        );

        StorageLib.Storage storage s = StorageLib.getStorage();

        require(!s.erc20Registered[token], "ERC20BridgeLib: already registered");

        s.erc20Registered[token] = true;
        s.erc20MarketId[token]   = marketId;
        s.erc20PositionId[token] = positionId;
        s.erc20IsBack[token]     = isBack;

        if (isBack) {
            s.positionBackERC20[marketId][positionId] = token;
        } else {
            s.positionLayERC20[marketId][positionId] = token;
        }

        emit PositionERC20Registered(token, marketId, positionId, isBack);
    }

    function registerBackPositionERC20(
        address token,
        uint256 marketId,
        uint256 positionId
    ) internal {
        _registerPositionERC20(token, marketId, positionId, true);
    }

    function registerLayPositionERC20(
        address token,
        uint256 marketId,
        uint256 positionId
    ) internal {
        _registerPositionERC20(token, marketId, positionId, false);
    }

    // -------------------------------------------------------------
    // TRANSFER VIA ERC20 MIRRORS
    // -------------------------------------------------------------

    function erc20PositionTransfer(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        require(amount > 0, "ERC20BridgeLib: zero amount");
        require(to != address(0), "ERC20BridgeLib: to=0");
        if (from == to) return; // no-op, matches ERC20 semantics

        StorageLib.Storage storage s = StorageLib.getStorage();

        require(msg.sender == token, "ERC20BridgeLib: only token");
        require(s.erc20Registered[token], "ERC20BridgeLib: unregistered token");

        uint256 marketId   = s.erc20MarketId[token];
        uint256 positionId = s.erc20PositionId[token];
        bool    isBack     = s.erc20IsBack[token];

        // Use unified settlement path:
        // - isBack = true for Back mirror ERC20, false for Lay mirror ERC20
        // - quoteAmount = 0 for a pure position transfer
        SettlementLib.ERC20Settle(
            to,          // payer (recipient of the position)
            from,        // payee (sender of the position)
            marketId,
            positionId,
            isBack,
            amount,
            0            // quoteAmount: no ppUSDC leg
        );
    }

    // -------------------------------------------------------------
    // META
    // -------------------------------------------------------------

    function getERC20PositionMeta(address token)
        internal
        view
        returns (
            uint256 marketId,
            uint256 positionId,
            bool    registered,
            bool    isBack
        )
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        registered = s.erc20Registered[token];
        marketId   = s.erc20MarketId[token];
        positionId = s.erc20PositionId[token];
        isBack     = s.erc20IsBack[token];
    }

    // ============================================
    // ERC20 totalSupply / balanceOf VIEWS
    // ============================================

    /// @notice ERC20 totalSupply for a position mirror:
    ///         marketValue[marketId] + syntheticCollateral[marketId].
    ///         Same for Back and Lay in this simple model.
    function erc20TotalSupply(address token) internal view returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.erc20Registered[token], "ERC20BridgeLib: unregistered token");

        uint256 marketId = s.erc20MarketId[token];

        // After resolution, mirrors report 0 supply.
        if (s.marketResolved[marketId]) {
            return 0;
        }

        uint256 mv  = s.marketValue[marketId];
        uint256 isc = s.syntheticCollateral[marketId]; // full ISC line (0 for resolving markets)

        return mv + isc;
    }

    /// @notice ERC20 balanceOf:
    ///         - Back: "available shares" on that outcome, clamped at 0.
    ///           Includes ISC for the DMM automatically via getCreatedShares.
    ///         - Lay: only the minTilt position for the account has a
    ///           non-zero balance, equal to getMinTiltDelta(account, marketId).
function erc20BalanceOf(address token, address account)
        internal
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.erc20Registered[token], "ERC20BridgeLib: unregistered token");

        uint256 marketId   = s.erc20MarketId[token];
        uint256 positionId = s.erc20PositionId[token];
        bool    isBack     = s.erc20IsBack[token];

        if (s.marketResolved[marketId]) {
            return 0;
        }

        if (isBack) {
            // BACK MIRROR
            int256 avail = LedgerLib.getCreatedShares(
                account,
                marketId,
                positionId
            );
            if (avail <= 0) return 0;
            return uint256(avail);
        } else {
            // LAY MIRROR
            (, uint256 minPosId) = LedgerLib.getMinTilt(account, marketId);
            if (minPosId != positionId) {
                return 0;
            }

            int256 delta = HeapLib._getMinTiltDelta(account, marketId);
            if (delta <= 0) return 0;
            return uint256(delta);
        }
    }
}

