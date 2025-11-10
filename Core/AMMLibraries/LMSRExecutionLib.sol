// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../LMSRMarketMaker.sol";
import "./LMSRQuoteLib.sol";
import "./LMSRUpdateLib.sol";
import "./LMSRHelpersLib.sol";

/// @title LMSRExecutionLib
/// @notice Library for execution-related functions in LMSRMarketMaker (buy/sell trades).
// attention needed to how we manage the fee. currently its just sent to the ledger and added to deposits
library LMSRExecutionLib {
    /// @notice Internal implementation for buying exact t tokens.
    function buyInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t,
        uint256 maxUSDCIn,
        bool usePermit2,
        bytes calldata permitBlob
    ) internal returns (uint256 mFinal) {
        require(t > 0, "t=0");
        require(self.initialized[marketId], "not initialized");
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        uint256 mNoFee = LMSRQuoteLib.quoteBuyInternal(self, marketId, ledgerPositionId, isBack, t);
        mFinal = (mNoFee * (10_000 + LMSRMarketMaker.FEE_BPS)) / 10_000;
        require(mFinal <= maxUSDCIn, "slippage");

        // Pull funds + mint via ledger (passing the *ledger* positionId)
        self.ledger.processBuy(msg.sender, marketId, self.mmId[marketId], ledgerPositionId, isBack, mFinal, t, 0, usePermit2, permitBlob);

        // O(1) state update
        LMSRUpdateLib.applyUpdateInternal(self, marketId, slot, isBack, true, t);

        emit LMSRMarketMaker.Trade(msg.sender, ledgerPositionId, isBack, t, mFinal, true);
        emit LMSRMarketMaker.PriceUpdated(ledgerPositionId, LMSRViewLib.getBackPriceWadInternal(self, marketId, ledgerPositionId));
    }

    /// @notice Internal implementation for buying with exact USDC amount.
    function buyForUSDCInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 usdcIn,
        uint256 tMax,
        uint256 minTokensOut,
        bool usePermit2,
        bytes calldata permitBlob
    ) internal returns (uint256 tOut) {
        require(self.initialized[marketId], "not initialized");
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        tOut = LMSRQuoteLib.quoteBuyForUSDCInternal(self, marketId, ledgerPositionId, isBack, usdcIn);
        require(tOut >= minTokensOut && tOut > 0, "slippage");

        self.ledger.processBuy(msg.sender, marketId, self.mmId[marketId], ledgerPositionId, isBack, usdcIn, tOut, 0, usePermit2, permitBlob);

        LMSRUpdateLib.applyUpdateInternal(self, marketId, slot, isBack, true, tOut);

        emit LMSRMarketMaker.Trade(msg.sender, ledgerPositionId, isBack, tOut, usdcIn, true);
        emit LMSRMarketMaker.PriceUpdated(ledgerPositionId, LMSRViewLib.getBackPriceWadInternal(self, marketId, ledgerPositionId));
    }

    /// @notice Internal implementation for selling exact t tokens.
    function sellInternal(
        LMSRMarketMaker self,
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t,
        uint256 minUSDCOut
    ) internal returns (uint256 usdcOut) {
        require(t > 0, "t=0");
        require(self.initialized[marketId], "not initialized");
        uint256 slot = LMSRHelpersLib.requireListed(self, marketId, ledgerPositionId);

        uint256 mNoFee = LMSRQuoteLib.quoteSellInternal(self, marketId, ledgerPositionId, isBack, t);
        usdcOut = (mNoFee * (10_000 - LMSRMarketMaker.FEE_BPS)) / 10_000;
        require(usdcOut >= minUSDCOut, "slippage");

        self.ledger.processSell(msg.sender, marketId, self.mmId[marketId], ledgerPositionId, isBack, t, usdcOut);

        LMSRUpdateLib.applyUpdateInternal(self, marketId, slot, isBack, false, t);

        emit LMSRMarketMaker.Trade(msg.sender, ledgerPositionId, isBack, t, usdcOut, false);
        emit LMSRMarketMaker.PriceUpdated(ledgerPositionId, LMSRViewLib.getBackPriceWadInternal(self, marketId, ledgerPositionId));
    }
}

