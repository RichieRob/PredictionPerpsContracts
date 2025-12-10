// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./6_ClaimsLib.sol";

library PpUSDCBridgeLib {
 function ppUSDCTransfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(to != address(0), "to=0");

        if (from != address(0)) {
            // Ensure from has at least `amount` free collateral.
            uint256 cur = ClaimsLib.ensureFreeCollateralFor(from, amount);
            require(cur >= amount, "Insufficient ppUSDC");
            s.realFreeCollateral[from] = cur - amount;
        }

        s.realFreeCollateral[to] += amount;
    }

    /*//////////////////////////////////////////////////////////////
                           FREE COLLATERAL VIEWS
    //////////////////////////////////////////////////////////////*/

    // effectiveFreeCollateral is current ppUSDC-equivalent balance,
    // computed as realFreeCollateral + unclaimed winnings (view-only).
    function effectiveFreeCollateral(address account)
        internal
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 base = s.realFreeCollateral[account];
        uint256[] memory markets = s.userMarkets[account];

        for (uint256 i = 0; i < markets.length; ++i) {
            uint256 marketId = markets[i];
            if (!s.marketResolved[marketId]) continue;

            uint256 winner = s.winningPositionId[marketId];
            int256 exposure = s.tilt[account][marketId][winner];
            if (exposure > 0) {
                base += uint256(exposure);
            }
        }

        return base;
    }

    // realFreeCollateral does not include unclaimed winnings.
    function realFreeCollateral(address account)
        internal
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.realFreeCollateral[account];
    }
}
