// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AMMLibraries/IMarketMaker.sol";
import "./AMMLibraries/ILedgerPositions.sol";

/// @title NormalizedLinearInventoryMarketMaker
/// @notice O(1) multi-outcome AMM:
///         - Each outcome i has a fixed prior weight w_i and variable exposure x_i (BACK sold).
///         - Define score y_i = w_i + k * x_i, and global sumY = sumW + k * sumX.
///         - BACK price p(i) = y_i / sumY, LAY price = 1 - p(i).
///
///         Trades update only {x_i, sumX} (O(1)); no loops in execution.
///
/// Fee model:
/// - Charges a flat 1% fee (100 bps) on *all buys* (both BACK and LAY),
///   applied on top of the AMM "fair" cost.
///
/// Notes:
/// - All position tokens use 6 decimals (like USDC).
/// - 1 position token redeems for 1 USDC if it wins (complete set costs 1 USDC).
/// - External sells are not supported; LAY buys are implemented using:
///       BUY LAY(i,t) = pay t for complete set, then SELL BACK(i,t) into AMM (internal).
contract NormalizedLinearInventoryMarketMaker is IMarketMaker {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;
    uint256 internal constant WAD_PER_USDC = 1e12; // 1e18 / 1e6

    uint256 internal constant FEE_BPS   = 100;     // 1%
    uint256 internal constant BPS_DENOM = 10_000;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct Market {
        bool initialized;

        // k parameter (WAD). Score is: y = w + (k * x / WAD).
        // - k = 1e18 means y increases 1:1 with x (in WAD).
        uint256 k_wad;

        // Listed outcomes
        uint256[] listed;                  // positionIds
        mapping(uint256 => bool) isListed; // positionId => listed?
        uint256 N;                         // listed.length

        // Priors (WAD) and exposures (WAD)
        mapping(uint256 => uint256) w_wad; // fixed prior weight per outcome
        uint256 sumW_wad;                  // sum of w_wad over listed

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
        require(msg.sender == governor, "NLI: not governor");
        _;
    }

    constructor(address _governor, address _ledger) {
        require(_governor != address(0), "NLI: bad governor");
        require(_ledger != address(0), "NLI: bad ledger");
        governor = _governor;
        ledger   = ILedgerPositions(_ledger);
    }

    /*//////////////////////////////////////////////////////////////
                         MARKET INITIALISATION / LISTING
    //////////////////////////////////////////////////////////////*/

    struct InitialPosition {
        uint256 positionId;
        uint256 priorWad; // WAD
    }

    /// @notice Initialize market with priors and k.
    /// @param marketId Market identifier shared with the ledger.
    /// @param initialPositions Array of {positionId, priorWad}.
    /// @param kWad Score slope (WAD). kWad=1e18 => y increases 1:1 with x.
    function initMarket(
        uint256 marketId,
        InitialPosition[] calldata initialPositions,
        uint256 kWad
    ) external onlyGovernor {
        Market storage mk = _m[marketId];
        require(!mk.initialized, "NLI: already init");
        require(initialPositions.length >= 2, "NLI: need >=2 outcomes");
        require(kWad > 0, "NLI: k=0");

        mk.initialized = true;
        mk.k_wad = kWad;

        for (uint256 i = 0; i < initialPositions.length; i++) {
            _listPosition(mk, marketId, initialPositions[i].positionId, initialPositions[i].priorWad);
        }
    }

    /// @notice List a position with a prior weight (can be 0, but normally > 0).
    function listPosition(
        uint256 marketId,
        uint256 ledgerPositionId,
        uint256 priorWad
    ) external onlyGovernor {
        Market storage mk = _mustMarket(marketId);
        _listPosition(mk, marketId, ledgerPositionId, priorWad);
    }

    function _listPosition(
        Market storage mk,
        uint256 marketId,
        uint256 posId,
        uint256 priorWad
    ) internal {
        require(!mk.isListed[posId], "NLI: already listed");
        require(ledger.positionExists(marketId, posId), "NLI: ledger pos missing");

        mk.isListed[posId] = true;
        mk.listed.push(posId);
        mk.N = mk.listed.length;

        mk.w_wad[posId] = priorWad;
        mk.sumW_wad += priorWad;
    }

    /*//////////////////////////////////////////////////////////////
                                     VIEWS
    //////////////////////////////////////////////////////////////*/

    function listSlots(uint256 marketId) external view override returns (uint256[] memory) {
        Market storage mk = _mustMarketView(marketId);
        return mk.listed;
    }

    /// @notice Z = sumY in WAD (informational).
    function getZ(uint256 marketId) external view override returns (uint256) {
        Market storage mk = _mustMarketView(marketId);
        return _sumY(mk);
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
        marketId;
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                       IMarketMaker – BUYS ONLY
    //////////////////////////////////////////////////////////////*/

    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,         // tokens (1e6)
        uint256 maxUSDCIn  // (1e6)
    ) external override returns (uint256 usdcIn) {
        Market storage mk = _mustMarket(marketId);
        _requireListed(mk, positionId);

        uint256 baseCost;
        if (isBack) {
            baseCost = _buyBackExactBase(mk, positionId, t);
        } else {
            baseCost = _buyLayExactBase(mk, positionId, t);
        }

        uint256 fee = _feeOnTop(baseCost);
        usdcIn = baseCost + fee;

        require(usdcIn <= maxUSDCIn, "NLI: slippage buy");
    }

    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,        // total spend incl fee (1e6)
        uint256 minTokensOut
    ) external override returns (uint256 tokensOut) {
        Market storage mk = _mustMarket(marketId);
        _requireListed(mk, positionId);

        // gross = base + ceil(base*fee/denom)
        // floor baseBudget so we never exceed gross.
        uint256 baseBudget = (usdcIn * BPS_DENOM) / (BPS_DENOM + FEE_BPS);

        if (isBack) {
            tokensOut = _buyBackForUSDCBase(mk, positionId, baseBudget);
        } else {
            tokensOut = _buyLayForUSDCBase(mk, positionId, baseBudget);
        }

        require(tokensOut >= minTokensOut, "NLI: min tokens");
    }

    /*//////////////////////////////////////////////////////////////
                              CORE PRICING
    //////////////////////////////////////////////////////////////*/

    function _sumY(Market storage mk) internal view returns (uint256 sumY_wad) {
        // sumY = sumW + k*sumX/WAD
        uint256 kx = FullMath.mulDiv(mk.k_wad, mk.sumX_wad, WAD);
        sumY_wad = mk.sumW_wad + kx;
        require(sumY_wad > 0, "NLI: bad sumY");
    }

    function _y_i(Market storage mk, uint256 posId) internal view returns (uint256 y_wad) {
        uint256 kx = FullMath.mulDiv(mk.k_wad, mk.x_wad[posId], WAD);
        y_wad = mk.w_wad[posId] + kx;
    }

    function _backPriceWad(Market storage mk, uint256 posId) internal view returns (uint256) {
        uint256 sumY = _sumY(mk);
        uint256 y    = _y_i(mk, posId);
        return FullMath.mulDiv(y, WAD, sumY);
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
        uint256 K     = mk.k_wad;

        uint256 sumY0 = _sumY(mk);
        uint256 y0    = _y_i(mk, posId);

        // ba = sumY - y (everything else)
        uint256 ba = sumY0 - y0;

        // delta = (K * t)/WAD, and bt = sumY0 + delta
        uint256 delta = FullMath.mulDiv(K, t_wad, WAD);
        uint256 bt    = sumY0 + delta;

        // lnTerm = ln( (sumY0 + delta) / sumY0 ) in WAD
        int256 lnTerm = FixedPointMathLib.lnWad(
            int256(FullMath.mulDiv(bt, WAD, sumY0))
        );
        require(lnTerm >= 0, "NLI: ln<0");

        // cost_wad = t - ba * ln(...) / K
        uint256 cost_wad = t_wad - FullMath.mulDiv(ba, uint256(lnTerm), K);
        baseUSDCIn = _wadToUsdcRoundUp(cost_wad);

        // update exposure
        mk.x_wad[posId] += t_wad;
        mk.sumX_wad     += t_wad;
    }

    /// @dev Executes BUY LAY exact `t_usdc` and returns BASE net cost (no fee).
    function _buyLayExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal returns (uint256 baseUSDCIn) {
        // Buy complete set for t, then SELL BACK(t) into AMM.
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
        uint256 K     = mk.k_wad;

        // You can only "sell back" up to existing exposure.
        require(mk.x_wad[posId] >= t_wad, "NLI: not enough exposure");

        uint256 sumY0 = _sumY(mk);
        uint256 y0    = _y_i(mk, posId);
        uint256 ba    = sumY0 - y0;

        // delta = (K * t)/WAD, require sumY0 > delta
        uint256 delta = FullMath.mulDiv(K, t_wad, WAD);
        require(sumY0 > delta, "NLI: sumY too small");

        // lnTerm = ln( sumY0 / (sumY0 - delta) ) in WAD
        int256 lnTerm = FixedPointMathLib.lnWad(
            int256(FullMath.mulDiv(sumY0, WAD, (sumY0 - delta)))
        );
        require(lnTerm >= 0, "NLI: ln<0");

        // out_wad = t - ba * ln(...) / K
        uint256 out_wad = t_wad - FullMath.mulDiv(ba, uint256(lnTerm), K);
        usdcOut = _wadToUsdcRoundDown(out_wad);

        // update exposure
        mk.x_wad[posId] -= t_wad;
        mk.sumX_wad     -= t_wad;
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
        require(spent <= baseBudgetUSDC, "NLI: baseBudget");
    }

    function _buyLayForUSDCBase(
        Market storage mk,
        uint256 posId,
        uint256 baseBudgetUSDC
    ) internal returns (uint256 tokensOut) {
        tokensOut = _solveBuyLayTokensOutBase(mk, posId, baseBudgetUSDC);

        uint256 usdcOutBack = _sellBackExactBase(mk, posId, tokensOut);
        uint256 netIn = (tokensOut > usdcOutBack) ? (tokensOut - usdcOutBack) : 0;
        require(netIn <= baseBudgetUSDC, "NLI: baseBudget");
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
        uint256 hi = baseBudgetUSDC * 1000 + 1; // generous upper bound

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
        uint256 K     = mk.k_wad;

        uint256 sumY0 = _sumY(mk);
        uint256 y0    = _y_i(mk, posId);
        uint256 ba    = sumY0 - y0;

        uint256 delta = FullMath.mulDiv(K, t_wad, WAD);
        uint256 bt    = sumY0 + delta;

        int256 lnTerm = FixedPointMathLib.lnWad(
            int256(FullMath.mulDiv(bt, WAD, sumY0))
        );
        if (lnTerm < 0) return type(uint256).max;

        uint256 cost_wad = t_wad - FullMath.mulDiv(ba, uint256(lnTerm), K);
        usdcIn = _wadToUsdcRoundUp(cost_wad);
    }

    function _previewSellBackExactBase(
        Market storage mk,
        uint256 posId,
        uint256 t_usdc
    ) internal view returns (uint256 usdcOut) {
        uint256 t_wad = t_usdc * WAD_PER_USDC;
        uint256 K     = mk.k_wad;

        if (mk.x_wad[posId] < t_wad) return 0;

        uint256 sumY0 = _sumY(mk);
        uint256 y0    = _y_i(mk, posId);
        uint256 ba    = sumY0 - y0;

        uint256 delta = FullMath.mulDiv(K, t_wad, WAD);
        if (sumY0 <= delta) return 0;

        int256 lnTerm = FixedPointMathLib.lnWad(
            int256(FullMath.mulDiv(sumY0, WAD, (sumY0 - delta)))
        );
        if (lnTerm < 0) return 0;

        uint256 out_wad = t_wad - FullMath.mulDiv(ba, uint256(lnTerm), K);
        usdcOut = _wadToUsdcRoundDown(out_wad);
    }

    /*//////////////////////////////////////////////////////////////
                              FEE HELPERS
    //////////////////////////////////////////////////////////////*/

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
        require(mk.initialized, "NLI: market not init");
    }

    function _mustMarketView(uint256 marketId) internal view returns (Market storage mk) {
        mk = _m[marketId];
        require(mk.initialized, "NLI: market not init");
    }

    function _requireListed(Market storage mk, uint256 posId) internal view {
        require(mk.isListed[posId], "NLI: pos not listed");
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
        int256 z  = ((u - int256(WAD)) * int256(WAD)) / (u + int256(WAD)); // WAD
        int256 z2 = (z * z) / int256(WAD);
        int256 z3 = (z2 * z) / int256(WAD);
        int256 z5 = (z3 * z2) / int256(WAD);

        int256 series = z + (z3 / 3) + (z5 / 5);
        int256 lnU = 2 * series;

        int256 LN2_WAD = 693147180559945309; // ~0.693147...
        r = lnU + k * LN2_WAD;
    }
}

/*//////////////////////////////////////////////////////////////
                        Full precision mulDiv
//////////////////////////////////////////////////////////////*/

library FullMath {
    /// @notice Calculates floor(a*b/denominator) with full precision.
    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        require(denominator != 0, "mulDiv: denom=0");

        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(a, b, not(0))
            prod0 := mul(a, b)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            return prod0 / denominator;
        }

        require(denominator > prod1, "mulDiv: overflow");

        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }

        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // Factor powers of two out of denominator.
        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }

        prod0 |= prod1 * twos;

        // Invert denominator mod 2^256 (Newton-Raphson).
        uint256 inv = (3 * denominator) ^ 2;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;
        inv *= 2 - denominator * inv;

        result = prod0 * inv;
    }
}
