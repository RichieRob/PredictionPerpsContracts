// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./2_FreeCollateralLib.sol";
import "./7_PositionTransferLib.sol";
import "./4_SolvencyLib.sol";

library SettlementLib {
    /// @dev Generic settlement helper with a flash-loan-style bump on the payer.
    /// - payer: side that ultimately pays `quoteAmount` (gets temporary realFreeCollateral boost)
    /// - payee: side that receives `quoteAmount`
    /// - Positions always flow payee -> payer (payer receives the baseAmount).
    function settleWithFlash(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,   // tokens
        uint256 quoteAmount   // ppUSDC / USDC
    ) internal {
        require(payer != address(0), "payer=0");
        require(payee != address(0), "payee=0");
        require(baseAmount > 0, "base=0");
        require(quoteAmount > 0, "quote=0");

        StorageLib.Storage storage s = StorageLib.getStorage();

        // 0) Flash loan
        s.realFreeCollateral[payee] += quoteAmount;
        s.realTotalFreeCollateral   += quoteAmount;

        // 1) Position delta: payee -> payer
        PositionTransferLib.transferPosition(
            payee,
            payer,
            marketId,
            positionId,
            isBack,
            baseAmount
        );


        // 3) Solvency checks (payee first, then payer)
        SolvencyLib.rebalanceFull(payee, marketId);
        SolvencyLib.rebalanceFull(payer, marketId);

        // 4) Repay flash loan
        s.realFreeCollateral[payer] -= quoteAmount;

        s.realTotalFreeCollateral   -= quoteAmount;
    }
}
