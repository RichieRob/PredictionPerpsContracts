// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LMSRStorageLib.sol";

/// @title LMSRViewLib
/// @notice Read-only helpers for prices, Z, and slot listings.
/// @dev Works purely on LMSRStorageLib.State; main contract just wraps.
library LMSRViewLib {
    uint256 internal constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                          INTERNAL SLOT HELPER
    //////////////////////////////////////////////////////////////*/

    function _requireListed(
        LMSRStorageLib.Market storage m,
        uint256               ledgerPositionId
    ) private view returns (uint256 slot) {
        uint256 v = m.slotOf[ledgerPositionId]; // 1-based; 0 = not listed
        require(v != 0, "LMSR: not listed");
        slot = v - 1;
    }

    /*//////////////////////////////////////////////////////////////
                                 PRICES
    //////////////////////////////////////////////////////////////*/

    /// @notice BACK price p(i) in 1e18 for a given ledgerPositionId.
    function getBackPriceWad(
        LMSRStorageLib.State storage s,
        uint256               marketId,
        uint256               ledgerPositionId
    ) internal view returns (uint256) {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");
        require(m.S > 0, "LMSR: S=0");

        uint256 slot = _requireListed(m, ledgerPositionId);
        // p = R_i / S  (both 1e18-scale ints)
        return uint256((m.R[slot] * int256(WAD)) / m.S);
    }

    /// @notice True LAY(not-i) price 1 − p(i) in 1e18.
    function getLayPriceWad(
        LMSRStorageLib.State storage s,
        uint256               marketId,
        uint256               ledgerPositionId
    ) internal view returns (uint256) {
        return WAD - getBackPriceWad(s, marketId, ledgerPositionId);
    }

    /// @notice Informational reserve (“Other”) price in 1e18.
    function getReservePriceWad(
        LMSRStorageLib.State storage s,
        uint256               marketId
    ) internal view returns (uint256) {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");
        require(m.S > 0, "LMSR: S=0");

        return uint256((m.R_reserve * int256(WAD)) / m.S);
    }

    /// @notice Z = G · S in 1e18 (sum of exponentials).
    function getZ(
        LMSRStorageLib.State storage s,
        uint256               marketId
    ) internal view returns (uint256) {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");
        return uint256((m.G * m.S) / int256(WAD));
    }

    /*//////////////////////////////////////////////////////////////
                              SLOT LISTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the listed ledger position ids for this market.
    /// @dev Length == numOutcomes; each entry is the ledgerPositionId for slot i.
    function listSlots(
        LMSRStorageLib.State storage s,
        uint256               marketId
    ) internal view returns (uint256[] memory listedLedgerIds) {
        LMSRStorageLib.Market storage m = LMSRStorageLib.market(s, marketId);
        require(m.initialized, "LMSR: not initialized");

        uint256 n = m.numOutcomes;
        listedLedgerIds = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            listedLedgerIds[i] = m.ledgerIdOfSlot[i];
        }
    }
}
