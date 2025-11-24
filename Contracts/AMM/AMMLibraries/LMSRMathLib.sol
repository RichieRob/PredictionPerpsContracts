

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";

/// @title LMSRMathLib
/// @notice Library for common math helpers used in LMSRMarketMaker.
library LMSRMathLib {
    using PRBMathSD59x18 for int256;

    uint256 internal constant WAD = 1e18;

    /// @dev returns e^{x/b} where x is 1e6, result 1e18
    function expRatioOverB(int256 b, int256 x) internal pure returns (int256 eWad) {
        int256 xWad = (x * int256(WAD)) / b;      // x/b in 1e18
        eWad = PRBMathSD59x18.exp(xWad);          // 1e18
    }

    /// @dev (a * b) / 1e18
    function wmul(int256 a, int256 b_) internal pure returns (int256) {
        return (a * b_) / int256(WAD);
    }
}

