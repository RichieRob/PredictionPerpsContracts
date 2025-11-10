
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { PRBMathSD59x18 } from "@prb/math/PRBMathSD59x18.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../Interfaces/ILedger.sol";
import "./AMMLibraries/LMSRMathLib.sol";
import "./AMMLibraries/LMSRQuoteLib.sol";
import "./AMMLibraries/LMSRUpdateLib.sol";
import "./AMMLibraries/LMSRExpansionLib.sol";
import "./AMMLibraries/LMSRInitLib.sol";
import "./AMMLibraries/LMSRExecutionLib.sol";
import "./AMMLibraries/LMSRHelpersLib.sol";
import "./AMMLibraries/LMSRViewLib.sol";

/// @title LMSRMarketMaker (Reserve + Controlled Expansion + Listed-Subset Mapping)
/// @notice O(1) LMSR with global+local decomposition, non-tradable reserve mass,
///         and an explicit mapping from ledger positionIds to AMM slots.
///         Externally, ALL APIs accept *ledger* positionIds. Internally, we
///         look up the AMM slot via `slotOf[ledgerId]`.
///         Supports multiple markets in a single deployment.
/// @notice LMSR AMM with O(1) updates using global+local decomposition:
///         x_i = U_all + u_i  =>  E_i = exp(x_i/b) = G * R_i
///         Cache: G = exp(U_all/b), R_i = exp(u_i/b), S = sum_i R_i
///         Prices: p_i = R_i / S
///         BACK buy t:     m = b * ln(1 - p + p * e^{ t/b})
///         BACK sell t:    m = b * ln(1 - p + p * e^{-t/b})
///         LAY(not-i) buy: m = b * ln(   p + (1-p) * e^{ t/b})
///         LAY(not-i) sell:m = b * ln(   p + (1-p) * e^{-t/b})
///         State updates use:
///           ΔU_other, ΔU_k  (see mapping below) and
///           Z' = e^{ΔU_other/b}(Z - E_k) + e^{ΔU_k/b} E_k
///         Implemented as:
///           G    *= e^{ΔU_other/b}
///           R_k  *= e^{(ΔU_k - ΔU_other)/b}
///           S    += (R_k_new - R_k_old)
contract LMSRMarketMaker {
    using PRBMathSD59x18 for int256;
    using LMSRMathLib for int256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant FEE_BPS = 30;          // 0.30%
    uint256 public constant WAD     = 1e18;

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL REFERENCES
    //////////////////////////////////////////////////////////////*/

    ILedger public immutable ledger;
    IERC20  public immutable usdc;
    address public immutable governor; // who may list positions / split reserve
    uint256 public immutable mmId;

    /*//////////////////////////////////////////////////////////////
                             PER-MARKET STATE
    //////////////////////////////////////////////////////////////*/

    // LMSR PARAMS
    mapping(uint256 => int256) public b; // > 0, per market
    mapping(uint256 => uint256) public mmId; // per market

    // DECOMPOSED STATE
    mapping(uint256 => int256) public G; // Global factor G = exp(U_all / b)  (1e18)
    mapping(uint256 => int256[]) public R; // Tradable base masses (1e18) indexed by AMM slot [0..numOutcomes-1]
    mapping(uint256 => int256) public S_tradables;   // sum(R)
    mapping(uint256 => int256) public R_reserve; // Non-tradable reserve mass (1e18)
    mapping(uint256 => uint256) public numOutcomes; // Number of listed tradables (R.length)
    mapping(uint256 => bool) public isExpanding; // Whether this market can split the reserve into new listed positions

    // LEDGER ↔ AMM LISTING MAP
    mapping(uint256 => mapping(uint256 => uint256)) public slotOf; // marketId => ledgerPositionId => slot+1 (0 means NOT listed)
    mapping(uint256 => mapping(uint256 => uint256)) public ledgerIdOfSlot; // marketId => slot => ledgerPositionId

    // Initialization flag per market
    mapping(uint256 => bool) public initialized;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event Trade(address indexed user, uint256 indexed ledgerPositionId, bool isBack, uint256 tokens, uint256 usdcAmount, bool isBuy);
    event PriceUpdated(uint256 indexed ledgerPositionId, uint256 pBackWad);
    event PositionListed(uint256 indexed ledgerPositionId, uint256 slot, int256 priorR);
    event PositionSplitFromReserve(uint256 indexed ledgerPositionId, uint256 slot, uint256 alphaWad, int256 reserveBefore, int256 reserveAfter, int256 Rnew);

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _ledger,
        address _usdc,
        address _governor
    ) {
        require(_ledger != address(0) && _usdc != address(0), "bad addr");
        require(_governor != address(0), "bad governor");

        ledger     = ILedger(_ledger);
        usdc       = IERC20(_usdc);
        governor   = _governor;

        mmId = ledger.registerMarketMaker();
    }

    /*//////////////////////////////////////////////////////////////
                              MARKET INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }

 
    struct InitialPosition {
        uint256 positionId;
        int256 r;
    }

    /// @notice Initialize a new market. Can only be called once per marketId.
    /// @param _marketId The market ID to initialize.
    /// @param initialPositions Array of {positionId, r} pairs for initial listed tradables.
    /// @param liabilityUSDC The total liability in USDC (1e6-scaled) to compute b = liability / ln(numPositions).
    /// @param reserve0 Initial reserve mass (1e18). Must be 0 if !_isExpanding; >0 if _isExpanding.
    /// @param _isExpanding Whether the market is expanding (allows reserve splits).
    function initMarket(
        uint256 _marketId,
        InitialPosition[] memory initialPositions,
        uint256 liabilityUSDC,
        int256 reserve0,
        bool _isExpanding
    ) external onlyGovernor {
        LMSRInitLib.initMarketInternal(this, _marketId, initialPositions, liabilityUSDC, reserve0, _isExpanding);
    }
    
    /*//////////////////////////////////////////////////////////////
                                    VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get BACK price for a *ledger* positionId (1e18)
    function getBackPriceWad(uint256 marketId, uint256 ledgerPositionId) public view returns (uint256) {
        return LMSRViewLib.getBackPriceWadInternal(this, marketId, ledgerPositionId);
    }

    /// @notice Get true LAY(not-i) price for a *ledger* positionId (1e18)
    function getLayPriceWad(uint256 marketId, uint256 ledgerPositionId) external view returns (uint256) {
        return LMSRViewLib.getLayPriceWadInternal(this, marketId, ledgerPositionId);
    }

    /// @notice Informational reserve (“Other”) price (1e18)
    function getReservePriceWad(uint256 marketId) external view returns (uint256) {
        return LMSRViewLib.getReservePriceWadInternal(this, marketId);
    }

    /// @notice Z = sum E_i = G * (S_tradables + R_reserve) (1e18)
    function getZ(uint256 marketId) public view returns (uint256) {
        return LMSRViewLib.getZInternal(this, marketId);
    }

    /// @notice Return the listed AMM slots and their ledger ids (for UIs)
    function listSlots(uint256 marketId) external view returns (uint256[] memory listedLedgerIds) {
        return LMSRViewLib.listSlotsInternal(this, marketId);
    }

    /*//////////////////////////////////////////////////////////////
                                   QUOTES
    //////////////////////////////////////////////////////////////*/

    /// @notice Quote cost (pre-fee, 1e6) for buying t tokens of ledgerPositionId.
    function quoteBuy(uint256 marketId, uint256 ledgerPositionId, bool isBack, uint256 t) public view returns (uint256 mNoFee) {
        return LMSRQuoteLib.quoteBuyInternal(this, marketId, ledgerPositionId, isBack, t);
    }

    /// @notice Quote proceeds (pre-fee magnitude, 1e6) for selling t tokens.
    function quoteSell(uint256 marketId, uint256 ledgerPositionId, bool isBack, uint256 t) public view returns (uint256 mNoFeeMag) {
        return LMSRQuoteLib.quoteSellInternal(this, marketId, ledgerPositionId, isBack, t);
    }

    /// @notice CLOSED-FORM tokens for exact USDC-in (fee stripped first).
    function quoteBuyForUSDC(
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 mFinal,
        uint256 /* tMax (ignored) */
    ) public view returns (uint256 tOut) {
        return LMSRQuoteLib.quoteBuyForUSDCInternal(this, marketId, ledgerPositionId, isBack, mFinal);
    }

    /// @notice With-fee wrappers
    function quoteBuyWithFee(uint256 marketId, uint256 ledgerPositionId, bool isBack, uint256 t) public view returns (uint256 mFinal) {
        uint256 m = quoteBuy(marketId, ledgerPositionId, isBack, t);
        mFinal = (m * (10_000 + FEE_BPS)) / 10_000;
    }
    function quoteSellWithFee(uint256 marketId, uint256 ledgerPositionId, bool isBack, uint256 t) public view returns (uint256 mFinalOut) {
        uint256 m = quoteSell(marketId, ledgerPositionId, isBack, t);
        mFinalOut = (m * (10_000 - FEE_BPS)) / 10_000;
    }

    /*//////////////////////////////////////////////////////////////
                                 EXPANSION
    //////////////////////////////////////////////////////////////*/

    /// @notice List a new (or previously unlisted) ledger position with a chosen prior mass.
    ///         One-way: once listed, cannot be delisted.
    function listPosition(uint256 marketId, uint256 ledgerPositionId, int256 priorR) external onlyGovernor {
        LMSRExpansionLib.listPositionInternal(this, marketId, ledgerPositionId, priorR);
    }

    /// @notice Split α fraction of the reserve into a NEW listing tied to `ledgerPositionId`.
    ///         Requires market to be in expanding mode.
    ///         Keeps (S_tradables + R_reserve) constant → price continuity.
    function splitFromReserve(uint256 marketId, uint256 ledgerPositionId, uint256 alphaWad) external onlyGovernor returns (uint256 slot) {
        return LMSRExpansionLib.splitFromReserveInternal(this, marketId, ledgerPositionId, alphaWad);
    }

    /*//////////////////////////////////////////////////////////////
                                   EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Buy exact t (BACK i or true LAY(not-i)) by *ledger* positionId
    function buy(
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t,
        uint256 maxUSDCIn,
        bool usePermit2,
        bytes calldata permitBlob
    ) external returns (uint256 mFinal) {
        return LMSRExecutionLib.buyInternal(this, marketId, ledgerPositionId, isBack, t, maxUSDCIn, usePermit2, permitBlob);
    }

    /// @notice Buy for exact USDC (inverse closed-form; supports BACK and true LAY)
    function buyForUSDC(
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 usdcIn,
        uint256 tMax,             // unused (ABI compatibility)
        uint256 minTokensOut,
        bool usePermit2,
        bytes calldata permitBlob
    ) external returns (uint256 tOut) {
        return LMSRExecutionLib.buyForUSDCInternal(this, marketId, ledgerPositionId, isBack, usdcIn, tMax, minTokensOut, usePermit2, permitBlob);
    }

    /// @notice Sell exact t (BACK i or true LAY(not-i)) by *ledger* positionId
    function sell(
        uint256 marketId,
        uint256 ledgerPositionId,
        bool isBack,
        uint256 t,
        uint256 minUSDCOut
    ) external returns (uint256 usdcOut) {
        return LMSRExecutionLib.sellInternal(this, marketId, ledgerPositionId, isBack, t, minUSDCOut);
    }
}