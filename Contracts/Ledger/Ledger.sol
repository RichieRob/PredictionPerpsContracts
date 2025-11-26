

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Interfaces/ILedger.sol";
import "./5_LedgerLibraries/1_StorageLib.sol";
import "./5_LedgerLibraries/7_DepositWithdrawLib.sol";
import "./5_LedgerLibraries/4_SolvencyLib.sol";
import "./5_LedgerLibraries/3_HeapLib.sol";
import "./5_LedgerLibraries/2_MarketManagementLib.sol";
import "./5_LedgerLibraries/5_LedgerLib.sol";
import "./5_LedgerLibraries/7_PositionTransferLib.sol";
import "./5_LedgerLibraries/8_TradeExecutionLib.sol";
import "./5_LedgerLibraries/2_ProtocolFeeLib.sol";
import "./5_LedgerLibraries/5_LedgerInvariantViews.sol";
import "./PositionERC20.sol";
import "./5_LedgerLibraries/9_TradeRouterLib.sol";
import "./5_LedgerLibraries/0_0_Types.sol";
import "./5_LedgerLibraries/2_IntentLib.sol";
import "./5_LedgerLibraries/8_ERC20BridgeLib.sol"; 
import "./5_LedgerLibraries/T0_0_TypesPermit.sol";
import "./5_LedgerLibraries/8_FillIntentLib.sol";








contract MarketMakerLedger {
    using 3_HeapLib for *;
    using 2_MarketManagementLib for *;
    using 5_LedgerLib for *;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event TiltUpdated(address indexed account, uint256 indexed marketId, uint256 indexed positionId, uint256 freeCollateral, int256 allocatedCapital, int256 newTilt);
    event Bought(address indexed account, uint256 indexed marketId, uint256 indexed positionId, bool isBack, uint256 tokensOut, uint256 usdcIn, uint256 recordedUSDC);
    event Sold(address indexed account, uint256 indexed marketId, uint256 indexed positionId, bool isBack, uint256 tokensIn, uint256 usdcOut);
    event Redeemed(uint256 indexed marketId, uint256 amount);
    event MarketMakerRegistered(address indexed mmAddress, address account);
    event LiquidityTransferred(address indexed account, address indexed oldAddress, address indexed newAddress);
    event DMMAllowed(address indexed account, bool allowed);
    event IntentFilled( address indexed relayer, address indexed trader, uint256 indexed marketId, uint256 positionId, 0_Types.TradeKind kind, bool isBack, uint256 primaryAmount, uint256 bound);




    modifier onlyOwner() {
        require(msg.sender == StorageLib.getStorage().owner, "Only owner");
        _;
    }

    constructor(address _usdc, address _aUSDC, address _aavePool, address _permit2, address _ppUSDC ) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.owner = msg.sender;
        s.usdc = IERC20(_usdc);
        s.aUSDC = IERC20(_aUSDC);
        s.aavePool = IAavePool(_aavePool);
        s.permit2 = _permit2; // may be address(0) if unused
        s.ppUSDC = IERC20(_ppUSDC);
    
        // Deploy the shared ERC20 implementation once
        s.positionERC20Implementation = address(new PositionERC20(address(this)));

    }

 

    // --- market / position management  ---
    function createMarket(string memory name, string memory ticker, address dmm, uint256 iscAmount, bool doesResolve, address oracle, bytes calldata oraclePamas ) external onlyOwner returns (uint256 marketId) {
        marketId = 2_MarketManagementLib.createMarket(name, ticker, dmm, iscAmount, doesResolve, oracle, oracleParams);
    }

