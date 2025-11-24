// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRViewLib
/// @notice Library for view functions in LMSRMarketMaker (prices, Z, slots).
library LMSRViewLib {
    /// @notice Internal implementation to get BACK price for a ledger positionId (1e18).
    function getBackPriceWadInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId
    ) internal view returns (uint256) {
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);
        return uint256((self.R[marketId][slot] * int256(LMSRMarketMaker.WAD)) / self.S[marketId]);
    }

    /// @notice Internal implementation to get true LAY(not-i) price for a ledger positionId (1e18).
    function getLayPriceWadInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId
    ) internal view returns (uint256) {
        return LMSRMarketMaker.WAD - getBackPriceWadInternal(self, marketId, ledgerPositionId);
    }

    /// @notice Internal implementation for informational reserve (“Other”) price (1e18).
    function getReservePriceWadInternal(
        LMSRMarketMaker self,
        uint256 marketId
    ) internal view returns (uint256) {
        return uint256((self.R_reserve[marketId] * int256(LMSRMarketMaker.WAD)) /self.S[marketId]);
    }

    /// @notice Internal implementation for Z = sum E_i = G * S(1e18).
    function getZInternal(
        LMSRMarketMaker self,
        uint256 marketId
    ) internal view returns (uint256) {
        return uint256((self.G[marketId] * self.S[marketId]) / int256(LMSRMarketMaker.WAD));
    }

    /// @notice Internal implementation to return the listed AMM slots and their ledger ids (for UIs).
    function listSlotsInternal(
        LMSRMarketMaker self,
        uint256 marketId
    ) internal view returns (uint256[] memory listedLedgerIds) {
        listedLedgerIds = new uint256[](self.numOutcomes[marketId]);
        for (uint256 i = 0; i < self.numOutcomes[marketId]; i++) {
            listedLedgerIds[i] = self.ledgerIdOfSlot[marketId][i];
        }
    }
}
