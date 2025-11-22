// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./FreeCollateralLib.sol";
import "./PositionTransferLib.sol";
import "../../Interfaces/IMarketMaker.sol";

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
        FreeCollateralLib.decreaseFreeCollateralWithEvent(trader, usdcIn);
        PositionTransferLib.transferPosition(
            mm,
            trader,
            marketId,
            positionId,
            isBack,
            tokensOut
        );
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
        PositionTransferLib.transferPosition(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            tokensIn
        );
        FreeCollateralLib.increaseFreeCollateralWithEvent(trader, usdcOut);
    }

    /*//////////////////////////////////////////////////////////////
                         LEDGER TRADE ENTRYPOINTS
    //////////////////////////////////////////////////////////////*/

    function buyExactTokens(
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) internal {
        require(t > 0, "t=0");
        address trader = msg.sender;

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
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) internal {
        require(usdcIn > 0, "usdcIn=0");
        address trader = msg.sender;

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
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) internal {
        require(t > 0, "t=0");
        address trader = msg.sender;

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
        address mm,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) internal {
        require(usdcOut > 0, "usdcOut=0");
        address trader = msg.sender;

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
