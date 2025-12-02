// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./2_FreeCollateralLib.sol";
import "./7_PositionTransferLib.sol";
import "./4_SolvencyLib.sol";
import "../Interfaces/IMarketMaker.sol";
import "hardhat/console.sol"; // Add this

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
        // 1) Position delta first
        PositionTransferLib.transferPosition(
            mm,
            trader,
            marketId,
            positionId,
            isBack,
            tokensOut
        );

        // Log state after position transfer
        console.log("After position transfer: trader freeCollateral = %s, usdcIn = %s", StorageLib.getStorage().realFreeCollateral[trader], usdcIn);

        // 2) Flashloan
        FreeCollateralLib.mintPpUSDC(mm, usdcIn);

        // 3) Deallocate Excess so there is more free collateral
        SolvencyLib.deallocateExcess(trader, marketId);
        SolvencyLib.deallocateExcess(mm, marketId);

        // Log state after dealloc
        console.log("After dealloc: trader freeCollateral = %s, usdcIn = %s", StorageLib.getStorage().realFreeCollateral[trader], usdcIn);

        // 4) Repay Flashloan
        FreeCollateralLib.burnPpUSDC(trader, usdcIn);

        // Log state after payment
        console.log("After payment: trader freeCollateral = %s", StorageLib.getStorage().realFreeCollateral[trader]);

        // 4) Check both sides solvent still
        SolvencyLib.ensureSolvency(trader, marketId);
        SolvencyLib.ensureSolvency(mm, marketId);

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
        // 1) Position delta first
        PositionTransferLib.transferPosition(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            tokensIn
        );

        // 2) Flashloan
        FreeCollateralLib.mintPpUSDC(mm, usdcIn);
        
        // 2) Deallocate Excess so there is more free collateral
        SolvencyLib.deallocateExcess(trader, marketId);
        SolvencyLib.deallocateExcess(mm, marketId);

        // 3) Net cash settlement: mm pays trader (ppUSDC move only)
        FreeCollateralLib.transferFreeCollateral(mm, trader, usdcOut);

        // 4) Check both sides solvent still
        SolvencyLib.ensureSolvency(trader, marketId);
        SolvencyLib.ensureSolvency(mm, marketId);

     SolvencyLib.deallocateExcess(trader, marketId);
        SolvencyLib.deallocateExcess(mm, marketId);
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
