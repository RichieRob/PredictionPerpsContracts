
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";

/// @title LMSRHelpersLib
/// @notice Library for helper functions in LMSRMarketMaker  listing checks).
library LMSRHelpersLib {


    /// @dev Require a ledger positionId is listed. Returns its AMM slot.
    function requireListed(LMSRMarketMaker self, uint256 marketId, uint256 ledgerPositionId) internal view returns (uint256 slot) {
        uint256 v = self.slotOf[marketId][ledgerPositionId];
        require(v != 0, "not listed");
        slot = v - 1;
    }
}
