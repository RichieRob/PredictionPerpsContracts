// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";

library ProtocolFeeLib {
    event FeeConfigUpdated(address indexed recipient, uint16 feeBps, bool enabled);
    event FeeSkimmed(address indexed recipient, uint256 feeAamount);

    /// @notice Set / update protocol fee config (stored in ledger storage).
    function setFeeConfig(address recipient, uint16 bps, bool enabled) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(bps <= 1000, "fee too high"); // cap @ 10%
        s.feeRecipient = recipient;
        s.feeBps = bps;
        s.feeEnabled = enabled;
        emit FeeConfigUpdated(recipient, bps, enabled);
    }

    /// @notice Skim fee *in aUSDC* after supplying to Aave. Returns net credited to MM.
    /// @dev Call this right after computing (a1 - a0). If fee disabled or zero, returns aReceived unchanged.
    function skimOnAaveSupply(uint256 aReceived) internal returns (uint256 net) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        if (!s.feeEnabled || s.feeRecipient == address(0) || s.feeBps == 0) {
            return aReceived;
        }
        uint256 feeA = (aReceived * s.feeBps) / 10_000;
        if (feeA == 0) return aReceived;

        // transfer aUSDC fee to recipient (continues earning yield)
        require(s.aUSDC.transfer(s.feeRecipient, feeA), "aUSDC fee xfer fail");
        emit FeeSkimmed(s.feeRecipient, feeA);
        return aReceived - feeA;
    }
}
