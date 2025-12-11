// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./LedgerLibraries/0_Types.sol";
import "./LedgerLibraries/0_TypesPermit.sol";

import "./LedgerLibraries/1_StorageLib.sol";
import "./LedgerLibraries/2_MarketManagementLib.sol";

import "./LedgerLibraries/5_LedgerLib.sol";
import "./LedgerLibraries/6_ResolutionLib.sol";
import "./LedgerLibraries/7_DepositWithdrawLib.sol";
import "./LedgerLibraries/8_ERC20BridgeLib.sol";
import "./LedgerLibraries/9_TradeRouterLib.sol";
import "./LedgerLibraries/7b_SettlementLib.sol";
import "./LedgerLibraries/3_HeapLib.sol";

import "./LedgerLibraries/5_LedgerInvariantViews.sol";

import "./LedgerLibraries/2_FeeLib.sol";
import "./LedgerLibraries/6_ClaimsLib.sol";

import "./LedgerLibraries/8_PpUSDCBridgeLib.sol";

struct PositionInfo {
    uint256 positionId;
    bool    isBack; // true = Back mirror, false = Lay mirror
    string  name;
    string  ticker;
}

struct PositionInfoWithBalance {
    uint256 positionId;
    bool    isBack; // true = Back mirror, false = Lay mirror
    string  name;
    string  ticker;
    uint256 balance;
}

contract Ledger {
    using MarketManagementLib for *;
    using LedgerLib for *;

    modifier onlyOwner() {
        require(msg.sender == StorageLib.getStorage().owner, "Only owner");
        _;
    }

    constructor(
        address _usdc,
        address _aUSDC,
        address _aavePool,
        address _permit2,
        address _ppUSDC
    ) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.owner   = msg.sender;
        s.usdc    = IERC20(_usdc);
        s.aUSDC   = IERC20(_aUSDC);
        s.aavePool = IAavePool(_aavePool);
        s.ppUSDC  = IERC20(_ppUSDC);
    }

    // ─────────────────────────────────────────────
    // Intents: allowlisted external intent contracts
    // ─────────────────────────────────────────────

    mapping(address => bool) public allowedIntentContracts;

    modifier onlyIntentContract() {
        require(allowedIntentContracts[msg.sender], "not intent");
        _;
    }

    function setIntentContract(address intent, bool allowed)
        external
        onlyOwner
    {
        require(intent != address(0), "intent=0");
        allowedIntentContracts[intent] = allowed;
    }

    function settleIntentP2P(
        address trader,      // buyer / payer of quote
        address filler,      // seller / payee
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 fillPrimary, // tokens
        uint256 fillQuote    // ppUSDC / USDC
    ) external onlyIntentContract {
        require(trader != address(0), "trader=0");
        require(filler != address(0), "filler=0");
        require(trader != filler, "self-fill");

        // All checks (price, sigs, partial fills) are in the external intent contract.
        SettlementLib.settle(
            trader,
            filler,
            marketId,
            positionId,
            isBack,
            fillPrimary,
            fillQuote
        );
    }

    // ─────────────────────────────────────────────
    // Market / position management
    // ─────────────────────────────────────────────

