// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./5_LedgerLib.sol";
import "./7_AllocateCapitalLib.sol";
import "./7a_SettlementCore.sol"; // library SettlementAccountingLib

interface JNotify {
    function notifyTransfer(address from, address to, uint256 amount) external;
}

/// @title SettlementLib
/// @notice Thin wrapper around SettlementAccountingLib:
///         - bundles parameters
///         - calls applyDeltas
///         - projects Back/Lay/ppUSDC ERC20-level events using
///           canonical LedgerLib.getBackAndLayBalances snapshots.
library SettlementLib {
    event Settlement(
        address indexed payer,
        address indexed payee,
        uint256 indexed marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,
        uint256 quoteAmount
    );

    struct MirrorCtx {
        address payer;
        uint256 marketId;
        uint256 positionId;

        address backToken;
        address layToken;

        uint256 backBefore;
        uint256 layBefore;
        uint256 backAfter;
        uint256 layAfter;

        AllocateCapitalLib.CapitalDeltas payerDeltas;
        int256  payerWinningsInt;

        address ppUSDC;
    }

    // ─────────────────────────────────────────────────────
    // Public shells (now EXTERNAL so they are true library calls)
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
    ) external {
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
    ) external {
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
    // Core wrapper: params + ERC20 mirrors (snapshot-based)
    // ─────────────────────────────────────────────────────

    function _settleCore(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,          // informational
        uint256 baseAmount,      // tokens (informational only here)
        uint256 quoteAmount,     // ppUSDC / USDC (informational)
        bool    skipPayerRebalance
    ) internal {
        require(payer != address(0), "payer=0");
        require(payee != address(0), "payee=0");
        require(baseAmount > 0, "base=0");
        // quoteAmount may be 0 for pure position transfers.

        StorageLib.Storage storage s = StorageLib.getStorage();

        // Back / Lay ERC20 mirrors for this outcome
        address backToken = s.positionBackERC20[marketId][positionId];
        address layToken  = s.positionLayERC20[marketId][positionId];

        // Snapshot canonical BACK/LAY balances for payer *before* settlement
        (uint256 backBefore, uint256 layBefore) =
            LedgerLib.getBackAndLayBalances(payer, marketId, positionId);

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

        // Snapshot canonical BACK/LAY balances for payer *after* settlement
        (uint256 backAfter, uint256 layAfter) =
            LedgerLib.getBackAndLayBalances(payer, marketId, positionId);

        // Build ctx AFTER heavy call so we don't keep extra vars live
        MirrorCtx memory ctx;
        ctx.payer            = payer;
        ctx.marketId         = marketId;
        ctx.positionId       = positionId;
        ctx.backToken        = backToken;
        ctx.layToken         = layToken;
        ctx.backBefore       = backBefore;
        ctx.layBefore        = layBefore;
        ctx.backAfter        = backAfter;
        ctx.layAfter         = layAfter;
        ctx.payerDeltas      = payerDeltas;
        ctx.payerWinningsInt = payerWinningsInt;
        ctx.ppUSDC           = address(s.ppUSDC);

        _projectERC20Mirrors(ctx);
    }

    /// @dev ERC20 mirror projection using canonical balance snapshots.
    ///      Only payer is considered (we ignore payee for mint/burn).
    function _projectERC20Mirrors(
        MirrorCtx memory c
    ) internal {
        // ─────────────────────────────────────────────
        // Back ERC20 mirror
        // ─────────────────────────────────────────────
        if (c.backToken != address(0) && c.backAfter != c.backBefore) {
            if (c.backAfter > c.backBefore) {
                uint256 diff = c.backAfter - c.backBefore;
                // Mint to payer
                JNotify(c.backToken).notifyTransfer(
                    address(0),
                    c.payer,
                    diff
                );
            } else {
                uint256 diff = c.backBefore - c.backAfter;
                // Burn from payer
                JNotify(c.backToken).notifyTransfer(
                    c.payer,
                    address(0),
                    diff
                );
            }
        }

        // ─────────────────────────────────────────────
        // Lay ERC20 mirror
        // ─────────────────────────────────────────────
        if (c.layToken != address(0) && c.layAfter != c.layBefore) {
            if (c.layAfter > c.layBefore) {
                uint256 diff = c.layAfter - c.layBefore;
                JNotify(c.layToken).notifyTransfer(
                    address(0),
                    c.payer,
                    diff
                );
            } else {
                uint256 diff = c.layBefore - c.layAfter;
                JNotify(c.layToken).notifyTransfer(
                    c.payer,
                    address(0),
                    diff
                );
            }
        }

        // ─────────────────────────────────────────────
        // ppUSDC mirror: freeCollateral delta minus winnings.
        // ─────────────────────────────────────────────
        int256 fcDelta =
            c.payerDeltas.realFreeCollateralAccount - c.payerWinningsInt;

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
