// attention needed to how we manage the fee. currently its just sent to the ledger and added to deposits


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../Interfaces/ILedger.sol";
import "./LedgerLibraries/StorageLib.sol";
import "./LedgerLibraries/DepositWithdrawLib.sol";
import "./LedgerLibraries/SolvencyLib.sol";
import "./LedgerLibraries/HeapLib.sol";
import "./LedgerLibraries/MarketManagementLib.sol";
import "./LedgerLibraries/LedgerLib.sol";
import "./LedgerLibraries/PositionTransferLib.sol";
import "./LedgerLibraries/TradeExecutionLib.sol";
import "../Interfaces/IPositionToken1155.sol";
import "./LedgerLibraries/ProtocolFeeLib.sol";
import "./LedgerLibraries/LedgerInvariantViews.sol";

using LedgerInvariantViews for *;

contract MarketMakerLedger {
    using DepositWithdrawLib for *;
    using SolvencyLib for *;
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



    modifier onlyOwner() {
        require(msg.sender == StorageLib.getStorage().owner, "Only owner");
        _;
    }

    constructor(address _usdc, address _aUSDC, address _aavePool, address _positionToken1155, address _permit2, address _ppUSDC ) {
        StorageLib.Storage storage store = StorageLib.getStorage();
        store.owner = msg.sender;
        store.usdc = IERC20(_usdc);
        store.aUSDC = IERC20(_aUSDC);
        store.aavePool = IAavePool(_aavePool);
        store.positionToken1155 = _positionToken1155;
        store.permit2 = _permit2; // may be address(0) if unused
        store.ppUSDC = IERC20(_ppUSDC);
    
        // Deploy the shared ERC20 implementation once
         s.positionERC20Implementation = address(new PositionERC20(address(this)));

    }

 

    // --- market / position management  ---
    function createMarket(string memory name, string memory ticker, address dmm, uint256 iscAmount) external onlyOwner returns (uint256 marketId) {
        marketId = MarketManagementLib.createMarket(name, ticker, dmm, iscAmount);
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
    }


    function createPositions(
    uint256 marketId,
    PositionMeta[] memory positions
    ) external onlyOwner returns (uint256[] memory positionIds) {
    require(positions.length > 0, "No positions provided");

    positionIds = new uint256[](positions.length);
    for (uint256 i = 0; i < positions.length; i++) {
        positionIds[i] = MarketManagementLib.createPosition(
            marketId,
            positions[i].name,
            positions[i].ticker
        );
     }
    }

    function addPositionToExpandingMarket(uint256 marketId, string memory name, string memory ticker) external onlyOwner { MarketManagementLib.splitFromOther(marketId, name, ticker); }

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
        // Everything else stays default/zero
        return (false, 0, 0, "", "", "", "");
    }

    marketId       = s.erc20MarketId[token];
    positionId     = s.erc20PositionId[token];
    positionName   = s.positionNames[positionId];
    positionTicker = s.positionTickers[positionId];
    marketName     = s.marketNames[marketId];
    marketTicker   = s.marketTickers[marketId];
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
        TradeExecutionLib.buyExactTokens(
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
        TradeExecutionLib.buyForUSDC(
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
        TradeExecutionLib.sellExactTokens(
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
        TradeExecutionLib.sellForUSDC(
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

    // 1) Deposit from wallet -> ledger freeCollateral for msg.sender
    uint256 recorded = DepositWithdrawLib.depositFromTraderUnified(
        msg.sender,           // ledger account credited
        msg.sender,           // trader paying USDC
        maxUSDCFromWallet,    // wallet amount we try to pull
        0,                    // minUSDCDeposited; could add a param if you want
        mode,
        eipPermit,
        permit2Calldata
    );

    // 2) Use `recorded` as the actual budget seen by the MM.
    //    This guarantees freeCollateral >= usdcIn that TradeExecutionLib will burn.
    TradeExecutionLib.buyExactTokens(
        mm,
        marketId,
        positionId,
        isBack,
        t,
        recorded       // maxUSDCIn for the MM
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

    // 1) Deposit from wallet -> ledger freeCollateral
    uint256 recorded = DepositWithdrawLib.depositFromTraderUnified(
        msg.sender,          // ledger account credited
        msg.sender,          // trader paying USDC
        usdcFromWallet,
        0,                   // minUSDCDeposited
        mode,
        eipPermit,
        permit2Calldata
    );

    // 2) Trade using whatever actually got credited (`recorded`)
    TradeExecutionLib.buyForUSDC(
        mm,
        marketId,
        positionId,
        isBack,
        recorded,       // usdcIn as seen by MM / ledger
        minTokensOut
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
        uint256 beforeFree = s.freeCollateral[msg.sender];

        // 1) Normal internal sell → credits freeCollateral (ppUSDC)
        TradeExecutionLib.sellExactTokens(
            mm,
            marketId,
            positionId,
            isBack,
            t,
            minUSDCOut
        );

        // 2) Work out how much this trade just credited
        uint256 afterFree = s.freeCollateral[msg.sender];
        require(afterFree >= beforeFree, "freeCollateral underflow");
        uint256 delta = afterFree - beforeFree;
        require(delta > 0, "no proceeds");

        // 3) Withdraw only that delta as real USDC to `to`
        DepositWithdrawLib.withdrawTo(msg.sender, delta, to);
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
        uint256 beforeFree = s.freeCollateral[msg.sender];

        // 1) Normal internal sell → credits freeCollateral (ppUSDC)
        TradeExecutionLib.sellForUSDC(
            mm,
            marketId,
            positionId,
            isBack,
            usdcOut,
            maxTokensIn
        );

        // 2) Work out how much this trade just credited
        uint256 afterFree = s.freeCollateral[msg.sender];
        require(afterFree >= beforeFree, "freeCollateral underflow");
        uint256 delta = afterFree - beforeFree;
        // Optional sanity check: delta should be == usdcOut in normal flow
        require(delta > 0, "no proceeds");

        // 3) Withdraw only that delta as real USDC to `to`
        DepositWithdrawLib.withdrawTo(msg.sender, delta, to);
        emit Withdrawn(msg.sender, delta);
    }



    // --- views / misc ---


    function getPositionLiquidity(address account, uint256 marketId, uint256 positionId)
        external view
        returns (uint256 freeCollateral, int256 allocatedCapital, int256 tilt)
    {
        return LedgerLib.getPositionLiquidity(account, marketId, positionId);
    }

    function getAvailableShares(address account, uint256 marketId, uint256 positionId)
        external view
        returns (int256)
    {
        (uint256 freeCollateral, int256 allocatedCapital, int256 tilt) =
            LedgerLib.getPositionLiquidity(account, marketId, positionId);
        return int256(freeCollateral) + allocatedCapital + int256(tilt);
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
    function getTotalFreeCollateral() external view returns (uint256) {
        return StorageLib.getStorage().totalFreeCollateral;
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
    function getMarketDetails(uint256 marketId) external view returns (string memory name, string memory ticker) {
        StorageLib.Storage storage store = StorageLib.getStorage();
        name = IPositionToken1155(store.positionToken1155).getMarketName(marketId);
        ticker = IPositionToken1155(store.positionToken1155).getMarketTicker(marketId);
        return (name, ticker);
    }
    function getPositionDetails(uint256 marketId, uint256 positionId)
        external view
        returns (string memory name, string memory ticker, uint256 backTokenId, uint256 layTokenId)
    {
        StorageLib.Storage storage store = StorageLib.getStorage();
        backTokenId = StorageLib.encodeTokenId(uint64(marketId), uint64(positionId), true);
        layTokenId  = StorageLib.encodeTokenId(uint64(marketId), uint64(positionId), false);
        name = IPositionToken1155(store.positionToken1155).getPositionName(backTokenId);
        ticker = IPositionToken1155(store.positionToken1155).getPositionTicker(backTokenId);
        return (name, ticker, backTokenId, layTokenId);
    }

    function positionExists(uint256 marketId, uint256 positionId) external view returns (bool) {
        return MarketManagementLib.positionExists(marketId, positionId);
    }



// --- allowlist for DMMs ---
    function allowDMM(address account, bool allowed) external onlyOwner {
        StorageLib.Storage storage store = StorageLib.getStorage();
        store.allowedDMMs[account] = allowed;
        emit DMMAllowed(account, allowed);
    }

        /*//////////////////////////////////////////////////////////////
                                   Turn on/off fees
    //////////////////////////////////////////////////////////////*/

    function setFeeConfig(address recipient, uint16 bps, bool enabled) external onlyOwner {
    ProtocolFeeLib.setFeeConfig(recipient, bps, enabled);
}


// ppUSDC views

function freeCollateralOf(address account) external view returns (uint256) {
    return StorageLib.getStorage().freeCollateral[account];
}

function totalFreeCollateral() external view returns (uint256) {
    return StorageLib.getStorage().totalFreeCollateral;
}

function ppUSDCTransfer(address from, address to, uint256 amount) external {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(msg.sender == s.ppUSDC, "Only ppUSDC");

    // ↓ bookkeeping: move freeCollateral between accounts
    require(s.freeCollateral[from] >= amount, "Insufficient ppUSDC");
    s.freeCollateral[from] -= amount;
    s.freeCollateral[to]   += amount;

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
    DepositWithdrawLib.withdrawTo(msg.sender, amount, to);
    emit Withdrawn(msg.sender, amount);
}

//ERC20 Transfers

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
    string memory positionName = s.positionNames[positionId];

    return string.concat(positionName, " in ", marketName);
}

function erc20Symbol(uint256 marketId, uint256 positionId)
    external
    view
    returns (string memory)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    string memory marketTicker   = s.marketTickers[marketId];
    string memory positionTicker = s.positionTickers[positionId];

    return string.concat(positionTicker, "-", marketTicker);
}





// EXPOSE LIBRARY FOR TESTS


function invariant_marketAccounting(uint256 marketId)
    external
    view
    returns (uint256 lhs, uint256 rhs)
{
    return LedgerInvariantViews.marketAccounting(marketId);
}

function invariant_iscWithinLine(uint256 marketId)
    external
    view
    returns (uint256 used, uint256 line)
{
    StorageLib.Storage storage s = StorageLib.getStorage();
    used = LedgerInvariantViews.iscSpent(marketId);
    line = s.syntheticCollateral[marketId];
}

function invariant_effectiveMin(address account, uint256 marketId)
    external
    view
    returns (int256 effMin)
{
    return LedgerInvariantViews.effectiveMinShares(account, marketId);
}

function invariant_systemFunding(uint256 marketId)
    external
    view
    returns (uint256 fullSetsSystem)
{
    return LedgerInvariantViews.totalFullSets(marketId);
}

function invariant_userFunding(uint256 marketId)
    external
    view
    returns (bool ok, uint256 fullUser, uint256 fullSystem)
{
    return LedgerInvariantViews.checkUserFundingInvariant(marketId);
}

function invariant_balancedExposure(uint256 marketId)
    external
    view
    returns (bool ok, int256 refE, uint256[] memory positions)
{
    return LedgerInvariantViews.checkBalancedExposure(marketId);
}

function invariant_tvl()
    external
    view
    returns (uint256 tvl, uint256 aUSDCBalance)
{
    return LedgerInvariantViews.tvlAccounting();
}


}