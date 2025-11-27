// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SD59x18, sd } from "@prb/math/src/SD59x18.sol";

import "./LMSRStorageLib.sol";
import "./LMSRMathLib.sol";
import "./ILedgerPositions.sol";


/// @title LMSRExpandLib
/// @notice Expansion-related functions for LMSR:
///         - listing new positions
///         - splitting from reserve
///         - reparameterising b and G to keep max liability fixed
/// @dev Purely storage-based – no dependency on LMSRMarketMaker type.
library LMSRExpandLib {
    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event ExpandedPositionListed(
        uint256 indexed ledgerPositionId,
        uint256 slot,
        int256  priorR
    );

    event PositionSplitFromReserve(
        uint256 indexed ledgerPositionId,
        uint256 slot,
        uint256 alphaWad,
        int256  reserveBefore,
        int256  reserveAfter,
        int256  Rnew
    );

    /*//////////////////////////////////////////////////////////////
                             LIST POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice List a new (or previously unlisted) ledger position with chosen prior mass.
    /// @dev This shifts all prices (S += priorR).
    function listPosition(
        LMSRStorageLib.State storage s,
        ILedgerPositions      ledger,
        uint256               marketId,
        uint256               ledgerPositionId,
        int256                priorR
    ) internal {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);

        require(m.initialized, "LMSR: not initialized");
        require(priorR > 0, "LMSR: prior<=0");
        require(
            ledger.positionExists(marketId, ledgerPositionId),
            "LMSR: ledger position !exists"
        );
        require(m.slotOf[ledgerPositionId] == 0, "LMSR: already listed");

        uint256 slot = m.numOutcomes;

        m.R[slot] = priorR;
        m.S      += priorR;

        m.slotOf[ledgerPositionId] = slot + 1;
        m.ledgerIdOfSlot[slot]     = ledgerPositionId;

        m.numOutcomes = slot + 1;

        require(m.S > 0, "LMSR: S<=0");

        emit ExpandedPositionListed(ledgerPositionId, slot, priorR);
    }

    /*//////////////////////////////////////////////////////////////
                             SPLIT FROM RESERVE
    //////////////////////////////////////////////////////////////*/

    /// @notice Split α fraction of the reserve into a NEW listing tied to `ledgerPositionId`.
    /// @dev
    ///   1. Keeps S constant (we move mass from reserve → tradable).
    ///   2. Then reparameterises b and G so that maxLiabilityUpscaled is unchanged.
    function splitFromReserve(
        LMSRStorageLib.State storage s,
        ILedgerPositions      ledger,
        uint256               marketId,
        uint256               ledgerPositionId,
        uint256               alphaWad
    ) internal returns (uint256 slot) {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);

        require(m.initialized, "LMSR: not initialized");
        require(m.isExpanding, "LMSR: not expanding");
        require(alphaWad > 0 && alphaWad <= WAD, "LMSR: bad alpha");
        require(
            ledger.positionExists(marketId, ledgerPositionId),
            "LMSR: ledger position !exists"
        );
        require(m.slotOf[ledgerPositionId] == 0, "LMSR: already listed");

        // --- 1 · Split from reserve into (reserve', Rnew) ---

        int256 before = m.R_reserve;
        require(before > 0, "LMSR: reserve empty");

        int256 Rnew = (before * int256(alphaWad)) / int256(WAD);
        require(Rnew > 0, "LMSR: tiny split");

        int256 reserveAfter = before - Rnew;
        require(reserveAfter >= 0, "LMSR: reserve underflow");

        slot = m.numOutcomes;

        m.R[slot]           = Rnew;
        m.R_reserve         = reserveAfter;
        m.slotOf[ledgerPositionId] = slot + 1;
        m.ledgerIdOfSlot[slot]     = ledgerPositionId;
        m.numOutcomes       = slot + 1;

        // S unchanged by construction: R_reserve' + Rnew = R_reserve
        require(m.S > 0, "LMSR: S<=0");

        emit PositionSplitFromReserve(
            ledgerPositionId,
            slot,
            alphaWad,
            before,
            reserveAfter,
            Rnew
        );

        // --- 2 · O(1) reparameterisation of b and G to keep max liability fixed ---

        // effective positions = (#tradables + reserve bucket)
        uint256 effectiveNNew = m.numOutcomes + 1;

        int256 bOld = m.b;
        int256 bNew = _calculateBFromUpscaled(
            m.maxLiabilityUpscaled,
            effectiveNNew
        );
        require(bNew > 0, "LMSR: bad bNew");

        // Z = G * S
        int256 Z = LMSRMathLib.wmul(m.G, m.S); // 1e18 * 1e18 / 1e18 = 1e18

        // ratio = bOld / bNew  (dimensionless, in 1e18-scale)
        int256 ratioWad = (bOld * int256(WAD)) / bNew;

        // Z' = Z^(ratio) = exp( ln(Z) * ratio )
        int256 lnZ  = LMSRMathLib.lnWad(Z);
        int256 arg  = (lnZ * ratioWad) / int256(WAD);
        int256 ZNew = sd(arg).exp().unwrap(); // expWad(arg)

        // G' = Z' / S
        int256 GNew = (ZNew * int256(WAD)) / m.S;

        m.b = bNew;
        m.G = GNew;
    }

    /// @dev b = maxLiabilityUpscaled / ln(n), where:
    ///      - maxLiabilityUpscaled is liabilityUSDC * 1e18
    ///      - n is effectivePositions (tradables + reserve if expanding)
    function _calculateBFromUpscaled(
        int256 maxLiabilityUpscaled,
        uint256 effectivePositions
    ) internal pure returns (int256 _b) {
        int256 nWad = int256(effectivePositions) * int256(WAD);
        int256 lnNWad = LMSRMathLib.lnWad(nWad);
        require(lnNWad > 0, "LMSR: ln(n)<=0");

        _b = maxLiabilityUpscaled / lnNWad;
    }
}
