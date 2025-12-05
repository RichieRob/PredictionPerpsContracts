// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./3_AllocateCapitalLib.sol";
import "./4_SolvencyLib.sol";
import "./7_PositionTransferLib.sol";
import "./6_ResolutionLib.sol";

/// @title SettlementAccountingLib
/// @notice Heavy accounting for settlement:
///         - moves ppUSDC
///         - transfers positions
///         - runs solvency rebalances
///         - applies pending winnings
///         - applies account + global deltas.
library SettlementAccountingLib {
    using AllocateCapitalLib for AllocateCapitalLib.CapitalDeltas;

    // -------------------------------------------------------------
    // Parameter bundle (shared with SettlementLib)
    // -------------------------------------------------------------
    struct SettleParams {
        address payer;
        address payee;
        uint256 marketId;
        uint256 positionId;
        bool    isBack;
        uint256 baseAmount;         // tokens
        uint256 quoteAmount;        // ppUSDC / USDC
        bool    skipPayerRebalance;
    }

    /// @dev Helper to sum two CapitalDeltas (accumulator-style).
    function _addCapitalDeltas(
        AllocateCapitalLib.CapitalDeltas memory acc,
        AllocateCapitalLib.CapitalDeltas memory d
    ) private pure {
        acc.realFreeCollateralAccount += d.realFreeCollateralAccount;
        acc.realTotalFreeCollateral   += d.realTotalFreeCollateral;

        acc.usdcSpent    += d.usdcSpent;
        acc.redeemedUSDC += d.redeemedUSDC;

        acc.marketValue       += d.marketValue;
        acc.totalMarketsValue += d.totalMarketsValue;
    }

    /// @dev Heavy helper:
    ///      - moves ppUSDC
    ///      - transfers position (payee -> payer)
    ///      - runs solvency rebalances for both sides
    ///      - applies account + global deltas
    ///      Returns:
    ///          * full payerDeltas (for ERC20 projection)
    ///          * payerWinningsInt (so caller can net it out of ppUSDC events)
    function applyDeltas(
        StorageLib.Storage storage s,
        SettleParams memory p
    )
        internal
        returns (
            AllocateCapitalLib.CapitalDeltas memory payerDeltas,
            int256 payerWinningsInt
        )
    {
        // These structs + a few ints are the "heavy" stack users;
        // keeping them confined to this function avoids stack-too-deep elsewhere.
        AllocateCapitalLib.CapitalDeltas memory payeeDeltas;
        AllocateCapitalLib.CapitalDeltas memory globalDeltas;

        payerWinningsInt = 0;

        // ─────────────────────────────────────────────────
        // 1) Move ppUSDC between payer and payee (cash leg)
        // ─────────────────────────────────────────────────
        if (p.quoteAmount > 0) {
            int256 q = int256(p.quoteAmount);
            payeeDeltas.realFreeCollateralAccount += q;
            payerDeltas.realFreeCollateralAccount -= q;
        }

        // ─────────────────────────────────────────────────
        // 2) Position delta: payee -> payer (payer gets baseAmount)
        // ─────────────────────────────────────────────────
        PositionTransferLib.transferPosition(
            p.payee,
            p.payer,
            p.marketId,
            p.positionId,
            p.isBack,
            p.baseAmount
        );

        // ─────────────────────────────────────────────────
        // 3) Solvency rebalances via VIEW + CAPITAL DELTAS
        // ─────────────────────────────────────────────────

        // Payee
        {
            (int256 allocDelta, int256 deallocDelta) =
                SolvencyLib.rebalanceFullView(p.payee, p.marketId);

            if (allocDelta > 0) {
                AllocateCapitalLib.CapitalDeltas memory dAlloc =
                    AllocateCapitalLib._capitalDeltasView(
                        uint256(allocDelta),
                        true  // allocate
                    );
                _addCapitalDeltas(payeeDeltas, dAlloc);
            }

            if (deallocDelta < 0) {
                AllocateCapitalLib.CapitalDeltas memory dDealloc =
                    AllocateCapitalLib._capitalDeltasView(
                        uint256(-deallocDelta),
                        false // deallocate
                    );
                _addCapitalDeltas(payeeDeltas, dDealloc);
            }
        }

        // Payer – optionally skip this entire block
        if (!p.skipPayerRebalance) {
            (int256 allocDelta, int256 deallocDelta) =
                SolvencyLib.rebalanceFullView(p.payer, p.marketId);

            if (allocDelta > 0) {
                AllocateCapitalLib.CapitalDeltas memory dAlloc2 =
                    AllocateCapitalLib._capitalDeltasView(
                        uint256(allocDelta),
                        true  // allocate
                    );
                _addCapitalDeltas(payerDeltas, dAlloc2);
            }

            if (deallocDelta < 0) {
                AllocateCapitalLib.CapitalDeltas memory dDealloc2 =
                    AllocateCapitalLib._capitalDeltasView(
                        uint256(-deallocDelta),
                        false // deallocate
                    );
                _addCapitalDeltas(payerDeltas, dDealloc2);
            }
        }

        // ─────────────────────────────────────────────────
        // 3b) Resolution: claim pending winnings for both
        // ─────────────────────────────────────────────────
        {
            // Payer winnings
            uint256 payerWinnings =
                ResolutionLib._applyPendingWinnings(p.payer);
            if (payerWinnings > 0) {
                int256 w = int256(payerWinnings);
                payerWinningsInt = w; // track separately
                payerDeltas.realFreeCollateralAccount += w;
                payerDeltas.realTotalFreeCollateral   += w;
            }

            // Payee winnings (avoid double-claim if same address)
            if (p.payee != p.payer) {
                uint256 payeeWinnings =
                    ResolutionLib._applyPendingWinnings(p.payee);
                if (payeeWinnings > 0) {
                    int256 w2 = int256(payeeWinnings);
                    payeeDeltas.realFreeCollateralAccount += w2;
                    payeeDeltas.realTotalFreeCollateral   += w2;
                }
            }
        }

        // ─────────────────────────────────────────────────
        // 4) APPLY DELTAS
        // ─────────────────────────────────────────────────

        // 4a) Apply trader-specific deltas
        if (
            payeeDeltas.realFreeCollateralAccount != 0 ||
            payeeDeltas.usdcSpent                 != 0 ||
            payeeDeltas.redeemedUSDC              != 0
        ) {
            AllocateCapitalLib._applyAccountDeltas(
                s,
                p.payee,
                p.marketId,
                payeeDeltas
            );
        }

        if (
            payerDeltas.realFreeCollateralAccount != 0 ||
            payerDeltas.usdcSpent                 != 0 ||
            payerDeltas.redeemedUSDC              != 0
        ) {
            AllocateCapitalLib._applyAccountDeltas(
                s,
                p.payer,
                p.marketId,
                payerDeltas
            );
        }

        // 4b) Aggregate and apply global deltas once
        globalDeltas.realTotalFreeCollateral =
            payeeDeltas.realTotalFreeCollateral +
            payerDeltas.realTotalFreeCollateral;

        globalDeltas.marketValue =
            payeeDeltas.marketValue +
            payerDeltas.marketValue;

        globalDeltas.totalMarketsValue =
            payeeDeltas.totalMarketsValue +
            payerDeltas.totalMarketsValue;

        if (
            globalDeltas.realTotalFreeCollateral != 0 ||
            globalDeltas.marketValue             != 0 ||
            globalDeltas.totalMarketsValue       != 0
        ) {
            AllocateCapitalLib._applyGlobalDeltas(
                s,
                p.marketId,
                globalDeltas
            );
        }

        return (payerDeltas, payerWinningsInt);
    }
}