function createPosition(
    uint256 marketId,
    string memory name,
    string memory ticker
)
    external
    onlyOwner
    returns (uint256 positionId, address token)
{
    (positionId, token) = 2_MarketManagementLib.createPosition(
        marketId,
        name,
        ticker
    );

    // Wire the cloned ERC20 to this market/position
    8_ERC20BridgeLib.registerBackPositionERC20(token, marketId, positionId);
}


    function createPositions(
    uint256 marketId,
    0_Types.PositionMeta[] memory positions
    ) external onlyOwner returns (uint256[] memory positionIds) {
    require(positions.length > 0, "No positions provided");

    positionIds = new uint256[](positions.length);
    for (uint256 i = 0; i < positions.length; i++) {
        (uint256 positionId, address token) = 2_MarketManagementLib.createPosition(
            marketId,
            positions[i].name,
            positions[i].ticker
        );

    // Wire the cloned ERC20 to this market/position
    8_ERC20BridgeLib.registerBackPositionERC20(token, marketId, positionId);
        positionIds[i] = positionId;
     }
    }

    // --- owner finance ops ---
    function withdrawInterest() external onlyOwner {
        7_DepositWithdrawLib.withdrawInterest(msg.sender);
    }


    // Exposure functions for the ERC20

  // In MarketMakerLedger.sol

function getERC20PositionMeta(address token)
    external
    view
    returns (
        bool   registered,
        uint256 marketId,
        uint256 positionId,
        string memory positionName,
        string memory positionTicker,
        string memory marketName,
        string memory marketTicker
    )
{
    StorageLib.Storage storage s = StorageLib.getStorage();

    registered     = s.erc20Registered[token];
    if (!registered) {
        return (false, 0, 0, "", "", "", "");
    }

    marketId       = s.erc20MarketId[token];
    positionId     = s.erc20PositionId[token];

    // 🔧 FIX: index by (marketId, positionId)
    positionName   = s.positionNames[marketId][positionId];
    positionTicker = s.positionTickers[marketId][positionId];

    marketName     = s.marketNames[marketId];
    marketTicker   = s.marketTickers[marketId];
}




function erc20TotalSupply(address token) external view returns (uint256) {
    return 8_ERC20BridgeLib.erc20TotalSupply(token);
}

function erc20BalanceOf(address token, address account) external view returns (uint256) {
    return 8_ERC20BridgeLib.erc20BalanceOf(token, account);
}



   // --- trading entrypoints using and updating internal ppUSDC---


function buyExactTokens(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 t,
    uint256 maxUSDCIn
) external {
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.BUY_EXACT_TOKENS,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        t,
        maxUSDCIn
    );
}

function buyForppUSDC(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 usdcIn,
    uint256 minTokensOut
) external {
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.BUY_FOR_USDC,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        usdcIn,
        minTokensOut
    );
}

function sellExactTokens(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 t,
    uint256 minUSDCOut
) external {
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.SELL_EXACT_TOKENS,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        t,
        minUSDCOut
    );
}

function sellForppUSDC(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 usdcOut,
    uint256 maxTokensIn
) external {
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.SELL_FOR_USDC,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        usdcOut,
        maxTokensIn
    );
}


  // --- trading entrypoints using and updating USDC directly---

function buyExactTokensWithUSDC(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 t,
    uint256 maxUSDCFromWallet,
    uint8   mode,                         // 0 = allowance, 1 = EIP-2612, 2 = Permit2
    0_TypesPermit.EIP2612Permit calldata eipPermit,
    bytes  calldata permit2Calldata
) external {
    require(t > 0, "t=0");

    // 1) Deposit from wallet -> ledger realFreeCollateral for msg.sender
    uint256 recorded = 7_DepositWithdrawLib.depositFromTraderUnified(
        msg.sender,           // ledger account credited
        msg.sender,           // trader paying USDC
        maxUSDCFromWallet,    // wallet amount we try to pull
        0,                    // minUSDCDeposited; could add a param if you want
        mode,
        eipPermit,
        permit2Calldata
    );

    // 2) Route via router (uses recorded as maxUSDCIn)
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.BUY_EXACT_TOKENS,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        t,          // primaryAmount = tokens
        recorded    // bound = maxUSDCIn
    );
}

