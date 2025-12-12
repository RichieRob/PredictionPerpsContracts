// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Unified MarketMaker interface used by the Ledger and frontends.
///         - Execution functions are REQUIRED.
///         - View functions are OPTIONAL but strongly recommended.
///         - Implementations may revert on unsupported functions.
interface IMarketMaker {
    /*//////////////////////////////////////////////////////////////
                            EXECUTION (LEDGER)
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy exactly `t` position tokens (1e6 units),
    ///         paying up to `maxUSDCIn` (1e6).
    /// @return usdcIn Total USDC paid (1e6), INCLUDING any AMM fee.
    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external returns (uint256 usdcIn);

    /// @notice Spend exactly `usdcIn` (1e6) to buy as many tokens as possible.
    /// @dev `usdcIn` is TOTAL spend INCLUDING fee.
    /// @return tokensOut Tokens bought (1e6).
    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external returns (uint256 tokensOut);

    /*//////////////////////////////////////////////////////////////
                                PRICES (VIEWS)
    //////////////////////////////////////////////////////////////*/

    /// @notice BACK price p(i) in 1e18.
    function getBackPriceWad(
        uint256 marketId,
        uint256 positionId
    ) external view returns (uint256);

    /// @notice True LAY price = 1 - p(i) in 1e18.
    function getLayPriceWad(
        uint256 marketId,
        uint256 positionId
    ) external view returns (uint256);

    /// @notice Batched BACK prices.
    /// @return positionIds Ledger position IDs
    /// @return priceWads   BACK prices in 1e18
    /// @return reservePriceWad Optional “other / reserve” price (0 if unused)
    function getAllBackPricesWad(
        uint256 marketId
    )
        external
        view
        returns (
            uint256[] memory positionIds,
            uint256[] memory priceWads,
            uint256 reservePriceWad
        );

    /// @notice Batched LAY prices (true lay = 1 − back).
    function getAllLayPricesWad(
        uint256 marketId
    )
        external
        view
        returns (
            uint256[] memory positionIds,
            uint256[] memory priceWads
        );

    /// @notice Informational reserve / “other” price (1e18).
    /// @dev Return 0 if the AMM has no reserve bucket.
    function getReservePriceWad(
        uint256 marketId
    ) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                           MARKET STRUCTURE (VIEWS)
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the listed ledger position IDs for this market.
    function listSlots(
        uint256 marketId
    ) external view returns (uint256[] memory);

    /// @notice Return AMM internal normalization constant (e.g. Z, D, etc).
    /// @dev Purely informational; semantics are AMM-specific.
    function getZ(
        uint256 marketId
    ) external view returns (uint256);
}