function createMarket(
    string memory name,
    string memory ticker,
    address dmm,
    uint256 iscAmount,
    bool    doesResolve,
    address oracle,
    bytes   calldata oracleParams,
    uint16  feeBps,
    address marketCreator,
    address[] calldata feeWhitelistAccounts,
    bool hasWhitelist // true = whitelist enabled, false = no whitelist forever
) external returns (uint256 marketId) {
    // NOTE: anyone can call this; you decide who `marketCreator` is.
    // Often you'd pass `marketCreator = msg.sender`, but it's flexible.
    marketId = MarketManagementLib.createMarket(
        name,
        ticker,
        dmm,
        iscAmount,
        doesResolve,
        oracle,
        oracleParams,
        feeBps,
        marketCreator,
        feeWhitelistAccounts,
        hasWhitelist
    );
}


    /// @notice Create a single position and its Back/Lay ERC20 mirrors.
    function createPosition(
        uint256 marketId,
        string memory name,
        string memory ticker
    )
        external
        
        returns (
            uint256 positionId,
            address backToken,
            address layToken
        )
    {
        (positionId, backToken, layToken) = MarketManagementLib.createPosition(
            marketId,
            name,
            ticker
        );

        // Wire the cloned ERC20s to this market/position
        ERC20BridgeLib.registerBackPositionERC20(backToken, marketId, positionId);
        ERC20BridgeLib.registerLayPositionERC20(layToken,  marketId, positionId);
    }

    /// @notice Batch create positions and their Back/Lay ERC20 mirrors.
    function createPositions(
        uint256 marketId,
        Types.PositionMeta[] memory positions
    )
        external
        onlyOwner
        returns (
            uint256[] memory positionIds,
            address[] memory backTokens,
            address[] memory layTokens
        )
    {
        require(positions.length > 0, "No positions provided");

        (positionIds, backTokens, layTokens) =
            MarketManagementLib.createPositions(marketId, positions);

        // Wire all cloned ERC20s
        for (uint256 i = 0; i < positionIds.length; i++) {
            ERC20BridgeLib.registerBackPositionERC20(
                backTokens[i],
                marketId,
                positionIds[i]
            );
            ERC20BridgeLib.registerLayPositionERC20(
                layTokens[i],
                marketId,
                positionIds[i]
            );
        }
    }

 function lockMarketPositions(uint256 marketId) external {
    MarketManagementLib.lockMarketPositions(marketId);
}

    /*//////////////////////////////////////////////////////////////
                         HWM Fee Whitelist
    //////////////////////////////////////////////////////////////*/

    function setFeeWhitelist(
        uint256 marketId,
        address account,
        bool isFree
    ) external {
        // Access control is inside FeeLib: requires msg.sender == creator
        // (and/or owner, depending on which version you keep).
        FeeLib.setFeeWhitelist(marketId, account, isFree);
    }


    // --- owner finance ops ---

    function withdrawInterest() external onlyOwner {
        DepositWithdrawLib.withdrawInterest(msg.sender);
    }


    function setNewMarketProtocolFeeShareBps(uint16 bps) external onlyOwner {
        FeeLib.setNewMarketProtocolFeeShareBps(bps);
    }


    // ─────────────────────────────────────────────
    // Exposure functions for the ERC20 mirrors
    // ─────────────────────────────────────────────

    function getERC20PositionMeta(address token)
        external
        view
        returns (
            bool   registered,
            uint256 marketId,
            uint256 positionId,
            bool   isBack,
            string memory positionName,
            string memory positionTicker,
            string memory marketName,
            string memory marketTicker
        )
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        registered = s.erc20Registered[token];
        if (!registered) {
            return (false, 0, 0, false, "", "", "", "");
        }

        marketId   = s.erc20MarketId[token];
        positionId = s.erc20PositionId[token];
        isBack     = s.erc20IsBack[token];

        positionName   = s.positionNames[marketId][positionId];
        positionTicker = s.positionTickers[marketId][positionId];

        marketName   = s.marketNames[marketId];
        marketTicker = s.marketTickers[marketId];
    }

    /// @notice Back-side ERC20 mirror for a given market/position.
    function getBackPositionERC20(
        uint256 marketId,
        uint256 positionId
    ) external view returns (address) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.positionBackERC20[marketId][positionId];
    }

    /// @notice Lay-side ERC20 mirror for a given market/position.
    function getLayPositionERC20(
        uint256 marketId,
        uint256 positionId
    ) external view returns (address) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.positionLayERC20[marketId][positionId];
    }

    /// @dev Legacy alias if you still want it; currently returns the Back ERC20.
    function getPositionERC20(
        uint256 marketId,
        uint256 positionId
    ) external view returns (address) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return s.positionBackERC20[marketId][positionId];
    }

    function positionExists(uint256 marketId, uint256 positionId)
        external
        view
        returns (bool)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        // valid if we've already allocated this positionId in this market
        return positionId < s.nextPositionId[marketId];
    }

    function erc20TotalSupply(address token)
        external
        view
        returns (uint256)
    {
        return ERC20BridgeLib.erc20TotalSupply(token);
    }

    function erc20BalanceOf(address token, address account)
        external
        view
        returns (uint256)
    {
        return ERC20BridgeLib.erc20BalanceOf(token, account);
    }

    /// @notice Raw underlying "created shares" view (Back-side semantics).
    function balanceOf(
        uint marketId,
        uint positionId,
        address account
    ) external view returns (uint256) {
        int256 avail = LedgerLib.getCreatedShares(
            account,
            marketId,
            positionId
        );
        if (avail <= 0) return 0;
        return uint256(avail);
    }

    // ─────────────────────────────────────────────
    // Trading entrypoints using and updating ppUSDC
    // ─────────────────────────────────────────────

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

    // ─────────────────────────────────────────────
    // Views / misc
    // ─────────────────────────────────────────────

    function getPositionLiquidity(
        address account,
        uint256 marketId,
        uint256 positionId
    )
        external
        view
        returns (
            uint256 _realFreeCollateral,
            int256 marketExposure,
            int256 tilt,
            uint256 amountOfISCForThisAccountAndMarket
        )
    {
        return LedgerLib.getPositionLiquidity(
            account,
            marketId,
            positionId
        );
    }

    function getMinTilt(address account, uint256 marketId)
        external
        view
        returns (int256 minTilt, uint256 minPositionId)
    {
        return LedgerLib.getMinTilt(account, marketId);
    }

    function getMaxTilt(address account, uint256 marketId)
        external
        view
        returns (int256 maxTilt, uint256 maxPositionId)
    {
        return LedgerLib.getMaxTilt(account, marketId);
    }

    function getMarketValue(uint256 marketId)
        external
        view
        returns (uint256)
    {
        return StorageLib.getStorage().marketValue[marketId];
    }

    function getTotalMarketsValue() external view returns (uint256) {
        return StorageLib.getStorage().TotalMarketsValue;
    }

    function effectiveTotalFreeCollateral()
        external
        view
        returns (uint256)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        return
            s.realTotalFreeCollateral +
            s.effectiveTotalFreeCollateralDelta;
    }

    function getTotalValueLocked() external view returns (uint256) {
        return StorageLib.getStorage().totalValueLocked;
    }

    function getMarkets() external view returns (uint256[] memory) {
        return MarketManagementLib.getMarkets();
    }

    function getMarketPositions(uint256 marketId)
        external
        view
        returns (uint256[] memory)
    {
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
    }

    // set the ERC20 Implementation

    function setPositionERC20Implementation(address impl)
        external
        onlyOwner
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(impl != address(0), "Invalid impl");
        require(
            s.positionERC20Implementation == address(0),
            "Already set"
        );
        s.positionERC20Implementation = impl;
    }



    // ppUSDC views

    function effectiveFreeCollateral(address account)
        external
        view
        returns (uint256)
    {
        return PpUSDCBridgeLib.effectiveFreeCollateral(account);
    }

    function realFreeCollateral(address account)
        external
        view
        returns (uint256)
    {
        return PpUSDCBridgeLib.realFreeCollateral(account);
    }

    function realTotalFreeCollateral() external view returns (uint256) {
        return StorageLib.getStorage().realTotalFreeCollateral;
    }


   

    function ppUSDCTransfer(
        address from,
        address to,
        uint256 amount
    ) external {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(msg.sender == address(s.ppUSDC), "Only ppUSDC");

        PpUSDCBridgeLib.ppUSDCTransfer(from, to, amount);
    }

    // -----------------------------------------------------------------------
    // Unified Deposit (Allowance / EIP-2612 / Permit2)
    // -----------------------------------------------------------------------

    // mode: 0 = allowance, 1 = EIP-2612, 2 = Permit2
    function deposit(
        address to,
        uint256 amount,
        uint256 minUSDCDeposited,
        uint8   mode,
        TypesPermit.EIP2612Permit calldata eipPermit // only used if mode==2
    ) external {
        uint256 recorded = DepositWithdrawLib.depositFromTraderUnified(
            to,              // ledger account credited
            msg.sender,      // trader paying USDC
            amount,
            minUSDCDeposited,
            mode,
            eipPermit
        );
        recorded; // silence unused var
    }

    function withdraw(uint256 amount, address to) external {
        DepositWithdrawLib.withdrawWithClaims(msg.sender, amount, to);
    }

