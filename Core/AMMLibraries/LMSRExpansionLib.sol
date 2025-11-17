// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";

/// @title LMSRExpansionLib
/// @notice Library for expansion-related functions in LMSRMarketMaker (listing and splitting).
library LMSRExpansionLib {
    /// @notice Internal implementation to list a new position.
    // this function is going to shift all the other prices in the market
    function listPositionInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        int256 priorR
    ) internal {
        require(priorR > 0, "prior<=0");
        require(self.slotOf[marketId][ledgerPositionId] == 0, "already listed");
        require(self.ledger.positionExists(marketId, ledgerPositionId), "ledger: position !exists");

        uint256 slot = self.numOutcomes[marketId]; // append
        self.R[marketId].push(priorR);
        self.S[marketId] += priorR;

        self.slotOf[marketId][ledgerPositionId] = slot + 1;
        self.ledgerIdOfSlot[marketId][slot]     = ledgerPositionId;

        self.numOutcomes[marketId] += 1;

        emit LMSRMarketMaker.PositionListed(ledgerPositionId, slot, priorR);
    }

    /// @notice Internal implementation to split from reserve.
    // this funciton splits off from the reserve bucket leaving all other prices unaffected
    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";
import "../LMSRMarketMaker.sol";

library LMSRExpandLib {
    using PRBMathSD59x18 for int256;

    function splitFromReserveInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        uint256 alphaWad
    ) internal returns (uint256 slot) {
        require(self.isExpanding[marketId], "not expanding");
        require(alphaWad > 0 && alphaWad <= LMSRMarketMaker.WAD, "bad alpha");
        require(self.slotOf[marketId][ledgerPositionId] == 0, "already listed");
        require(self.ledger.positionExists(marketId, ledgerPositionId), "ledger: position !exists");

        // --- 1 · Split from reserve into (reserve', Rnew) ---

        int256 before = self.R_reserve[marketId];
        require(before > 0, "reserve empty");

        int256 Rnew = (before * int256(alphaWad)) / int256(LMSRMarketMaker.WAD);
        require(Rnew > 0, "tiny split");

        // shrink reserve; S is unchanged because we add Rnew with the removed mass
        int256 reserveAfter = before - Rnew;
        require(reserveAfter >= 0, "reserve underflow");
        self.R_reserve[marketId] = reserveAfter;

        // Slot index for the new outcome
        slot = self.numOutcomes[marketId];

        // Add new listed outcome with weight Rnew
        self.R[marketId].push(Rnew);

        // S[marketId] unchanged by construction: R_reserve' + Rnew = R_reserve

        self.slotOf[marketId][ledgerPositionId] = slot + 1;
        self.ledgerIdOfSlot[marketId][slot]     = ledgerPositionId;

        // increase number of outcomes in market
        self.numOutcomes[marketId] += 1;

        uint256 effectiveNNew = self.numOutcomes[marketId] +1;

        emit LMSRMarketMaker.PositionSplitFromReserve(
            ledgerPositionId,
            slot,
            alphaWad,
            before,
            reserveAfter,
            Rnew
        );

        // --- 2 · O(1) reparameterisation of b and G to keep max loss (maxLiabilityUpscaled) fixed ---


        int256 bNew = self.calculateB(self.maxLiabilityUpscaled[marketId], effectiveNNew);

        // Z = G * S
        int256 GOld = self.G[marketId];
        int256 S    = self.S[marketId];
        int256 Z    = GOld.mul(S);             // 1e18 * 1e18 / 1e18 = 1e18

        // ratio = bOld / bNew
        int256 ratio   = bOld.div(bNew);

        // Z' = Z^(ratio) = exp( ln(Z) * ratio )
        int256 ZNew  = Z.ln().mul(ratio).exp();

        // G' = Z' / S
        int256 GNew  = ZNew.div(S);

        self.b[marketId] = bNew;
        self.G[marketId] = GNew;
    }
}

}