function buyForUSDCWithUSDC(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 usdcFromWallet,
    uint256 minTokensOut,
    uint8   mode,                         // 0 = allowance, 1 = EIP-2612, 2 = Permit2
    0_TypesPermit.EIP2612Permit calldata eipPermit,
    bytes  calldata permit2Calldata
) external {
    require(usdcFromWallet > 0, "usdcIn=0");

    // 1) Deposit from wallet -> ledger realFreeCollateral
    uint256 recorded = 7_DepositWithdrawLib.depositFromTraderUnified(
        msg.sender,          // ledger account credited
        msg.sender,          // trader paying USDC
        usdcFromWallet,
        0,                   // minUSDCDeposited
        mode,
        eipPermit,
        permit2Calldata
    );

    // 2) Route via router (recorded is actual usdcIn)
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.BUY_FOR_USDC,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        recorded,      // primaryAmount = usdcIn
        minTokensOut   // bound = minTokensOut
    );
}

/// @notice Sell exact `t` tokens and withdraw the USDC proceeds to `to`.
function sellExactTokensForUSDCToWallet(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 t,
    uint256 minUSDCOut,
    address to
) external {
    require(t > 0, "t=0");
    require(to != address(0), "to=0");

    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256 beforeFree = s.realFreeCollateral[msg.sender];

    // 1) Internal sell → credits realFreeCollateral (ppUSDC) via router
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.SELL_EXACT_TOKENS,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        t,           // primaryAmount = tokens
        minUSDCOut   // bound = minUSDCOut
    );

    // 2) Work out how much this trade just credited
    uint256 afterFree = s.realFreeCollateral[msg.sender];
    require(afterFree >= beforeFree, "realFreeCollateral underflow");
    uint256 delta = afterFree - beforeFree;
    require(delta > 0, "no proceeds");

    // 3) Withdraw only that delta as real USDC to `to`
    7_DepositWithdrawLib.withdrawWithoutClaims(msg.sender, delta, to);
    emit Withdrawn(msg.sender, delta);
}

/// @notice Sell however many tokens are needed to get exactly `usdcOut`
///         and withdraw that USDC directly to `to`.
function sellForUSDCToWallet(
    address mm,
    uint256 marketId,
    uint256 positionId,
    bool    isBack,
    uint256 usdcOut,
    uint256 maxTokensIn,
    address to
) external {
    require(usdcOut > 0, "usdcOut=0");
    require(to != address(0), "to=0");

    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256 beforeFree = s.realFreeCollateral[msg.sender];

    // 1) Internal sell → credits realFreeCollateral (ppUSDC) via router.
    9_TradeRouterLib.tradeWithPPUSDC(
        0_Types.TradeKind.SELL_FOR_USDC,
        msg.sender,
        mm,
        marketId,
        positionId,
        isBack,
        usdcOut,      // primaryAmount = target ppUSDC credit
        maxTokensIn   // bound
    );

    // 2) Compute net realFreeCollateral gained
    uint256 afterFree = s.realFreeCollateral[msg.sender];
    require(afterFree >= beforeFree, "realFreeCollateral underflow");
    uint256 delta = afterFree - beforeFree;

    // 3) Enforce "all of usdcOut must be withdrawable"
    require(delta >= usdcOut, "sellForUSDC: insufficient net proceeds");

    // 4) Withdraw exactly usdcOut to wallet
    7_DepositWithdrawLib.withdrawWithoutClaims(msg.sender, usdcOut, to);
    emit Withdrawn(msg.sender, usdcOut);
}




    // --- views / misc ---


    function getPositionLiquidity(address account, uint256 marketId, uint256 positionId)
        external view
        returns (uint256 realFreeCollateral, int256 marketExposure, int256 tilt, uint256 amountOfISCForThisAccountAndMarket)
    {
        return 5_LedgerLib.getPositionLiquidity(account, marketId, positionId);
    }


    function getMinTilt(address account, uint256 marketId) external view returns (int256 minTilt, uint256 minPositionId) {
        return 5_LedgerLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(address account, uint256 marketId) external view returns (int256 maxTilt, uint256 maxPositionId) {
        return 5_LedgerLib.getMaxTilt(account, marketId);
    }

    function getMarketValue(uint256 marketId) external view returns (uint256) {
        return StorageLib.getStorage().marketValue[marketId];
    }
    function getTotalMarketsValue() external view returns (uint256) {
        return StorageLib.getStorage().TotalMarketsValue;
    }


    function effectiveTotalFreeCollateral() external view returns (uint256)
    {
    StorageLib.Storage storage s = StorageLib.getStorage();
    return s.realTotalFreeCollateral + s.effectiveTotalFreeCollateralDelta;
    }

    function getTotalValueLocked() external view returns (uint256) {
        return StorageLib.getStorage().totalValueLocked;
    }
    function getMarkets() external view returns (uint256[] memory) {
        return 2_MarketManagementLib.getMarkets();
    }
    function getMarketPositions(uint256 marketId) external view returns (uint256[] memory) {
        return 2_MarketManagementLib.getMarketPositions(marketId);
    }
 
 function getMarketDetails(uint256 marketId)
    external
    view
    returns (string memory name, string memory ticker)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    name   = s.marketNames[marketId];
    ticker = s.marketTickers[marketId];
}

