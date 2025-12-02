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
    /// - payerReceivesPosition: if true, positions flow payee -> payer, else payer -> payee
    function settleWithFlash(
        address payer,
        address payee,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 baseAmount,   // tokens
        uint256 quoteAmount,  // ppUSDC / USDC
        bool    payerReceivesPosition
    ) internal {
        require(payer != address(0), "payer=0");
        require(payee != address(0), "payee=0");
        require(baseAmount > 0, "base=0");
        require(quoteAmount > 0, "quote=0");

        StorageLib.Storage storage s = StorageLib.getStorage();

        // 0) Flash loan to payer
        s.realFreeCollateral[payer] += quoteAmount;
        s.realTotalFreeCollateral   += quoteAmount;

        // 1) Position delta
        if (payerReceivesPosition) {
            // payee -> payer
            PositionTransferLib.transferPosition(
                payee,
                payer,
                marketId,
                positionId,
                isBack,
                baseAmount
            );
        } else {
            // payer -> payee
            PositionTransferLib.transferPosition(
                payer,
                payee,
                marketId,
                positionId,
                isBack,
                baseAmount
            );
        }

        // 2) Net cash settlement: payer pays payee
        FreeCollateralLib.transferFreeCollateral(payer, payee, quoteAmount);

        // 3) Solvency on both sides.
        // Order: payee first, then payer (roughly matches your existing patterns).
        SolvencyLib.ensureSolvency(payee, marketId);
        SolvencyLib.deallocateExcess(payee, marketId);

        SolvencyLib.ensureSolvency(payer, marketId);
        SolvencyLib.deallocateExcess(payer, marketId);

        // 4) Repay flash loan
        s.realFreeCollateral[payer] -= quoteAmount;
        require(s.realFreeCollateral[payer] >= 0, "Flash loan repayment failed");

        s.realTotalFreeCollateral   -= quoteAmount;
        require(s.realTotalFreeCollateral >= 0, "Flash loan repayment failed");
    }
}