function batchClaimWinnings(address user, uint256[] calldata marketIds) external {
    ClaimsLib.batchPullAndCredit(user, marketIds);
}



    // -----------------------------------------------------------------------
    // ERC20 Transfers
    // -----------------------------------------------------------------------

    function transferPosition(
        address to,
        uint256 marketId,
        uint256 positionId,
        bool    isBack,
        uint256 amount
    ) external {
        SettlementLib.settle(
            to,          // payer (recipient of the position)
            msg.sender,  // payee (sender of the position)
            marketId,
            positionId,
            isBack,
            amount,
            0            // quoteAmount: no ppUSDC leg
        );
    }

    function positionERC20Transfer(
        address from,
        address to,
        uint256 amount
    ) external {
        ERC20BridgeLib.erc20PositionTransfer(
            msg.sender,
            from,
            to,
            amount
        );
    }

    // -----------------------------------------------------------------------
    // ERC20 Names
    // -----------------------------------------------------------------------

    /// @notice Base name for a position (without Back/Lay prefix).
    ///         Used as the underlying descriptor for both mirrors.
    function erc20Name(uint256 marketId, uint256 positionId)
        public
        view
        returns (string memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        string memory marketName   = s.marketNames[marketId];
        string memory positionName = s.positionNames[marketId][positionId];

        return string.concat(positionName, " in ", marketName);
    }

    /// @notice Base symbol for a position (without B-/L- prefix).
    ///         Used as the underlying descriptor for both mirrors.
    function _erc20Symbol(uint256 marketId, uint256 positionId)
        internal
        view
        returns (string memory)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        string memory marketTicker   = s.marketTickers[marketId];
        string memory positionTicker = s.positionTickers[marketId][positionId];

        return string.concat(positionTicker, "-", marketTicker);
    }

    function erc20Symbol(uint256 marketId, uint256 positionId)
        external
        view
        returns (string memory)
    {
        return _erc20Symbol(marketId, positionId);
    }

    /// @notice Full ERC20 name for a specific side (Back / Lay).
    /// e.g. "Back YES in Election 2025" / "Lay YES in Election 2025".
    function erc20NameForSide(
        uint256 marketId,
        uint256 positionId,
        bool    isBack
    ) external view returns (string memory) {
        string memory base = erc20Name(marketId, positionId);
        if (isBack) {
            return string.concat("Back ", base);
        } else {
            return string.concat("Lay ", base);
        }
    }

    /// @notice Full ERC20 symbol for a specific side (Back / Lay).
    /// e.g. "B-YES-ELEC25" / "L-YES-ELEC25".
    function erc20SymbolForSide(
        uint256 marketId,
        uint256 positionId,
        bool    isBack
    ) external view returns (string memory) {
        string memory base = _erc20Symbol(marketId, positionId);
        if (isBack) {
            return string.concat("B-", base);
        } else {
            return string.concat("L-", base);
        }
    }

    // -----------------------------------------------------------------------
    // Resolve
    // -----------------------------------------------------------------------

    function resolveMarket(uint256 marketId) external onlyOwner {
        ResolutionLib.resolveFromOracle(marketId);
    }

    /// @notice Manually resolve a market to a winning position
    function resolveMarket(
        uint256 marketId,
        uint256 winningPositionId
    ) external onlyOwner {
        ResolutionLib._resolveMarketCore(marketId, winningPositionId);
    }

    function getMinTiltDelta(address account, uint256 marketId)
        external
        view
        returns (uint256)
    {
        int256 d = HeapLib._getMinTiltDelta(account, marketId);
        if (d <= 0) {
            return 0;
        }
        return uint256(d);
    }

    //   // EXPOSE LIBRARY FOR TESTS

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

    function invariant_tvl()
        external
        view
        returns (uint256 tvl, uint256 aUSDCBalance)
    {
        return LedgerInvariantViews.tvlAccounting();
    }

    function invariant_systemBalance()
        external
        view
        returns (uint256 lhs, uint256 rhs)
    {
        return LedgerInvariantViews.systemBalance();
    }

    function invariant_checkSolvencyAllMarkets(address account)
        external
        view
        returns (bool ok)
    {
        return LedgerInvariantViews.checkSolvencyAllMarkets(account);
    }

    function invariant_redeemabilityState(
        address account,
        uint256 marketId
    )
        external
        view
        returns (int256 netAlloc, int256 redeemable, int256 margin)
    {
        return LedgerInvariantViews.redeemabilityState(account, marketId);
    }

    function debugFeeState(address account, uint256 marketId)
        external
        view
        returns (
            uint16 feeBps,
            uint16 protocolShareBps,
            bool   hasWhitelist,
            bool   isWhitelisted,
            uint256 spent,
            uint256 redeemed,
            uint256 hwm,
            uint256 realFree
        )
    {
        StorageLib.Storage storage s = StorageLib.getStorage();

        FeesConfig storage cfg = s.feesConfig[marketId];

        feeBps           = cfg.feeBps;
        protocolShareBps = cfg.protocolShareBps;
        hasWhitelist     = cfg.hasWhitelist;
        isWhitelisted    = s.feeWhiteList[marketId][account];

        spent    = s.USDCSpent[account][marketId];
        redeemed = s.redeemedUSDC[account][marketId];
        hwm      = s.netUSDCAllocationHighWatermark[account][marketId];

        realFree = s.realFreeCollateral[account];
    }


}
