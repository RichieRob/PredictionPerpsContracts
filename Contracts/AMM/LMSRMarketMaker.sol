// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AMMLibraries/IMarketMaker.sol";
import "./AMMLibraries/LMSRStorageLib.sol";
import "./AMMLibraries/LMSRInitLib.sol";
import "./AMMLibraries/LMSRExpandLib.sol";
import "./AMMLibraries/LMSRExecutionLib.sol";
import "./AMMLibraries/LMSRViewLib.sol";
import "./AMMLibraries/LMSRTwapLib.sol";
import "./AMMLibraries/ILedgerPositions.sol";





/// @title LMSRMarketMaker
/// @notice O(1) LMSR AMM that:
///         - Maintains prices & internal state for many markets.
///         - Does NOT move balances or touch ppUSDC/USDC.
///         - Is called only via IMarketMaker.* by your MarketMakerLedger.
///
/// Ledger does:
///   - freeCollateral / ppUSDC accounting
///   - mint/burn of position ERC20s
///   - settlement & resolution
///
/// LMSR does:
///   - quoting (BACK / true LAY)
///   - internal state updates (G, R_i, S, reserve)
///   - TWAP accumulation (via LMSRTwapLib).
contract LMSRMarketMaker is IMarketMaker {
using LMSRInitLib    for LMSRStorageLib.State;
using LMSRExpandLib  for LMSRStorageLib.State;
using LMSRExecutionLib  for LMSRStorageLib.State;
using LMSRViewLib       for LMSRStorageLib.State;
using LMSRTwapLib       for LMSRStorageLib.State;


    /*//////////////////////////////////////////////////////////////
                               STORAGE ROOT
    //////////////////////////////////////////////////////////////*/

    /// @notice All AMM markets live inside this single state struct.
    LMSRStorageLib.State internal _ls;

    /*//////////////////////////////////////////////////////////////
                           GOVERNANCE / ACCESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Governor may initialize markets, list positions, split reserve.
    address public immutable governor;

    /// @notice The unified ledger, used only to check position existence.
    ILedgerPositions public immutable ledger;

    modifier onlyGovernor() {
        require(msg.sender == governor, "LMSR: not governor");
        _;
    }

    constructor(address _governor, address _ledger) {
        require(_governor != address(0), "LMSR: bad governor");
        require(_ledger != address(0), "LMSR: bad ledger");
        governor = _governor;
        ledger   = ILedgerPositions(_ledger);
    }

    /*//////////////////////////////////////////////////////////////
                         MARKET INITIALISATION / EXPANSION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize a new LMSR market (once per ledger marketId).
    /// @param marketId         Market identifier shared with the ledger.
    /// @param initialPositions Array of {positionId, r} priors (caller-scale).
    /// @param liabilityUSDC    Max AMM liability in raw USDC (1e6).
    /// @param reserve0         Initial reserve mass (caller-scale; usually 1e18).
    /// @param isExpanding      Whether the market can split from reserve.
function initMarket(
    uint256 marketId,
    LMSRInitLib.InitialPosition[] calldata initialPositions,
    uint256 liabilityUSDC,
    int256  reserve0,
    bool    isExpanding
) external onlyGovernor {
    _ls.initMarket(
        ledger,
        marketId,
        initialPositions,
        liabilityUSDC,
        reserve0,
        isExpanding
    );
}


    /// @notice List a new (or previously unlisted) ledger position with chosen prior mass.
    /// @dev This shifts all prices (S += priorR).
    function listPosition(
        uint256 marketId,
        uint256 ledgerPositionId,
        int256  priorR
    ) external onlyGovernor {
        _ls.listPosition(
            ledger,
            marketId,
            ledgerPositionId,
            priorR
        );
    }

    /// @notice Split α fraction of the reserve into a NEW listing tied to `ledgerPositionId`.
    /// @dev This keeps S constant (we move mass from reserve → tradable).
    function splitFromReserve(
        uint256 marketId,
        uint256 ledgerPositionId,
        uint256 alphaWad
    ) external onlyGovernor returns (uint256 slot) {
        return _ls.splitFromReserve(
            ledger,
            marketId,
            ledgerPositionId,
            alphaWad
        );
    }

    /*//////////////////////////////////////////////////////////////
                                     VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice BACK price p(i) in 1e18 for a given ledgerPositionId.
    function getBackPriceWad(
        uint256 marketId,
        uint256 ledgerPositionId
    ) external view returns (uint256) {
        return _ls.getBackPriceWad(marketId, ledgerPositionId);
    }

   /// @notice Returns BACK prices (in 1e18) for all listed positions in the market, plus the reserve price.
    /// @dev Useful for fetching all prices in a single call for dApp efficiency.
    /// @return prices Array of {positionId, priceWad} for each listed position.
    /// @return reservePriceWad The reserve ("Other") price in 1e18.
    struct PositionPrice {
        uint256 positionId;
        uint256 priceWad;
    }
    function getAllBackPricesWad(uint256 marketId) 
        external 
        view 
        returns (PositionPrice[] memory prices, uint256 reservePriceWad) 
    {
        uint256[] memory slots = _ls.listSlots(marketId);
        prices = new PositionPrice[](slots.length);

        for (uint256 i = 0; i < slots.length; i++) {
            uint256 posId = slots[i];
            prices[i].positionId = posId;
            prices[i].priceWad = _ls.getBackPriceWad(marketId, posId);
        }

        reservePriceWad = _ls.getReservePriceWad(marketId);
    }

    
    /// @notice True LAY(not-i) price 1 − p(i) in 1e18.
    function getLayPriceWad(
        uint256 marketId,
        uint256 ledgerPositionId
    ) external view returns (uint256) {
        return _ls.getLayPriceWad(marketId, ledgerPositionId);
    }



    /// 🔹 NEW: batched lay prices
    function getAllLayPricesWad(uint256 marketId)
        external
        view
        returns (PositionPrice[] memory prices)
    {
        uint256[] memory slots = _ls.listSlots(marketId);
        prices = new PositionPrice[](slots.length);

        for (uint256 i = 0; i < slots.length; i++) {
            uint256 posId = slots[i];
            prices[i].positionId = posId;
            prices[i].priceWad   = _ls.getLayPriceWad(marketId, posId);
        }
    }

    /// @notice Informational reserve (“Other”) price in 1e18.
    function getReservePriceWad(
        uint256 marketId
    ) external view returns (uint256) {
        return _ls.getReservePriceWad(marketId);
    }

    /// @notice Z = G · S in 1e18 (sum of exponentials).
    function getZ(
        uint256 marketId
    ) external view returns (uint256) {
        return _ls.getZ(marketId);
    }

    /// @notice Return the listed ledger position ids for this market.
    function listSlots(
        uint256 marketId
    ) external view returns (uint256[] memory listedLedgerIds) {
        return _ls.listSlots(marketId);
    }

    /*//////////////////////////////////////////////////////////////
                                TWAP VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current cumulative (price × seconds) for a position, plus timestamp.
    /// @dev Off-chain callers use this to compute TWAP between two checkpoints.
    function twapCurrentCumulative(
        uint256 marketId,
        uint256 ledgerPositionId
    ) external view returns (uint256 cumulativeWadSeconds, uint32 timestamp) {
        return _ls.currentCumulative(marketId, ledgerPositionId);
    }

    /// @notice Pure helper to compute TWAP between two checkpoints.
    function twapConsultFromCheckpoints(
        uint256 cumStart,
        uint32  tStart,
        uint256 cumEnd,
        uint32  tEnd
    ) external pure returns (uint256 avgPriceWad) {
        return LMSRTwapLib.consultFromCheckpoints(
            cumStart,
            tStart,
            cumEnd,
            tEnd
        );
    }

    /*//////////////////////////////////////////////////////////////
                       IMarketMaker – EXECUTION ENTRYPOINTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarketMaker
    function applyBuyExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 maxUSDCIn
    ) external override returns (uint256 usdcIn) {
        // All maths + events inside LMSRExecutionLib
        usdcIn = _ls.buyExactTokens(
            marketId,
            positionId,
            isBack,
            t,
            maxUSDCIn
        );
    }

    /// @inheritdoc IMarketMaker
    function applyBuyForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcIn,
        uint256 minTokensOut
    ) external override returns (uint256 tokensOut) {
        tokensOut = _ls.buyForUSDC(
            marketId,
            positionId,
            isBack,
            usdcIn,
            minTokensOut
        );
    }

    /// @inheritdoc IMarketMaker
    function applySellExactTokens(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 t,
        uint256 minUSDCOut
    ) external override returns (uint256 usdcOut) {
        usdcOut = _ls.sellExactTokens(
            marketId,
            positionId,
            isBack,
            t,
            minUSDCOut
        );
    }

    /// @inheritdoc IMarketMaker
    function applySellForUSDC(
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 usdcOut,
        uint256 maxTokensIn
    ) external override returns (uint256 tokensIn) {
        tokensIn = _ls.sellForUSDC(
            marketId,
            positionId,
            isBack,
            usdcOut,
            maxTokensIn
        );
    }
}
