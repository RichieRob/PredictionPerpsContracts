// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AMMLibraries/IMarketMaker.sol";
import "./AMMLibraries/ILedgerPositions.sol";

/// @title VFMarketMaker
/// @notice Simple multi-outcome "virtual funds" AMM:
///         - Prices are derived from exposures x_i and virtual liquidity V.
///         - Supports "true lay" with layPrice = 1 - backPrice by using
///           the complete-set identity: LAY(i) = SET - BACK(i).
///
/// Fee model:
/// - Charges a flat 1% fee (100 bps) on *all buys* (both BACK and LAY),
///   applied on top of the AMM "fair" cost.
///
/// Notes:
/// - All position tokens use 6 decimals (like USDC).
/// - 1 position token redeems for 1 USDC if it wins (complete set costs 1 USDC).
/// - Sells are not supported externally here (your Ledger doesn't support them anyway).
contract VFMarketMaker is IMarketMaker {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant WAD_PER_USDC = 1e12; // 1e18 / 1e6

    uint256 internal constant FEE_BPS  = 100;      // 1%
    uint256 internal constant BPS_DENOM = 10_000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Market {
        bool    initialized;

        // Virtual liquidity (WAD-scaled "USDC units")
        uint256 V_wad;

        // Listed outcomes
        uint256[] listed;                  // positionIds
        mapping(uint256 => bool) isListed; // positionId => listed?
        uint256 N;                         // listed.length

        // Exposures (WAD-scaled)
        mapping(uint256 => uint256) x_wad; // exposure sold on BACK(i)
        uint256 sumX_wad;                  // sum of x_wad over listed
    }

    mapping(uint256 => Market) internal _m; // marketId => Market

    /*//////////////////////////////////////////////////////////////
                           GOVERNANCE / ACCESS
    //////////////////////////////////////////////////////////////*/

    address public immutable governor;
    ILedgerPositions public immutable ledger;

    modifier onlyGovernor() {
        require(msg.sender == governor, "VF: not governor");
        _;
    }

    constructor(address _governor, address _ledger) {
        require(_governor != address(0), "VF: bad governor");
        require(_ledger != address(0), "VF: bad ledger");
        governor = _governor;
        ledger   = ILedgerPositions(_ledger);
    }

    /*//////////////////////////////////////////////////////////////
                         MARKET INITIALISATION / LISTING
    //////////////////////////////////////////////////////////////*/

    function initMarket(
        uint256 marketId,
        uint256[] calldata initialPositions,
        uint256 virtualLiquidityUSDC
    ) external onlyGovernor {
        Market storage mk = _m[marketId];
        require(!mk.initialized, "VF: already init");
        require(initialPositions.length >= 2, "VF: need >=2 outcomes");
        require(virtualLiquidityUSDC > 0, "VF: V=0");

        mk.initialized = true;
        mk.V_wad = virtualLiquidityUSDC * WAD_PER_USDC;

        for (uint256 i = 0; i < initialPositions.length; i++) {
            _listPosition(mk, marketId, initialPositions[i]);
        }
    }

    function listPosition(uint256 marketId, uint256 ledgerPositionId) external onlyGovernor {
        Market storage mk = _mustMarket(marketId);
        _listPosition(mk, marketId, ledgerPositionId);
    }

    function _listPosition(Market storage mk, uint256 marketId, uint256 posId) internal {
        require(!mk.isListed[posId], "VF: already listed");
        require(ledger.positionExists(marketId, posId), "VF: ledger pos missing");

        mk.isListed[posId] = true;
        mk.listed.push(posId);
        mk.N = mk.listed.length;
    }

    /*//////////////////////////////////////////////////////////////
                                     VIEWS
    //////////////////////////////////////////////////////////////*/

    function listSlots(uint256 marketId) external view override returns (uint256[] memory) {
        Market storage mk = _mustMarketView(marketId);
        return mk.listed;
    }

    /// @notice Denominator D = N*V + sumX (WAD)
    function getZ(uint256 marketId) external view override returns (uint256) {
        Market storage mk = _mustMarketView(marketId);
        return _denom(mk);
    }

    function getBackPriceWad(uint256 marketId, uint256 positionId)
        external
        view
        override
        returns (uint256)
    {
        Market storage mk = _mustMarketView(marketId);
        _requireListed(mk, positionId);
        return _backPriceWad(mk, positionId);
    }

    function getLayPriceWad(uint256 marketId, uint256 positionId)
        external
        view
        override
        returns (uint256)
    {
        Market storage mk = _mustMarketView(marketId);
        _requireListed(mk, positionId);
        uint256 p = _backPriceWad(mk, positionId);
        return WAD - p;
    }

    function getAllBackPricesWad(uint256 marketId)
        external
        view
        override
        returns (
            uint256[] memory positionIds,
            uint256[] memory priceWads,
            uint256 reservePriceWad
        )
    {
        Market storage mk = _mustMarketView(marketId);
        uint256 len = mk.listed.length;

        positionIds = new uint256[](len);
        priceWads   = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 posId = mk.listed[i];
            positionIds[i] = posId;
            priceWads[i]   = _backPriceWad(mk, posId);
        }

        reservePriceWad = 0;
    }

    function getAllLayPricesWad(uint256 marketId)
        external
        view
        override
        returns (
            uint256[] memory positionIds,
            uint256[] memory priceWads
        )
    {
        Market storage mk = _mustMarketView(marketId);
        uint256 len = mk.listed.length;

        positionIds = new uint256[](len);
        priceWads   = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 posId = mk.listed[i];
            positionIds[i] = posId;
            priceWads[i]   = WAD - _backPriceWad(mk, posId);
        }
    }

    function getReservePriceWad(uint256 marketId) external view override returns (uint256) {
        marketId; // silence unused
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                       IMarketMaker – BUYS ONLY
    //////////////////////////////////////////////////////////////*/

    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external override returns (uint256 usdcIn) {
        Market storage mk = _mustMarket(marketId);
        _requireListed(mk, positionId);

        // Compute AMM "fair" base cost first, then add fee on top.
        uint256 baseCost;
        if (isBack) {
            baseCost = _buyBackExactBase(mk, positionId, t);
        } else {
            // BUY LAY(i,t) = pay t for a complete set, then SELL BACK(i,t) into AMM
            // Net base cost = t - usdcOutFromSellBack
            baseCost = _buyLayExactBase(mk, positionId, t);
        }

        uint256 fee = _feeOnTop(baseCost);
        usdcIn = baseCost + fee;

        require(usdcIn <= maxUSDCIn, "VF: slippage buy");
    }

    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external override returns (uint256 tokensOut) {
        Market storage mk = _mustMarket(marketId);
        _requireListed(mk, positionId);

        // User provides total spend INCLUDING fee.
        // If fee is "on top of base", then:
        //   gross = base + ceil(base*feeBps/10_000)
        // We conservatively floor the base budget to never exceed gross.
        uint256 baseBudget = (usdcIn * BPS_DENOM) / (BPS_DENOM + FEE_BPS);

        if (isBack) {
            tokensOut = _buyBackForUSDCBase(mk, positionId, baseBudget);
        } else {
            tokensOut = _buyLayForUSDCBase(mk, positionId, baseBudget);
        }

        require(tokensOut >= minTokensOut, "VF: min tokens");
    }

    /*//////////////////////////////////////////////////////////////
                              CORE PRICING
    //////////////////////////////////////////////////////////////*/

    function _denom(Market storage mk) internal view returns (uint256 D_wad) {
        D_wad = mk.N * mk.V_wad + mk.sumX_wad;
        require(D_wad > 0, "VF: bad denom");
    }

    function _backPriceWad(Market storage mk, uint256 posId) internal view returns (uint256) {
        uint256 D  = _denom(mk);
        uint256 xi = mk.x_wad[posId];

        // BACK(i) = (V + x_i) / (N*V + sumX)
        uint256 num = mk.V_wad + xi;
        return (num * WAD) / D;
    }

    /*//////////////////////////////////////////////////////////////
                       BUY EXECUTION (BASE, NO FEE)
    //////////////////////////////////////////////////////////////*/

    /// @dev Executes BUY BACK exact `t_usdc` and returns BASE cost (no fee).
    function _buyBackExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal returns (uint256 baseUSDCIn) {
        uint256 t_wad = t_usdc * WAD_PER_USDC;

        uint256 b  = _denom(mk);           // b = N*V + sumX
        uint256 xi = mk.x_wad[posId];
        uint256 a  = mk.V_wad + xi;        // a = V + x_i

        // cost_wad = ∫ (a+q)/(b+q) dq from 0..t
        //          = t - (b-a) * ln((b+t)/b)
        uint256 ba = b - a; // (N-1)V + (sumX - xi) >= 0

        int256 lnTerm = FixedPointMathLib.lnWad(int256(((b + t_wad) * WAD) / b));
        require(lnTerm >= 0, "VF: ln<0");

        uint256 cost_wad = t_wad - ((ba * uint256(lnTerm)) / WAD);
        baseUSDCIn = _wadToUsdcRoundUp(cost_wad);

        // update state
        mk.x_wad[posId] = xi + t_wad;
        mk.sumX_wad     = mk.sumX_wad + t_wad;
    }

    /// @dev Executes BUY LAY exact `t_usdc` and returns BASE net cost (no fee).
    function _buyLayExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal returns (uint256 baseUSDCIn) {
        // Base model:
        // Buy a complete set for t, then SELL BACK(t) into the AMM.
        // Net base cost = t - usdcOutFromSellBack.
        uint256 usdcOutBack = _sellBackExactBase(mk, posId, t_usdc);
        baseUSDCIn = (t_usdc > usdcOutBack) ? (t_usdc - usdcOutBack) : 0;
    }

    /// @dev Internal primitive used only to implement "true lay" buys.
    ///      Executes SELL BACK exact `t_usdc`, returns USDC out (base, no fee).
    function _sellBackExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal returns (uint256 usdcOut) {
        uint256 t_wad = t_usdc * WAD_PER_USDC;

        uint256 xi = mk.x_wad[posId];
        require(xi >= t_wad, "VF: not enough exposure");

        uint256 b = _denom(mk);
        require(b > t_wad, "VF: D too small");

        uint256 a  = mk.V_wad + xi;
        uint256 ba = b - a;

        // out_wad = ∫ (a-q)/(b-q) dq from 0..t
        //         = t - (b-a) * ln(b/(b-t))
        int256 lnTerm = FixedPointMathLib.lnWad(int256((b * WAD) / (b - t_wad)));
        require(lnTerm >= 0, "VF: ln<0");

        uint256 out_wad = t_wad - ((ba * uint256(lnTerm)) / WAD);
        usdcOut = _wadToUsdcRoundDown(out_wad);

        // update state
        mk.x_wad[posId] = xi - t_wad;
        mk.sumX_wad     = mk.sumX_wad - t_wad;
    }

    /*//////////////////////////////////////////////////////////////
                          BUY-FOR-USDC (BASE)
    //////////////////////////////////////////////////////////////*/

    function _buyBackForUSDCBase(
        Market storage mk,
        uint256 posId,
        uint256 baseBudgetUSDC
    ) internal returns (uint256 tokensOut) {
        tokensOut = _solveBuyBackTokensOutBase(mk, posId, baseBudgetUSDC);
        uint256 spent = _buyBackExactBase(mk, posId, tokensOut);
        require(spent <= baseBudgetUSDC, "VF: baseBudget");
    }

    function _buyLayForUSDCBase(
        Market storage mk,
        uint256 posId,
        uint256 baseBudgetUSDC
    ) internal returns (uint256 tokensOut) {
        tokensOut = _solveBuyLayTokensOutBase(mk, posId, baseBudgetUSDC);

        uint256 usdcOutBack = _sellBackExactBase(mk, posId, tokensOut);
        uint256 netIn = (tokensOut > usdcOutBack) ? (tokensOut - usdcOutBack) : 0;
        require(netIn <= baseBudgetUSDC, "VF: baseBudget");
    }

    /*//////////////////////////////////////////////////////////////
                           SOLVERS (BINARY SEARCH)
    //////////////////////////////////////////////////////////////*/

    function _solveBuyBackTokensOutBase(
        Market storage mk,
        uint256 posId,
        uint256 baseBudgetUSDC
    ) internal view returns (uint256 t_usdc) {
        uint256 lo = 0;
        uint256 hi = baseBudgetUSDC * 1000 + 1; // generous

        for (uint256 i = 0; i < 64; i++) {
            uint256 mid = (lo + hi) >> 1;
            uint256 cost = _previewBuyBackExactBase(mk, posId, mid);
            if (cost <= baseBudgetUSDC) lo = mid;
            else hi = mid;
        }

        t_usdc = lo;
    }

    function _solveBuyLayTokensOutBase(
        Market storage mk,
        uint256 posId,
        uint256 baseBudgetUSDC
    ) internal view returns (uint256 t_usdc) {
        // cost(t) = t - sellBackOut(t)
        uint256 lo = 0;
        uint256 hi = baseBudgetUSDC * 1000 + 1;

        for (uint256 i = 0; i < 64; i++) {
            uint256 mid = (lo + hi) >> 1;
            uint256 outBack = _previewSellBackExactBase(mk, posId, mid);
            uint256 cost = (mid > outBack) ? (mid - outBack) : 0;
            if (cost <= baseBudgetUSDC) lo = mid;
            else hi = mid;
        }

        t_usdc = lo;
    }

    function _previewBuyBackExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal view returns (uint256 usdcIn) {
        uint256 t_wad = t_usdc * WAD_PER_USDC;

        uint256 b = mk.N * mk.V_wad + mk.sumX_wad;
        if (b == 0) return type(uint256).max;

        uint256 xi = mk.x_wad[posId];
        uint256 a  = mk.V_wad + xi;
        uint256 ba = b - a;

        int256 lnTerm = FixedPointMathLib.lnWad(int256(((b + t_wad) * WAD) / b));
        if (lnTerm < 0) return type(uint256).max;

        uint256 cost_wad = t_wad - ((ba * uint256(lnTerm)) / WAD);
        usdcIn = _wadToUsdcRoundUp(cost_wad);
    }

    function _previewSellBackExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal view returns (uint256 usdcOut) {
        uint256 t_wad = t_usdc * WAD_PER_USDC;

        uint256 xi = mk.x_wad[posId];
        if (xi < t_wad) return 0;

        uint256 b = mk.N * mk.V_wad + mk.sumX_wad;
        if (b <= t_wad) return 0;

        uint256 a  = mk.V_wad + xi;
        uint256 ba = b - a;

        int256 lnTerm = FixedPointMathLib.lnWad(int256((b * WAD) / (b - t_wad)));
        if (lnTerm < 0) return 0;

        uint256 out_wad = t_wad - ((ba * uint256(lnTerm)) / WAD);
        usdcOut = _wadToUsdcRoundDown(out_wad);
    }

    /*//////////////////////////////////////////////////////////////
                              FEE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Fee charged "on top" of base cost. Rounded up so you don't undercharge.
    function _feeOnTop(uint256 baseCostUSDC) internal pure returns (uint256) {
        // ceil(base * feeBps / 10_000)
        return (baseCostUSDC * FEE_BPS + (BPS_DENOM - 1)) / BPS_DENOM;
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _wadToUsdcRoundUp(uint256 wadAmount) internal pure returns (uint256) {
        return (wadAmount + (WAD_PER_USDC - 1)) / WAD_PER_USDC;
    }

    function _wadToUsdcRoundDown(uint256 wadAmount) internal pure returns (uint256) {
        return wadAmount / WAD_PER_USDC;
    }

    function _mustMarket(uint256 marketId) internal view returns (Market storage mk) {
        mk = _m[marketId];
        require(mk.initialized, "VF: market not init");
    }

    function _mustMarketView(uint256 marketId) internal view returns (Market storage mk) {
        mk = _m[marketId];
        require(mk.initialized, "VF: market not init");
    }

    function _requireListed(Market storage mk, uint256 posId) internal view {
        require(mk.isListed[posId], "VF: pos not listed");
    }
}

/*//////////////////////////////////////////////////////////////
                    Minimal fixed-point lnWad
//////////////////////////////////////////////////////////////*/

library FixedPointMathLib {
    uint256 internal constant WAD = 1e18;

    function lnWad(int256 x) internal pure returns (int256 r) {
        require(x > 0, "lnWad: x<=0");
        uint256 ux = uint256(x);

        int256 k = 0;
        while (ux < WAD) { ux <<= 1; k -= 1; }
        while (ux >= 2 * WAD) { ux >>= 1; k += 1; }

        int256 u = int256(ux);
        int256 z = ((u - int256(WAD)) * int256(WAD)) / (u + int256(WAD)); // WAD
        int256 z2 = (z * z) / int256(WAD);
        int256 z3 = (z2 * z) / int256(WAD);
        int256 z5 = (z3 * z2) / int256(WAD);

        int256 series = z + (z3 / 3) + (z5 / 5);
        int256 lnU = 2 * series;

        int256 LN2_WAD = 693147180559945309; // ~0.693147...
        r = lnU + k * LN2_WAD;
    }
}
