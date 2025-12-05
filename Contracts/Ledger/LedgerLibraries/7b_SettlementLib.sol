// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./3_HeapLib.sol";
import "./5_LedgerLib.sol";
import "./3_AllocateCapitalLib.sol";
import "./7a_SettlementCore.sol"; // library SettlementAccountingLib

interface JNotify {
    function notifyTransfer(address from, address to, uint256 amount) external;
}

/// @title SettlementLib
/// @notice Thin wrapper around SettlementAccountingLib:
///         - bundles parameters
///         - calls applyDeltas
///         - projects Back/Lay/ppUSDC ERC20-level events.
library SettlementLib {
    // We don't actually use the "using" in this lib any more
    // using AllocateCapitalLib for AllocateCapitalLib.CapitalDeltas;

    event Settlement(
        address indexed payer,
        address indexed payee,
        uint256 indexed marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,
        uint256 quoteAmount
    );

    /// @dev Context for ERC20 mirror projection, kept in memory
    ///      so we pass only one pointer instead of a ton of params.
    struct MirrorCtx {
        address payer;
        uint256 marketId;
        uint256 positionId;
        bool    isBack;
        uint256 baseAmount;

        address backToken;
        address layToken;
        uint256 oldLayBalance;

        AllocateCapitalLib.CapitalDeltas payerDeltas;
        int256  payerWinningsInt;

        address ppUSDC;
    }

    // ─────────────────────────────────────────────────────
    // Small helpers (local to this lib)
    // ─────────────────────────────────────────────────────

    function _createdSharesDeltaForAccount(
        AllocateCapitalLib.CapitalDeltas memory d,
        bool     isBack,
        bool     isPayer,      // true = payer, false = payee
        uint256  baseAmount
    ) private pure returns (int256 csDelta) {
        // ΔnetAlloc = Δ(USDCSpent - redeemedUSDC)
        int256 netAllocDelta = d.usdcSpent - d.redeemedUSDC;

        // Position-specific tilt/layOffset delta for THIS position:
        int256 posDelta = 0;

        if (isBack) {
            // Back: only tilt moves; layOffset stays 0
            // payee → payer transfer
            posDelta = isPayer
                ? int256(baseAmount)     // payer gets +tilt
                : -int256(baseAmount);   // payee gets -tilt
        } else {
            // Lay case:
            // We rely on netAllocDelta to capture any net-out of Back exposure.
            posDelta = 0;
        }

        return netAllocDelta + posDelta;
    }

    /// @dev Lay ERC20 "balance" for an account on (marketId, positionId),
    ///      derived from min-tilt heap. Zero if:
    ///        - market is resolved,
    ///        - this position is not the min-tilt leg,
    ///        - or the min-tilt delta <= 0.
    function _getLayBalanceForAccount(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId,
        uint256 positionId
    ) private view returns (uint256) {
        if (s.marketResolved[marketId]) {
            return 0;
        }

        (, uint256 minPos) = LedgerLib.getMinTilt(account, marketId);
        if (minPos != positionId) {
            return 0;
        }

        int256 delta = HeapLib._getMinTiltDelta(account, marketId);
        if (delta <= 0) {
            return 0;
        }

        return uint256(delta);
    }

    // ─────────────────────────────────────────────────────
    // Public shells (small, no heavy locals)
    // ─────────────────────────────────────────────────────

    /// @dev Normal settlement: includes payer rebalanceFullView.
    function settle(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,   // tokens
        uint256 quoteAmount   // ppUSDC / USDC
    ) internal {
        _settleCore(
            payer,
            payee,
            marketId,
            positionId,
            isBack,
            baseAmount,
            quoteAmount,
            false // skipPayerRebalance = false (DO rebalance payer)
        );

        emit Settlement(
            payer,
            payee,
            marketId,
            positionId,
            isBack,
            baseAmount,
            quoteAmount
        );
    }

    /// @dev ERC20-only settlement variant:
    ///      skips SolvencyLib.rebalanceFullView for the payer.
    function ERC20Settle(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,
        uint256 quoteAmount
    ) internal {
        _settleCore(
            payer,
            payee,
            marketId,
            positionId,
            isBack,
            baseAmount,
            quoteAmount,
            true // skipPayerRebalance = true
        );

        emit Settlement(
            payer,
            payee,
            marketId,
            positionId,
            isBack,
            baseAmount,
            quoteAmount
        );
    }

    // ─────────────────────────────────────────────────────
    // Core wrapper: params + ERC20 mirrors
    // ─────────────────────────────────────────────────────

    function _settleCore(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,   // tokens
        uint256 quoteAmount,  // ppUSDC / USDC
        bool    skipPayerRebalance
    ) private {
        require(payer != address(0), "payer=0");
        require(payee != address(0), "payee=0");
        require(baseAmount > 0, "base=0");
        // NOTE: quoteAmount may legitimately be 0 for pure position transfers.

        StorageLib.Storage storage s = StorageLib.getStorage();

        // Back / Lay ERC20 mirrors for this outcome
        address backToken = s.positionBackERC20[marketId][positionId];
        address layToken  = s.positionLayERC20[marketId][positionId];

        // Snapshot LAY balance for payer *before* settlement
        uint256 oldLayBalance = 0;
        if (layToken != address(0)) {
            oldLayBalance = _getLayBalanceForAccount(
                s,
                payer,
                marketId,
                positionId
            );
        }

        // ---- Heavy core: rebalances + resolution + deltas ----

        SettlementAccountingLib.SettleParams memory p =
            SettlementAccountingLib.SettleParams({
                payer: payer,
                payee: payee,
                marketId: marketId,
                positionId: positionId,
                isBack: isBack,
                baseAmount: baseAmount,
                quoteAmount: quoteAmount,
                skipPayerRebalance: skipPayerRebalance
            });

        (
            AllocateCapitalLib.CapitalDeltas memory payerDeltas,
            int256 payerWinningsInt
        ) = SettlementAccountingLib.applyDeltas(s, p);

        // ---- Build ctx AFTER heavy call so we don't keep extra vars live ----

        MirrorCtx memory ctx;
        ctx.payer           = payer;
        ctx.marketId        = marketId;
        ctx.positionId      = positionId;
        ctx.isBack          = isBack;
        ctx.baseAmount      = baseAmount;
        ctx.backToken       = backToken;
        ctx.layToken        = layToken;
        ctx.oldLayBalance   = oldLayBalance;
        ctx.payerDeltas     = payerDeltas;
        ctx.payerWinningsInt= payerWinningsInt;
        ctx.ppUSDC          = address(s.ppUSDC);

        _projectERC20Mirrors(s, ctx);
    }

    /// @dev ERC20 mirror projection in its own function with a single
    ///      memory struct argument to keep the stack shallow.
    function _projectERC20Mirrors(
        StorageLib.Storage storage s,
        MirrorCtx memory c
    ) private {
        // Back ERC20: createdShares delta for this position
        int256 csDeltaPayer = 0;
        if (c.isBack) {
            csDeltaPayer = _createdSharesDeltaForAccount(
                c.payerDeltas,
                true,        // isBack
                true,        // isPayer
                c.baseAmount
            );
        }

        // ppUSDC mirror: freeCollateral delta minus winnings
        int256 fcDelta =
            c.payerDeltas.realFreeCollateralAccount - c.payerWinningsInt;

        // Lay ERC20 balance *after* all changes
        uint256 newLayBalance = 0;
        if (c.layToken != address(0)) {
            newLayBalance = _getLayBalanceForAccount(
                s,
                c.payer,
                c.marketId,
                c.positionId
            );
        }

        // ─────────────────────────────────────────────
        // Back ERC20 mirror
        // ─────────────────────────────────────────────
        if (c.backToken != address(0) && csDeltaPayer != 0) {
            if (csDeltaPayer > 0) {
                // Mint to payer
                JNotify(c.backToken).notifyTransfer(
                    address(0),
                    c.payer,
                    uint256(csDeltaPayer)
                );
            } else {
                // Burn from payer
                JNotify(c.backToken).notifyTransfer(
                    c.payer,
                    address(0),
                    uint256(-csDeltaPayer)
                );
            }
        }

        // ─────────────────────────────────────────────
        // Lay ERC20 mirror: mint/burn from the change in lay balance.
        // ─────────────────────────────────────────────
        if (c.layToken != address(0) && newLayBalance != c.oldLayBalance) {
            if (newLayBalance > c.oldLayBalance) {
                uint256 diff = newLayBalance - c.oldLayBalance;
                JNotify(c.layToken).notifyTransfer(
                    address(0),
                    c.payer,
                    diff
                );
            } else {
                uint256 diff = c.oldLayBalance - newLayBalance;
                JNotify(c.layToken).notifyTransfer(
                    c.payer,
                    address(0),
                    diff
                );
            }
        }

        // ─────────────────────────────────────────────
        // ppUSDC mirror: use fcDelta (already net of winnings).
        // ─────────────────────────────────────────────
        if (fcDelta != 0) {
            if (fcDelta > 0) {
                // Mint ppUSDC to payer
                JNotify(c.ppUSDC).notifyTransfer(
                    address(0),
                    c.payer,
                    uint256(fcDelta)
                );
            } else {
                // Burn ppUSDC from payer
                JNotify(c.ppUSDC).notifyTransfer(
                    c.payer,
                    address(0),
                    uint256(-fcDelta)
                );
            }
        }
    }
}
