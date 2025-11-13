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

        int256 before = self.R_reserve[marketId];
        require(before > 0, "reserve empty");

        int256 Rnew = (before * int256(alphaWad)) / int256(LMSRMarketMaker.WAD);
        require(Rnew > 0, "tiny split");

        self.R_reserve[marketId] = before - Rnew; // denom unchanged
        require(self.R_reserve[marketId] >= 0, "reserve underflow");

        slot = self.numOutcomes[marketId];

        self.R[marketId].push(Rnew);
        //S unchanged
        // self.S[marketId] = self.S[marketId];

        self.slotOf[marketId][ledgerPositionId] = slot + 1;
        self.ledgerIdOfSlot[marketId][slot]     = ledgerPositionId;

        self.numOutcomes[marketId] += 1;

        emit LMSRMarketMaker.PositionSplitFromReserve(ledgerPositionId, slot, alphaWad, before, self.R_reserve[marketId], Rnew);
    }
}
