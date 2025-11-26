// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./2_FreeCollateralLib.sol";
import "./7_PositionTransferLib.sol";
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
        // 1) Position delta first
        PositionTransferLib.transferPosition(
            mm,
            trader,
            marketId,
            positionId,
            isBack,
            tokensOut
        );

        // 2) Net cash settlement: trader pays mm (ppUSDC move only)
        FreeCollateralLib.transferFreeCollateral(trader, mm, usdcIn);
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

        // 2) Net cash settlement: mm pays trader (ppUSDC move only)
        FreeCollateralLib.transferFreeCollateral(mm, trader, usdcOut);
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
