// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./2_FreeCollateralLib.sol";
import "./7_PositionTransferLib.sol";
import "./4_SolvencyLib.sol";
import "../Interfaces/IMarketMaker.sol";

library TradeExecutionLib {

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function processBuy(
    address trader,
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 usdcIn,
    uint256 tokensOut
) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();

    // 0) Flash loan: boost trader freeCollateral
    s.realFreeCollateral[trader] += usdcIn;
    s.realTotalFreeCollateral += usdcIn;  
    // 1) Position delta first
    PositionTransferLib.transferPosition(
        mm,
        trader,
        marketId,
        positionId,
        isBack,
        tokensOut
    );

    // 2) Net cash settlement
    FreeCollateralLib.transferFreeCollateral(trader, mm, usdcIn);

    // Clean up mm side
    SolvencyLib.ensureSolvency(mm, marketId);
    SolvencyLib.deallocateExcess(mm, marketId);


    // Clean up trader side
    SolvencyLib.ensureSolvency(trader, marketId);
    SolvencyLib.deallocateExcess(trader, marketId);  // Re-check mm post-trader changes

   // 3) Repay flash loan
    s.realFreeCollateral[trader] -= usdcIn;
    require(s.realFreeCollateral[trader] >= 0, "Flash loan repayment failed");
    s.realTotalFreeCollateral -= usdcIn;
    require(s.realTotalFreeCollateral >= 0, "Flash loan repayment failed");

}

    function processSell(
        address trader,
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 tokensIn,
        uint256 usdcOut
    ) internal {

        // 0) Flash Loan to mm
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.realFreeCollateral[mm] += usdcOut;  // Use int256 for safety
        s.realTotalFreeCollateral += usdcOut;  



        // 1) Position delta first
        PositionTransferLib.transferPosition(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            tokensIn
        );

        // 2) Net cash settlement: mm pays trader (ppUSDC move only)
        FreeCollateralLib.transferFreeCollateral(mm, trader, usdcOut);

        // 3) Clear up trader side
        SolvencyLib.ensureSolvency(trader, marketId);
        SolvencyLib.deallocateExcess(trader, marketId);

        // 3) Check both sides solvent still
        SolvencyLib.ensureSolvency(mm, marketId);
        SolvencyLib.deallocateExcess(mm, marketId);

        //4) Repay flashloan
        s.realFreeCollateral[mm] -= usdcOut;
          
        require(s.realFreeCollateral[mm] >= 0, "Flash loan repayment failed");
        s.realTotalFreeCollateral -= usdcOut;
        require(s.realTotalFreeCollateral >= 0, "Flash loan repayment failed");
    }

    /*//////////////////////////////////////////////////////////////
                         LEDGER TRADE ENTRYPOINTS
    //////////////////////////////////////////////////////////////*/

    function buyExactTokens(
        address trader,
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) internal {
        require(t > 0, "t=0");

        uint256 usdcIn = IMarketMaker(mm).applyBuyExactTokens(
            marketId,
            positionId,
            isBack,
            t,
            maxUSDCIn
        );

        processBuy(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            usdcIn,
            t
        );
    }

    function buyForUSDC(
        address trader,
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) internal {
        require(usdcIn > 0, "usdcIn=0");

        uint256 tokensOut = IMarketMaker(mm).applyBuyForUSDC(
            marketId,
            positionId,
            isBack,
            usdcIn,
            minTokensOut
        );

        processBuy(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            usdcIn,
            tokensOut
        );
    }

    function sellExactTokens(
        address trader,
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) internal {
        require(t > 0, "t=0");

        uint256 usdcOut = IMarketMaker(mm).applySellExactTokens(
            marketId,
            positionId,
            isBack,
            t,
            minUSDCOut
        );

        processSell(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            t,
            usdcOut
        );
    }

    function sellForUSDC(
        address trader,
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) internal {
        require(usdcOut > 0, "usdcOut=0");

        uint256 tokensIn = IMarketMaker(mm).applySellForUSDC(
            marketId,
            positionId,
            isBack,
            usdcOut,
            maxTokensIn
        );

        processSell(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            tokensIn,
            usdcOut
        );
    }
}
