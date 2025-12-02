// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./7a_SettlementLib.sol";
import "../Interfaces/IMarketMaker.sol";

library TradeExecutionLib {
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

        // trader pays usdcIn, receives t tokens from mm
        SettlementLib.settleWithFlash(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            t,
            usdcIn,
            /* payerReceivesPosition = */ true
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

        // trader pays usdcIn, receives tokensOut from mm
        SettlementLib.settleWithFlash(
            trader,
            mm,
            marketId,
            positionId,
            isBack,
            tokensOut,
            usdcIn,
            /* payerReceivesPosition = */ true
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

    // mm pays usdcOut, receives t tokens from trader
    SettlementLib.settleWithFlash(
        mm,
        trader,
        marketId,
        positionId,
        isBack,
        t,
        usdcOut,
        /* payerReceivesPosition = */ true   // ✅ was false
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

    // mm pays usdcOut, receives tokensIn from trader
    SettlementLib.settleWithFlash(
        mm,
        trader,
        marketId,
        positionId,
        isBack,
        tokensIn,
        usdcOut,
        /* payerReceivesPosition = */ true   // ✅ was false
    );
}

}
