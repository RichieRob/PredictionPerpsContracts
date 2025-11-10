// SPDX-License-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";

library LiquidityLib {
    function transferLiquidity(uint256 mmId, address newAddress) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(s.mmIdToAddress[mmId] == msg.sender || msg.sender == s.owner, "Unauthorized");
        require(newAddress != address(0), "Invalid address");
        s.mmIdToAddress[mmId] = newAddress;
    }
}