function getPositionDetails(uint256 marketId, uint256 positionId)
    external
    view
    returns (string memory name, string memory ticker)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    name   = s.positionNames[marketId][positionId];
    ticker = s.positionTickers[marketId][positionId];
}




// --- allowlist for DMMs ---
    function allowDMM(address account, bool allowed) external onlyOwner {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.allowedDMMs[account] = allowed;
        emit DMMAllowed(account, allowed);
    }

        /*//////////////////////////////////////////////////////////////
                                   Turn on/off fees
    //////////////////////////////////////////////////////////////*/

    function setFeeConfig(address recipient, uint16 bps, bool enabled) external onlyOwner {
    2_ProtocolFeeLib.setFeeConfig(recipient, bps, enabled);
}


// ppUSDC views

function effectiveFreeCollateral(address account) external view returns (uint256) {
    return 6_ResolutionLib.effectiveFreeCollateral(account);
}

function realFreeCollateral(address account) external view returns (uint256) {
    return 6_ResolutionLib.realFreeCollateral(account);
}

// this one is gonna be interesting... need to think about how this updates, currently doesn include any of the uclaimed..
function realTotalFreeCollateral() external view returns (uint256) {
    return StorageLib.getStorage().realTotalFreeCollateral;
}

function claimAllPendingWinnings() external {
    6_ResolutionLib._applyPendingWinnings(msg.sender);
}

function batchClaimWinnings(address account, uint256[] calldata marketIds) external {
    6_ResolutionLib._batchClaimWinnings(account, marketIds);
}



function ppUSDCTransfer(address from, address to, uint256 amount) external {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(msg.sender == address(s.ppUSDC), "Only ppUSDC");

    // ↓ bookkeeping: move freeCollateral between accounts
    require(s.freeCollateral[from] >= amount, "Insufficient ppUSDC");
    s.realFreeCollateral[from] -= amount;
    s.realFreeCollateral[to]   += amount;

}


// Deposit and Withdraw USDC

// -----------------------------------------------------------------------
// Unified Deposit (Allowance / EIP-2612 / Permit2)
// -----------------------------------------------------------------------

