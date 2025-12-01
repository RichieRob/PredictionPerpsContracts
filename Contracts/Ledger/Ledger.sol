

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Interfaces/ILedger.sol";

import "./LedgerLibraries/0_Types.sol";
import "./LedgerLibraries/0_TypesPermit.sol";

import "./LedgerLibraries/1_StorageLib.sol";
import "./LedgerLibraries/2_FreeCollateralLib.sol";
import "./LedgerLibraries/2_MarketManagementLib.sol";
import "./LedgerLibraries/2_ProtocolFeeLib.sol";
import "./LedgerLibraries/2_IntentLib.sol";
import "./LedgerLibraries/3_HeapLib.sol";
import "./LedgerLibraries/4_SolvencyLib.sol";
import "./LedgerLibraries/5_LedgerLib.sol";
import "./LedgerLibraries/5_LedgerInvariantViews.sol";
import "./LedgerLibraries/6_ResolutionLib.sol";
import "./LedgerLibraries/7_DepositWithdrawLib.sol";
import "./LedgerLibraries/7_PositionTransferLib.sol";
import "./LedgerLibraries/8_TradeExecutionLib.sol";
import "./LedgerLibraries/8_ERC20BridgeLib.sol";
import "./LedgerLibraries/8_FillIntentLib.sol";
import "./LedgerLibraries/9_TradeRouterLib.sol";











contract Ledger {
    using HeapLib for *;
    using MarketManagementLib for *;
    using LedgerLib for *;

    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event TiltUpdated(address indexed account, uint256 indexed marketId, uint256 indexed positionId, uint256 freeCollateral, int256 allocatedCapital, int256 newTilt);
    event Bought(address indexed account, uint256 indexed marketId, uint256 indexed positionId, bool isBack, uint256 tokensOut, uint256 usdcIn, uint256 recordedUSDC);
    event Sold(address indexed account, uint256 indexed marketId, uint256 indexed positionId, bool isBack, uint256 tokensIn, uint256 usdcOut);
    event Redeemed(uint256 indexed marketId, uint256 amount);
    event MarketMakerRegistered(address indexed mmAddress, address account);
    event LiquidityTransferred(address indexed account, address indexed oldAddress, address indexed newAddress);
    event DMMAllowed(address indexed account, bool allowed);
    event IntentFilled( address indexed relayer, address indexed trader, uint256 indexed marketId, uint256 positionId, Types.TradeKind kind, bool isBack, uint256 primaryAmount, uint256 bound);




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
    
       

    }

 

    // --- market / position management  ---
    
    function createMarket(string memory name, string memory ticker, address dmm, uint256 iscAmount, bool doesResolve, address oracle, bytes calldata oracleParams ) external onlyOwner returns (uint256 marketId) {
        marketId = MarketManagementLib.createMarket(name, ticker, dmm, iscAmount, doesResolve, oracle, oracleParams);
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
    (positionId, token) = MarketManagementLib.createPosition(
        marketId,
        name,
        ticker
    );

    // Wire the cloned ERC20 to this market/position
    ERC20BridgeLib.registerBackPositionERC20(token, marketId, positionId);
}


    function createPositions(
    uint256 marketId,
    Types.PositionMeta[] memory positions
    ) external onlyOwner returns (uint256[] memory positionIds) {
    require(positions.length > 0, "No positions provided");

    positionIds = new uint256[](positions.length);
    for (uint256 i = 0; i < positions.length; i++) {
        (uint256 positionId, address token) = MarketManagementLib.createPosition(
            marketId,
            positions[i].name,
            positions[i].ticker
        );

    // Wire the cloned ERC20 to this market/position
    ERC20BridgeLib.registerBackPositionERC20(token, marketId, positionId);
        positionIds[i] = positionId;
     }
    }

    // --- owner finance ops ---
    function withdrawInterest() external onlyOwner {
        DepositWithdrawLib.withdrawInterest(msg.sender);
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

function getPositionERC20(
    uint256 marketId,
    uint256 positionId
) external view returns (address) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.positionERC20[marketId][positionId];
}

function positionExists(
    uint256 marketId,
    uint256 positionId
) external view returns (bool) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    
    return s.positionERC20[marketId][positionId] != address(0);
}



