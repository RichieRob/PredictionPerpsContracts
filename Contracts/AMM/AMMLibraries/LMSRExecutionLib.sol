// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LMSRStorageLib.sol";
import "./LMSRQuoteLib.sol";
import "./LMSRUpdateLib.sol";
import "./LMSRViewLib.sol";
import "./LMSRTwapLib.sol";

/// @title LMSRExecutionLib
/// @notice Thin orchestration layer for trades:
///         - guard checks
///         - TWAP before/after
///         - quote via LMSRQuoteLib
///         - state update via LMSRUpdateLib
///         - emits Trade / PriceUpdated events
///
/// @dev All heavy maths lives in LMSRMathLib / LMSRQuoteLib / LMSRUpdateLib.
///      This library just wires them together so the main contract stays small.
library LMSRExecutionLib {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event Trade(
        address indexed user,
        uint256 indexed ledgerPositionId,
        bool    isBack,
        uint256 tokens,
        uint256 usdcAmount,
        bool    isBuy
    );

    event PriceUpdated(
        uint256 indexed ledgerPositionId,
        uint256 pBackWad
    );

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fetch market + require listed position, returning slot.
    function _requireMarketAndSlot(
        LMSRStorageLib.State storage s,
        uint256               marketId,
        uint256               ledgerPositionId
    ) private view returns (LMSRStorageLib.Market storage m, uint256 slot) {
        m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");
        slot = LMSRStorageLib.requireListed(m, ledgerPositionId);
    }

    /*//////////////////////////////////////////////////////////////
                              PUBLIC ENTRYPOINTS
    //////////////////////////////////////////////////////////////*/

    function buyExactTokens(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) internal returns (uint256 usdcIn) {
        require(t > 0, "LMSR: t=0");

        (LMSRStorageLib.Market storage m, uint256 slot) =
            _requireMarketAndSlot(s, marketId, ledgerPositionId);

        // TWAP before price change
        LMSRTwapLib.updateBeforePriceChange(s, marketId, slot);

        // Price the trade (with fee)
        usdcIn = LMSRQuoteLib.quoteBuyInternal(
            s,
            marketId,
            ledgerPositionId,
            isBack,
            t
        );
        require(usdcIn <= maxUSDCIn, "LMSR: slippage");

        // Apply O(1) state update
        LMSRUpdateLib.applyUpdateInternal(
            s,
            marketId,
            slot,
            isBack,
            true,   // isBuy
            t
        );

        // TWAP after price change
        LMSRTwapLib.updateAfterPriceChange(s, marketId, slot);

        uint256 pBackWad = LMSRViewLib.getBackPriceWad(
            s,
            marketId,
            ledgerPositionId
        );

        emit Trade(msg.sender, ledgerPositionId, isBack, t, usdcIn, true);
        emit PriceUpdated(ledgerPositionId, pBackWad);
    }

    function buyForUSDC(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) internal returns (uint256 tokensOut) {
        require(usdcIn > 0, "LMSR: usdcIn=0");

        (, uint256 slot) =
            _requireMarketAndSlot(s, marketId, ledgerPositionId);

        LMSRTwapLib.updateBeforePriceChange(s, marketId, slot);

        tokensOut = LMSRQuoteLib.quoteBuyForUSDCInternal(
            s,
            marketId,
            ledgerPositionId,
            isBack,
            usdcIn
        );
        require(tokensOut > 0 && tokensOut >= minTokensOut, "LMSR: slippage");

        LMSRUpdateLib.applyUpdateInternal(
            s,
            marketId,
            slot,
            isBack,
            true, // isBuy
            tokensOut
        );

        LMSRTwapLib.updateAfterPriceChange(s, marketId, slot);

        uint256 pBackWad = LMSRViewLib.getBackPriceWad(
            s,
            marketId,
            ledgerPositionId
        );

        emit Trade(msg.sender, ledgerPositionId, isBack, tokensOut, usdcIn, true);
        emit PriceUpdated(ledgerPositionId, pBackWad);
    }

    function sellExactTokens(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) internal returns (uint256 usdcOut) {
        require(t > 0, "LMSR: t=0");

        (, uint256 slot) =
            _requireMarketAndSlot(s, marketId, ledgerPositionId);

        LMSRTwapLib.updateBeforePriceChange(s, marketId, slot);

        usdcOut = LMSRQuoteLib.quoteSellInternal(
            s,
            marketId,
            ledgerPositionId,
            isBack,
            t
        );
        require(usdcOut >= minUSDCOut, "LMSR: slippage");

        LMSRUpdateLib.applyUpdateInternal(
            s,
            marketId,
            slot,
            isBack,
            false, // isBuy = false (sell)
            t
        );

        LMSRTwapLib.updateAfterPriceChange(s, marketId, slot);

        uint256 pBackWad = LMSRViewLib.getBackPriceWad(
            s,
            marketId,
            ledgerPositionId
        );

        emit Trade(msg.sender, ledgerPositionId, isBack, t, usdcOut, false);
        emit PriceUpdated(ledgerPositionId, pBackWad);
    }

    function sellForUSDC(
        LMSRStorageLib.State storage s,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) internal returns (uint256 tokensIn) {
        require(usdcOut > 0, "LMSR: usdcOut=0");

        (, uint256 slot) =
            _requireMarketAndSlot(s, marketId, ledgerPositionId);

        LMSRTwapLib.updateBeforePriceChange(s, marketId, slot);

        uint256 tRequired = LMSRQuoteLib.quoteSellForUSDCInternal(
            s,
            marketId,
            ledgerPositionId,
            isBack,
            usdcOut
        );
        require(tRequired > 0 && tRequired <= maxTokensIn, "LMSR: slippage");

        tokensIn = tRequired;

        LMSRUpdateLib.applyUpdateInternal(
            s,
            marketId,
            slot,
            isBack,
            false, // isBuy = false (sell)
            tokensIn
        );

        LMSRTwapLib.updateAfterPriceChange(s, marketId, slot);

        uint256 pBackWad = LMSRViewLib.getBackPriceWad(
            s,
            marketId,
            ledgerPositionId
        );

        emit Trade(msg.sender, ledgerPositionId, isBack, tokensIn, usdcOut, false);
        emit PriceUpdated(ledgerPositionId, pBackWad);
    }
}