// mode: 0 = allowance, 1 = EIP-2612, 2 = Permit2
function deposit(
    address to,
    uint256 amount,
    uint256 minUSDCDeposited,
    uint8   mode,
    0_TypesPermit.EIP2612Permit calldata eipPermit,   // only used if mode==1
    bytes  calldata permit2Calldata                 // only used if mode==2
) external {
    uint256 recorded = 7_DepositWithdrawLib.depositFromTraderUnified(
        to,        // ledger account credited
        msg.sender,        // trader paying USDC
        amount,
        minUSDCDeposited,
        mode,
        eipPermit,
        permit2Calldata
    );

    emit Deposited(msg.sender, recorded);
}

function withdraw(uint256 amount, address to) external {
    7_DepositWithdrawLib.withdrawWithClaims(msg.sender, amount, to);
    emit Withdrawn(msg.sender, amount);
}

//ERC20 Transfers

function positionERC20Transfer(
    address from,
    address to,
    uint256 amount
) external {
    8_ERC20BridgeLib.erc20PositionTransfer(msg.sender, from, to, amount);
}

//ERC20 Names

function erc20Name(uint256 marketId, uint256 positionId)
    external
    view
    returns (string memory)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    string memory marketName   = s.marketNames[marketId];
    string memory positionName = s.positionNames[marketId][positionId]; 

    return string.concat(positionName, " in ", marketName);
}

function erc20Symbol(uint256 marketId, uint256 positionId)
    external
    view
    returns (string memory)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    string memory marketTicker   = s.marketTickers[marketId];
    string memory positionTicker = s.positionTickers[marketId][positionId]; 

    return string.concat(positionTicker, "-", marketTicker);
}



function cancelIntent(0_Types.Intent calldata intent) external {
    // tx sender must be the trader
    require(intent.trader == msg.sender, "not trader");
    2_IntentLib.cancelIntent(intent);
}

function fillIntent(
    0_Types.Intent calldata intent,
    bytes calldata signature,
    uint256 fillPrimary,  // tokens
    uint256 fillQuote     // ppUSDC / USDC
) external {
    // Filler is msg.sender; 8_FillIntentLib will use that.
    8_FillIntentLib._fillIntent(intent, signature, fillPrimary, fillQuote);
            emit IntentFilled(
            msg.sender,
            intent.trader,
            intent.marketId,
            intent.positionId,
            intent.kind,
            intent.isBack,
            fillPrimary,
            fillQuote
        );
}






// EXPOSE LIBRARY FOR TESTS


function invariant_marketAccounting(uint256 marketId)
    external
    view
    returns (uint256 lhs, uint256 rhs)
{
    return 5_LedgerInvariantViews.marketAccounting(marketId);
}

function invariant_iscWithinLine(uint256 marketId)
    external
    view
    returns (uint256 used, uint256 line)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    used = 5_LedgerInvariantViews.iscSpent(marketId);
    line = s.syntheticCollateral[marketId];
}

function invariant_effectiveMin(address account, uint256 marketId)
    external
    view
    returns (int256 effMin)
{
    return 5_LedgerInvariantViews.effectiveMinShares(account, marketId);
}

function invariant_systemFunding(uint256 marketId)
    external
    view
    returns (uint256 fullSetsSystem)
{
    return 5_LedgerInvariantViews.totalFullSets(marketId);
}

function invariant_tvl()
    external
    view
    returns (uint256 tvl, uint256 aUSDCBalance)
{
    return 5_LedgerInvariantViews.tvlAccounting();
}

function invariant_systemBalance()
    external
    view
    returns (uint256 lhs, uint256 rhs)
{
    return 5_LedgerInvariantViews.systemBalance();
}

function invariant_checkSolvencyAllMarkets(address account)
    external
    view
    returns (bool ok)
{
    return 5_LedgerInvariantViews.checkSolvencyAllMarkets(account);
}

function invariant_redeemabilityState(address account, uint256 marketId)
    external
    view
    returns (int256 netAlloc, int256 redeemable, int256 margin)
{
    return 5_LedgerInvariantViews.redeemabilityState( account, marketId);
}

}