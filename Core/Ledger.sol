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
import "./LedgerLibraries/TradingLib.sol";
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
    using TradingLib for *;


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
        store.ppUSDC = IERC20(_ppUSDC)
    }

 

    // --- market / position management  ---
    function createMarket(string memory name, string memory ticker, address dmm, uint256 iscAmount) external onlyOwner returns (uint256 marketId) {
        marketId = MarketManagementLib.createMarket(name, ticker, dmm, iscAmount);
    }

    function createPosition(uint256 marketId, string memory name, string memory ticker) external onlyOwner returns (uint256 positionId) {
        positionId = MarketManagementLib.createPosition(marketId, name, ticker);
    }

    /// @notice Batch-create multiple positions for a market.
    /// @param marketId The market ID to add positions to.
    /// @param names Array of position names (must match tickers.length).
    /// @param tickers Array of position tickers (must match names.length).
    /// @return positionIds Array of newly created position IDs in order.
    
    struct PositionMeta {
    string name;
    string ticker;
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


    // --- trading entrypoints ---
    function processBuy(
        address to,
        uint256 marketId,
        address account,
        uint256 positionId,
        bool isBack,
        uint256 usdcIn,
        uint256 tokensOut,
        uint256 minUSDCDeposited,
        bool usePermit2,
        bytes calldata permitBlob
    )
        external
        returns (uint256 recordedUSDC, uint256 freeCollateral, int256 allocatedCapital, int256 newTilt)
    {
        (recordedUSDC, freeCollateral, allocatedCapital, newTilt) = TradingLib.processBuy(
            to, marketId, account, positionId, isBack, usdcIn, tokensOut, minUSDCDeposited, usePermit2, permitBlob
        );
        emit Bought(account, marketId, positionId, isBack, tokensOut, usdcIn, recordedUSDC);
        emit TiltUpdated(account, marketId, positionId, freeCollateral, allocatedCapital, newTilt);
    }

    function processSell(
        address to,
        uint256 marketId,
        address account,
        uint256 positionId,
        bool isBack,
        uint256 tokensIn,
        uint256 usdcOut
    )
        external
        returns (uint256 freeCollateral, int256 allocatedCapital, int256 newTilt)
    {
        (freeCollateral, allocatedCapital, newTilt) = TradingLib.processSell(
            to, marketId, account, positionId, isBack, tokensIn, usdcOut
        );
        emit Sold(account, marketId, positionId, isBack, tokensIn, usdcOut);
        emit TiltUpdated(account, marketId, positionId, freeCollateral, allocatedCapital, newTilt);
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