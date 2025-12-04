// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
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
        require(payer != address(0));
        require(payee != address(0));
        require(baseAmount > 0);
        // NOTE: quoteAmount may legitimately be 0 for pure position transfers.

        StorageLib.Storage storage s = StorageLib.getStorage();

        // ─────────────────────────────────────────────────────
        // 0) Move ppUSDC between payer and payee (if any cash leg)
        // ─────────────────────────────────────────────────────

        AllocateCapitalLib.CapitalDeltas memory payeeDeltas;
        AllocateCapitalLib.CapitalDeltas memory payerDeltas;

        if (quoteAmount > 0) {
            int256 q = int256(quoteAmount);
            payeeDeltas.realFreeCollateralAccount += q;
            payerDeltas.realFreeCollateralAccount -= q;
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
        // 4) PROJECT ERC20 EVENTS & Settlement EVENT (PAYER ONLY)
        //    Moved into a helper to reduce stack depth.
        // ─────────────────────────────────────────────────────
        _projectEvents(
            s,
            payer,
            payee,
            marketId,
            positionId,
            isBack,
            baseAmount,
            quoteAmount,
            payerDeltas,
            payerWinningsInt
        );
    }

    /// @dev Separate helper so the main function can drop locals
    ///      before we do ERC20 event projection.
    function _projectEvents(
        StorageLib.Storage storage s,
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,
        uint256 quoteAmount,
        AllocateCapitalLib.CapitalDeltas memory payerDeltas,
        int256  payerWinningsInt
    ) private {
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

                if (csDeltaPayer > 0) {
                    // Mint to payer
                    JNotify(posToken).notifyTransfer(
                        address(0),
                        payer,
                        uint256(csDeltaPayer)
                    );
                } else if (csDeltaPayer < 0) {
                    // Burn from payer
                    JNotify(posToken).notifyTransfer(
                        payer,
                        address(0),
                        uint256(-csDeltaPayer)
                    );
                }
            }
        }

        // 4b) ppUSDC mirror: use realFreeCollateralAccount delta for payer
        //     BUT subtract the winnings part so ERC20 events only show trade I/O.
        {
            int256 fcDelta = payerDeltas.realFreeCollateralAccount - payerWinningsInt;
            if (fcDelta > 0) {
                // Mint ppUSDC to payer
                JNotify(address(s.ppUSDC)).notifyTransfer(
                    address(0),
                    payer,
                    uint256(fcDelta)
                );
            } else if (fcDelta < 0) {
                // Burn ppUSDC from payer
                JNotify(address(s.ppUSDC)).notifyTransfer(
                    payer,
                    address(0),
                    uint256(-fcDelta)
                );
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
