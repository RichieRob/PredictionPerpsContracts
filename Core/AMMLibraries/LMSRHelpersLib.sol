
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";

/// @title LMSRHelpersLib
/// @notice Library for helper functions in LMSRMarketMaker (e.g., denom and listing checks).
library LMSRHelpersLib {
    /// @notice Price denominator S_tradables + R_reserve (1e18)
    function denom(LMSRMarketMaker self, uint256 marketId) internal view returns (int256) {
        int256 d = self.S_tradables[marketId] + self.R_reserve[marketId];
        require(d > 0, "denom=0");
        return d;
    }

    /// @dev Require a ledger positionId is listed. Returns its AMM slot.
    function requireListed(LMSRMarketMaker self, uint256 marketId, uint256 ledgerPositionId) internal view returns (uint256 slot) {
        uint256 v = self.slotOf[marketId][ledgerPositionId];
        require(v != 0, "not listed");
        slot = v - 1;
    }
}
