// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SD59x18, sd } from "@prb/math/src/SD59x18.sol";

/// @title LMSRMathLib
/// @notice Common math helpers used in LMSRMarketMaker.
library LMSRMathLib {
    uint256 internal constant WAD = 1e18;

    /// @dev exp(x / b) where x and b are 1e6-scaled “USDC units”.
    ///      Result is 1e18 WAD.
    function expRatioOverB(int256 b, int256 x) internal pure returns (int256 eWad) {
        // x/b in 1e18
        int256 xWad = (x * int256(WAD)) / b;
        // Wrap into SD59x18, exponentiate, unwrap back to raw int256 (1e18)
        eWad = sd(xWad).exp().unwrap();
    }

    /// @dev Natural log on a WAD value. Input and output both 1e18-scaled.
    function lnWad(int256 wad) internal pure returns (int256) {
        // Safety: avoid ln(0)
        require(wad > 0, "ln domain");
        return sd(wad).ln().unwrap();
    }

    /// @dev (a * b_) / 1e18
    function wmul(int256 a, int256 b_) internal pure returns (int256) {
        return (a * b_) / int256(WAD);
    }
}
