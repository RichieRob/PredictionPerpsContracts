// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";
import "./4_SolvencyLib.sol";
import "./3_HeapLib.sol";
import "./2_MarketManagementLib.sol";
import "./6_ResolutionLib.sol";

library PositionTransferLib {

/*//////////////////////////////////////////////////////////////
                       EVENTS
//////////////////////////////////////////////////////////////*/

event PositionTransfer(
    address indexed from,
    address indexed to,
    uint256 indexed marketId,
    uint256 positionId,
    bool    isBack,
    uint256 amount
);

    /*//////////////////////////////////////////////////////////////
                              CORE PRIMITIVES
    //////////////////////////////////////////////////////////////*/




    function _receiveBack(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        // H_k += amount  via tilt
        HeapLib.updateTilt(account, marketId, positionId, int256(amount));
    }

    function _receiveLay(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Lay received: layOffset += amount, tilt -= amount
        s.layOffset[account][marketId] += int256(amount);
        HeapLib.updateTilt(account, marketId, positionId, -int256(amount));
    }

    function _emitBack(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        // Sending Back: H_k -= amount via tilt
        HeapLib.updateTilt(account, marketId, positionId, -int256(amount));

    }

    function _emitLay(
        address account,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // Sending Lay: layOffset -= amount, tilt += amount
        s.layOffset[account][marketId] -= int256(amount);
        HeapLib.updateTilt(account, marketId, positionId, int256(amount));

    }

    /*//////////////////////////////////////////////////////////////
                        HIGH-LEVEL TRANSFER HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Internal Back transfer: from -> to, same market/position.
    /// @dev Caller (ledger) is responsible for checking token balances etc.
    function transferBack(
        address from,
        address to,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        require(amount > 0, "zero amount");
        require(MarketManagementLib.positionExists(marketId, positionId), "Position !exists");

        if (from != address(0)) {
            _emitBack(from, marketId, positionId, amount);
        }
        if (to != address(0)) {
            _receiveBack(to, marketId, positionId, amount);
        }
    }

    /// @notice Internal Lay transfer: from -> to, same market/position.
    function transferLay(
        address from,
        address to,
        uint256 marketId,
        uint256 positionId,
        uint256 amount
    ) internal {
        require(amount > 0, "zero amount");
        require(MarketManagementLib.positionExists(marketId, positionId), "Position !exists");

        if (from != address(0)) {
            _emitLay(from, marketId, positionId, amount);
        }
        if (to != address(0)) {
            _receiveLay(to, marketId, positionId, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       GENERIC POSITION TRANSFER SWITCH
    //////////////////////////////////////////////////////////////*/

    // _trackResolvingMarkets just helps us keep a list of all the resolving markets the user has touched 
    // elsewhere we remove markets from this list that the user has claimed from
    
    function _trackResolvingMarkets(address user, uint256 marketId) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();
    // dont store the market if it doesnt resolve
    if(s.doesResolve[marketId]==false) return;
    // check if its already stored if it is dont add it
    if (s.userMarketIndex[user][marketId] != 0) return;

    s.userMarkets[user].push(marketId);
    // using 1 for raw index 0
    s.userMarketIndex[user][marketId] = s.userMarkets[user].length;
    }

    function transferPosition(
        address from,
        address to,
        uint256 marketId,
        uint256 positionId,
        bool isBack,
        uint256 amount
    ) internal {

        StorageLib.Storage storage s = StorageLib.getStorage();
        require(!s.marketResolved[marketId], "Market resolved");
        if (isBack) {
            transferBack(from, to, marketId, positionId, amount);
        } else {
            transferLay(from, to, marketId, positionId, amount);
        }
        //update the list of markets the to and from accounts have touched
        // we need to update from because from might not actually have touched this market yet. This is because collateral essentially auto splits on transfer (if necessary)
        _trackResolvingMarkets(from, marketId);
        _trackResolvingMarkets(to, marketId); 

        

    }
}