function erc20TotalSupply(address token) external view returns (uint256) {
    return ERC20BridgeLib.erc20TotalSupply(token);
}

function erc20BalanceOf(address token, address account) external view returns (uint256) {
    return ERC20BridgeLib.erc20BalanceOf(token, account);
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
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.BUY_EXACT_TOKENS,
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
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.BUY_FOR_USDC,
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
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.SELL_EXACT_TOKENS,
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
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.SELL_FOR_USDC,
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
    TypesPermit.EIP2612Permit calldata eipPermit,
    bytes  calldata permit2Calldata
) external {
    require(t > 0, "t=0");

    // 1) Deposit from wallet -> ledger realFreeCollateral for msg.sender
    uint256 recorded = DepositWithdrawLib.depositFromTraderUnified(
        msg.sender,           // ledger account credited
        msg.sender,           // trader paying USDC
        maxUSDCFromWallet,    // wallet amount we try to pull
        0,                    // minUSDCDeposited; could add a param if you want
        mode,
        eipPermit,
        permit2Calldata
    );

    // 2) Route via router (uses recorded as maxUSDCIn)
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.BUY_EXACT_TOKENS,
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
    TypesPermit.EIP2612Permit calldata eipPermit,
    bytes  calldata permit2Calldata
) external {
    require(usdcFromWallet > 0, "usdcIn=0");

    // 1) Deposit from wallet -> ledger realFreeCollateral
    uint256 recorded = DepositWithdrawLib.depositFromTraderUnified(
        msg.sender,          // ledger account credited
        msg.sender,          // trader paying USDC
        usdcFromWallet,
        0,                   // minUSDCDeposited
        mode,
        eipPermit,
        permit2Calldata
    );

    // 2) Route via router (recorded is actual usdcIn)
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.BUY_FOR_USDC,
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
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.SELL_EXACT_TOKENS,
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
    DepositWithdrawLib.withdrawWithoutClaims(msg.sender, delta, to);
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
    TradeRouterLib.tradeWithPPUSDC(
        Types.TradeKind.SELL_FOR_USDC,
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
    DepositWithdrawLib.withdrawWithoutClaims(msg.sender, usdcOut, to);
    emit Withdrawn(msg.sender, usdcOut);
}




    // --- views / misc ---


    function getPositionLiquidity(address account, uint256 marketId, uint256 positionId)
        external view
        returns (uint256 _realFreeCollateral, int256 marketExposure, int256 tilt, uint256 amountOfISCForThisAccountAndMarket)
    {
        return LedgerLib.getPositionLiquidity(account, marketId, positionId);
    }


    function getMinTilt(address account, uint256 marketId) external view returns (int256 minTilt, uint256 minPositionId) {
        return LedgerLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(address account, uint256 marketId) external view returns (int256 maxTilt, uint256 maxPositionId) {
        return LedgerLib.getMaxTilt(account, marketId);
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
        return MarketManagementLib.getMarkets();
    }
    function getMarketPositions(uint256 marketId) external view returns (uint256[] memory) {
        return MarketManagementLib.getMarketPositions(marketId);
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

// set the ERC20 Implementation
function setPositionERC20Implementation(address impl) external onlyOwner {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(impl != address(0), "Invalid impl"); // Or use custom error
    require(s.positionERC20Implementation == address(0), "Already set"); // Optional: Make it set-once
    s.positionERC20Implementation = impl;
}


        /*//////////////////////////////////////////////////////////////
                                   Turn on/off fees
    //////////////////////////////////////////////////////////////*/

    function setFeeConfig(address recipient, uint16 bps, bool enabled) external onlyOwner {
    ProtocolFeeLib.setFeeConfig(recipient, bps, enabled);
}


// ppUSDC views

function effectiveFreeCollateral(address account) external view returns (uint256) {
    return ResolutionLib.effectiveFreeCollateral(account);
}

function realFreeCollateral(address account) external view returns (uint256) {
    return ResolutionLib.realFreeCollateral(account);
}

// this one is gonna be interesting... need to think about how this updates, currently doesn include any of the uclaimed..
function realTotalFreeCollateral() external view returns (uint256) {
    return StorageLib.getStorage().realTotalFreeCollateral;
}

function claimAllPendingWinnings() external {
    ResolutionLib._applyPendingWinnings(msg.sender);
}

function batchClaimWinnings(address account, uint256[] calldata marketIds) external {
    ResolutionLib._batchClaimWinnings(account, marketIds);
}



function ppUSDCTransfer(address from, address to, uint256 amount) external {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(msg.sender == address(s.ppUSDC), "Only ppUSDC");

    //Pull all winnings to the user before transfering it
    ResolutionLib._applyPendingWinnings(from);
    // ↓ bookkeeping: move freeCollateral between accounts
    require(s.realFreeCollateral[from] >= amount, "Insufficient ppUSDC");
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
    TypesPermit.EIP2612Permit calldata eipPermit,   // only used if mode==1
    bytes  calldata permit2Calldata                 // only used if mode==2
) external {
    uint256 recorded = DepositWithdrawLib.depositFromTraderUnified(
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
    DepositWithdrawLib.withdrawWithClaims(msg.sender, amount, to);
    emit Withdrawn(msg.sender, amount);
}

//ERC20 Transfers


    function transferPosition(
        address to,
        uint256 marketId,
        uint256 positionId,
        bool isBack,
        uint256 amount
    ) external {
        PositionTransferLib.transferPosition(msg.sender,to,marketId,positionId,isBack,amount);
        //Update solvency
        SolvencyLib.ensureSolvency(msg.sender, marketId);
        SolvencyLib.deallocateExcess(to, marketId);
    }

function positionERC20Transfer(
    address from,
    address to,
    uint256 amount
) external {
    ERC20BridgeLib.erc20PositionTransfer(msg.sender, from, to, amount); 

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



function cancelIntent(Types.Intent calldata intent) external {
    // tx sender must be the trader
    require(intent.trader == msg.sender, "not trader");
    IntentLib.cancelIntent(intent);
}

function fillIntent(
    Types.Intent calldata intent,
    bytes calldata signature,
    uint256 fillPrimary,  // tokens
    uint256 fillQuote     // ppUSDC / USDC
) external {
    // Filler is msg.sender; FillIntentLib will use that.
    FillIntentLib._fillIntent(intent, signature, fillPrimary, fillQuote);
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


function resolveMarket(uint256 marketId) external onlyOwner {
 ResolutionLib.resolveFromOracle(marketId);
 }

 /// @notice Manually resolve a market to a winning position
function resolveMarket(uint256 marketId, uint256 winningPositionId)
    external
    onlyOwner
{
    ResolutionLib._resolveMarketCore(marketId, winningPositionId);
}



// EXPOSE LIBRARY FOR TESTS


// function invariant_marketAccounting(uint256 marketId)
//     external
//     view
//     returns (uint256 lhs, uint256 rhs)
// {
//     return LedgerInvariantViews.marketAccounting(marketId);
// }

// function invariant_iscWithinLine(uint256 marketId)
//     external
//     view
//     returns (uint256 used, uint256 line)
// {
//     StorageLib.Storage storage s = StorageLib.getStorage();
//     used = LedgerInvariantViews.iscSpent(marketId);
//     line = s.syntheticCollateral[marketId];
// }

// function invariant_effectiveMin(address account, uint256 marketId)
//     external
//     view
//     returns (int256 effMin)
// {
//     return LedgerInvariantViews.effectiveMinShares(account, marketId);
// }

// function invariant_systemFunding(uint256 marketId)
//     external
//     view
//     returns (uint256 fullSetsSystem)
// {
//     return LedgerInvariantViews.totalFullSets(marketId);
// }

// function invariant_tvl()
//     external
//     view
//     returns (uint256 tvl, uint256 aUSDCBalance)
// {
//     return LedgerInvariantViews.tvlAccounting();
// }

// function invariant_systemBalance()
//     external
//     view
//     returns (uint256 lhs, uint256 rhs)
// {
//     return LedgerInvariantViews.systemBalance();
// }

// function invariant_checkSolvencyAllMarkets(address account)
//     external
//     view
//     returns (bool ok)
// {
//     return LedgerInvariantViews.checkSolvencyAllMarkets(account);
// }

// function invariant_redeemabilityState(address account, uint256 marketId)
//     external
//     view
//     returns (int256 netAlloc, int256 redeemable, int256 margin)
// {
//     return LedgerInvariantViews.redeemabilityState( account, marketId);
// }

}