
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILedger {
    // Events
    event Deposited(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event TiltUpdated(address indexed account, uint256 indexed marketId, uint256 indexed positionId, uint256 freeCollateral, int256 allocatedCapital, int256 newTilt);
    event Bought(address indexed account, uint256 indexed marketId, uint256 indexed positionId, bool isBack, uint256 tokensOut, uint256 usdcIn, uint256 recordedUSDC);
    event Sold(address indexed account, uint256 indexed marketId, uint256 indexed positionId, bool isBack, uint256 tokensIn, uint256 usdcOut);
    event Redeemed(uint256 indexed marketId, uint256 amount);
    event MarketMakerRegistered(address indexed mmAddress, address account);
    event LiquidityTransferred(address indexed account, address indexed oldAddress, address indexed newAddress);

    // Market and Position Management
    function createMarket(string memory name, string memory ticker) external returns (uint256 marketId);
    function createPosition(uint256 marketId, string memory name, string memory ticker) external returns (uint256 positionId);

    // Owner Finance Operations
    function withdrawInterest() external;

    // Redemption
    function redeemSet(uint256 marketId, uint256[] memory positionIds, uint256 amount, address to) external;

    // Trading Entrypoints
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
    ) external returns (uint256 recordedUSDC, uint256 freeCollateral, int256 allocatedCapital, int256 newTilt);

    function processSell(
        address to,
        uint256 marketId,
        address account,
        uint256 positionId,
        bool isBack,
        uint256 tokensIn,
        uint256 usdcOut
    ) external returns (uint256 freeCollateral, int256 allocatedCapital, int256 newTilt);

    // Views / Miscellaneous
    function transferLiquidity(address account, address newAddress) external;
    function getPositionLiquidity(address account, uint256 marketId, uint256 positionId)
        external view returns (uint256 freeCollateral, int256 allocatedCapital, int256 tilt);
    function getAvailableShares(address account, uint256 marketId, uint256 positionId) external view returns (int256);
    function getMinTilt(address account, uint256 marketId) external view returns (int256 minTilt, uint256 minPositionId);
    function getMarketValue(uint256 marketId) external view returns (uint256);
    function getTotalMarketsValue() external view returns (uint256);
    function getTotalFreeCollateral() external view returns (uint256);
    function getTotalValueLocked() external view returns (uint256);
    function getMarkets() external view returns (uint256[] memory);
    function getMarketPositions(uint256 marketId) external view returns (uint256[] memory);
    function getMarketDetails(uint256 marketId) external view returns (string memory name, string memory ticker);
    function getPositionDetails(uint256 marketId, uint256 positionId)
        external view returns (string memory name, string memory ticker, uint256 backTokenId, uint256 layTokenId);
}
