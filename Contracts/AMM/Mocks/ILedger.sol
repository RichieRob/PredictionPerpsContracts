// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILedger {
    function positionExists(uint256 marketId, uint256 positionId)
        external
        view
        returns (bool);

    function processBuy(
        address trader,
        uint256 marketId,
        uint256 mmId,
        uint256 positionId,
        bool isBack,
        uint256 usdcIn,
        uint256 tOut,
        uint256 referral,
        bool usePermit2,
        bytes calldata permitBlob
    ) external;

    function processSell(
        address trader,
        uint256 marketId,
        uint256 mmId,
        uint256 positionId,
        bool isBack,
        uint256 tIn,
        uint256 usdcOut
    ) external;
}
