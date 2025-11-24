// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Types {
    uint256 constant BLOCK_SIZE = 16;

    /// @notice Generic per-block extremum data.
    /// Used for both:
    ///   - minBlockData (min-heap)  → (id, val) = (minId, minTilt)
    ///   - blockDataMax (max-heap) → (id, val) = (maxId, maxTilt)
    struct BlockData {
        uint256 id;
        int256  val;
    }

    struct TokenData {
        uint64 marketId;
        uint64 positionId;
        bool   isBack;
    }

        // 🆕 Trade kinds for routing
    enum TradeKind {
        BUY_EXACT_TOKENS,
        BUY_FOR_USDC,
        SELL_EXACT_TOKENS,
        SELL_FOR_USDC
    }

        struct Intent {
        address trader;
        uint256 marketId;
        uint256 positionId;
        bool    isBack;
        TradeKind kind;
        uint256 primaryAmount; // t or usdc depending on kind
        uint256 bound;         // slippage bound (maxUSDCIn / minTokensOut / etc.)
        uint256 nonce;
        uint256 deadline;
    }


}