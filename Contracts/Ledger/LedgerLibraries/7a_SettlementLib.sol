// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./2_FreeCollateralLib.sol";
import "./7_PositionTransferLib.sol";
import "./4_SolvencyLib.sol";
import "./3_AllocateCapitalLib.sol";
import "./6_ResolutionLib.sol"; // <<< NEW

interface JNotify {
    function notifyTransfer(address from, address to, uint256 amount) external;
}

/// @title SettlementLib
/// @notice Handles settlement between a payer and payee around a trade,
///         using a flash-loan style bump to avoid temporary underflow on
///         the paying account.
library SettlementLib {
    using AllocateCapitalLib for AllocateCapitalLib.CapitalDeltas;

    event Settlement(
        address indexed payer,
        address indexed payee,
        uint256 indexed marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,
        uint256 quoteAmount
    );

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

    /// @dev Helper to sum two CapitalDeltas (accumulator-style).
    function _addCapitalDeltas(
        AllocateCapitalLib.CapitalDeltas memory acc,
        AllocateCapitalLib.CapitalDeltas memory d
    ) private pure {
        acc.realFreeCollateralAccount += d.realFreeCollateralAccount;
        acc.realTotalFreeCollateral   += d.realTotalFreeCollateral;

        acc.usdcSpent += d.usdcSpent;

        acc.redeemedUSDC += d.redeemedUSDC;

        acc.marketValue       += d.marketValue;
        acc.totalMarketsValue += d.totalMarketsValue;
    }

    /// @dev Generic settlement helper with a flash-loan-style bump.
    ///
    /// Roles:
    /// - `payer`: side that ultimately pays `quoteAmount`
    ///            (gets a temporary realFreeCollateral boost).
    /// - `payee`: side that receives `quoteAmount`.
    ///
    /// Position flow:
    /// - Positions always flow payee -> payer (payer receives `baseAmount`).
    ///
    /// Arguments:
    /// - `baseAmount`: number of position tokens (Back or Lay) moving.
    /// - `quoteAmount`: ppUSDC/USDC value moving in the opposite direction.
    ///                  If 0, this becomes a pure position-transfer settlement.
    function settleWithFlash(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,   // tokens
        uint256 quoteAmount   // ppUSDC / USDC
    ) internal {
        require(payer != address(0), "payer=0");   // still required: payer is the recipient
        require(payee != address(0), "payee=0");
        require(baseAmount > 0, "base=0");
        // NOTE: quoteAmount may legitimately be 0 for pure position transfers.

        StorageLib.Storage storage s = StorageLib.getStorage();

        // ─────────────────────────────────────────────────────
        // 0) Move ppUSDC between payer and payee (if any cash leg)
        // ─────────────────────────────────────────────────────

        AllocateCapitalLib.CapitalDeltas memory payeeDeltas;
        AllocateCapitalLib.CapitalDeltas memory payerDeltas;

        if (quoteAmount > 0) {
            payeeDeltas.realFreeCollateralAccount += int256(quoteAmount);
            payerDeltas.realFreeCollateralAccount -= int256(quoteAmount);
        }

        // ─────────────────────────────────────────────────────
        // 1) Position delta: payee -> payer (payer receives baseAmount)
        // ─────────────────────────────────────────────────────
        PositionTransferLib.transferPosition(
            payee,
            payer,
            marketId,
            positionId,
            isBack,
            baseAmount
        );

        // ─────────────────────────────────────────────────────
        // 2) Solvency rebalances via VIEW + CAPITAL DELTAS
        // ─────────────────────────────────────────────────────

        // Payee
        {
            (int256 allocDelta, int256 deallocDelta) =
                SolvencyLib.rebalanceFullView(payee, marketId);

            if (allocDelta > 0) {
                AllocateCapitalLib.CapitalDeltas memory dAlloc =
                    AllocateCapitalLib._capitalDeltasView(
                        uint256(allocDelta),
                        true  // allocate
                    );
                _addCapitalDeltas(payeeDeltas, dAlloc);
            }

            if (deallocDelta < 0) {
                uint256 deallocAmt = uint256(-deallocDelta);
                AllocateCapitalLib.CapitalDeltas memory dDealloc =
                    AllocateCapitalLib._capitalDeltasView(
                        deallocAmt,
                        false // deallocate
                    );
                _addCapitalDeltas(payeeDeltas, dDealloc);
            }
        }

        // Payer
        {
            (int256 allocDelta, int256 deallocDelta) =
                SolvencyLib.rebalanceFullView(payer, marketId);

            if (allocDelta > 0) {
                AllocateCapitalLib.CapitalDeltas memory dAlloc =
                    AllocateCapitalLib._capitalDeltasView(
                        uint256(allocDelta),
                        true  // allocate
                    );
                _addCapitalDeltas(payerDeltas, dAlloc);
            }

            if (deallocDelta < 0) {
                uint256 deallocAmt = uint256(-deallocDelta);
                AllocateCapitalLib.CapitalDeltas memory dDealloc =
                    AllocateCapitalLib._capitalDeltasView(
                        deallocAmt,
                        false // deallocate
                    );
                _addCapitalDeltas(payerDeltas, dDealloc);
            }
        }

        // ─────────────────────────────────────────────────────
        // 2b) Resolution: claim pending winnings for both accounts
        //     and fold into CapitalDeltas before global write.
        //     BUT: we do *not* want winnings in ppUSDC events.
        // ─────────────────────────────────────────────────────
        int256 payerWinningsInt = 0;
        int256 payeeWinningsInt = 0;

        {
            // Payer winnings
            uint256 payerWinnings = ResolutionLib._applyPendingWinnings(payer);
            if (payerWinnings > 0) {
                int256 w = int256(payerWinnings);
                payerWinningsInt = w; // track separately for event projection
                payerDeltas.realFreeCollateralAccount += w;
                payerDeltas.realTotalFreeCollateral   += w;
            }

            // Payee winnings (avoid double-claim if same address)
            if (payee != payer) {
                uint256 payeeWinnings = ResolutionLib._applyPendingWinnings(payee);
                if (payeeWinnings > 0) {
                    int256 w = int256(payeeWinnings);
                    payeeWinningsInt = w; // not used now, but kept for symmetry/future
                    payeeDeltas.realFreeCollateralAccount += w;
                    payeeDeltas.realTotalFreeCollateral   += w;
                }
            }
        }

        // ─────────────────────────────────────────────────────
        // 3) APPLY DELTAS
        //    - account deltas: once per account
        //    - global deltas: once per market
        // ─────────────────────────────────────────────────────

        // 3a) Apply trader-specific deltas
        if (
            payeeDeltas.realFreeCollateralAccount != 0 ||
            payeeDeltas.usdcSpent                 != 0 ||
            payeeDeltas.redeemedUSDC              != 0
        ) {
            AllocateCapitalLib._applyAccountDeltas(
                s,
                payee,
                marketId,
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
                payer,
                marketId,
                payerDeltas
            );
        }

        // 3b) Aggregate and apply global deltas once
        AllocateCapitalLib.CapitalDeltas memory globalDeltas;

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
                marketId,
                globalDeltas
            );
        }

        // ─────────────────────────────────────────────────────
        // 4) PROJECT ERC20 EVENTS FROM DELTAS (PAYER ONLY)
        //    - Position ERC20 (this position)
        //    - ppUSDC mirror (realFreeCollateralAccount *excluding winnings*)
        //    - Full ledger Settlement event
        // ─────────────────────────────────────────────────────

        // 4a) Position ERC20: createdShares delta for this position (payer only)
        {
            address posToken = s.positionERC20[marketId][positionId];
            if (posToken != address(0)) {
                int256 csDeltaPayer = _createdSharesDeltaForAccount(
                    payerDeltas,
                    isBack,
                    true,        // isPayer = true
                    baseAmount
                );

                if (csDeltaPayer != 0) {
                    uint256 amt;
                    address from;
                    address to;

                    if (csDeltaPayer > 0) {
                        // Mint to payer
                        amt  = uint256(csDeltaPayer);
                        from = address(0);
                        to   = payer;
                    } else {
                        // Burn from payer
                        amt  = uint256(-csDeltaPayer);
                        from = payer;
                        to   = address(0);
                    }

                    JNotify(posToken).notifyTransfer(from, to, amt);
                }
            }
        }

        // 4b) ppUSDC mirror: use realFreeCollateralAccount delta for payer
        //     BUT subtract the winnings part so ERC20 events only show trade I/O.
        {
            int256 fcDelta = payerDeltas.realFreeCollateralAccount - payerWinningsInt;
            if (fcDelta != 0) {
                uint256 amt;
                address from;
                address to;

                if (fcDelta > 0) {
                    // Mint ppUSDC to payer
                    amt  = uint256(fcDelta);
                    from = address(0);
                    to   = payer;
                } else {
                    // Burn ppUSDC from payer
                    amt  = uint256(-fcDelta);
                    from = payer;
                    to   = address(0);
                }

                JNotify(address(s.ppUSDC)).notifyTransfer(from, to, amt);
            }
        }

        // 4c) Full ledger-level settlement event with raw inputs
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
}
