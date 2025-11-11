
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./DepositWithdrawLib.sol";
import "./SolvencyLib.sol";
import "./HeapLib.sol";
import "./TokenOpsLib.sol";
import "./LedgerLib.sol";
import "./TypesPermit.sol";
import "./MarketManagementLib.sol";

library TradingLib {
    using TypesPermit for *;

    function receiveBackToken(uint256 mmId, uint256 marketId, uint256 positionId, uint256 amount) internal {
        HeapLib.updateTilt(mmId, marketId, positionId, int128(uint128(amount)));
        TokenOpsLib.burnToken(marketId, positionId, true, amount, msg.sender);
        SolvencyLib.deallocateExcess(mmId, marketId);
    }

    function receiveLayToken(uint256 mmId, uint256 marketId, uint256 positionId, uint256 amount) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.layOffset[mmId][marketId] += int256(amount);
        HeapLib.updateTilt(mmId, marketId, positionId, -int128(uint128(amount)));
        TokenOpsLib.burnToken(marketId, positionId, false, amount, msg.sender);
        SolvencyLib.deallocateExcess(mmId, marketId);
    }

    function emitBack(uint256 mmId, uint256 marketId, uint256 positionId, uint256 amount, address to) internal {
        HeapLib.updateTilt(mmId, marketId, positionId, -int128(uint128(amount)));
        TokenOpsLib.mintToken(marketId, positionId, true, amount, to);
        SolvencyLib.ensureSolvency(mmId, marketId);
    }

    function emitLay(uint256 mmId, uint256 marketId, uint256 positionId, uint256 amount, address to) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        s.layOffset[mmId][marketId] -= int256(amount);
        HeapLib.updateTilt(mmId, marketId, positionId, int128(uint128(amount)));
        TokenOpsLib.mintToken(marketId, positionId, false, amount, to);
        SolvencyLib.ensureSolvency(mmId, marketId);
    }

    function processBuy(
        address to,
        uint256 marketId,
        uint256 mmId,
        uint256 positionId,
        bool isBack,
        uint256 usdcIn,
        uint256 tokensOut,
        uint256 minUSDCDeposited,
        bool usePermit2,
        bytes calldata permitBlob
    )
        internal
        returns (uint256 recordedUSDC, uint256 freeCollateral, int256 allocatedCapital, int128 newTilt)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.mmIdToAddress[mmId] == msg.sender, "Invalid MMId");
        require(MarketManagementLib.positionExists(marketId, positionId), "Position !exists");


        if (usdcIn > 0) {
            if (usePermit2) {
                recordedUSDC = DepositWithdrawLib.depositFromTraderWithPermit2(
                    mmId, to, usdcIn, minUSDCDeposited, permitBlob
                );
            } else {
                TypesPermit.EIP2612Permit memory p = abi.decode(permitBlob, (TypesPermit.EIP2612Permit));
                recordedUSDC = DepositWithdrawLib.depositFromTraderWithEIP2612(
                    mmId, to, usdcIn, minUSDCDeposited, p
                );
            }
        } else {
            recordedUSDC = 0;
        }

        if (isBack) {
            emitBack(mmId, marketId, positionId, tokensOut, to);
        } else {
            emitLay(mmId, marketId, positionId, tokensOut, to);
        }

        (freeCollateral, allocatedCapital, newTilt) = LedgerLib.getPositionLiquidity(mmId, marketId, positionId);
    }

    function processSell(
        address to,
        uint256 marketId,
        uint256 mmId,
        uint256 positionId,
        bool isBack,
        uint256 tokensIn,
        uint256 usdcOut
    )
        internal
        returns (uint256 freeCollateral, int256 allocatedCapital, int128 newTilt)
    {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.mmIdToAddress[mmId] == msg.sender, "Invalid MMId");
        require(MarketManagementLib.positionExists(marketId, positionId), "Position !exists");


        // Burn incoming tokens and update tilt/capital
        if (isBack) {
            receiveBackToken(mmId, marketId, positionId, tokensIn);
        } else {
            receiveLayToken(mmId, marketId, positionId, tokensIn);
        }

        // Pay the trader directly from Aave via the ledger
        if (usdcOut > 0) {
            DepositWithdrawLib.withdrawTo(mmId, usdcOut, to);
        }

        (freeCollateral, allocatedCapital, newTilt) = LedgerLib.getPositionLiquidity(mmId, marketId, positionId);
    }
}