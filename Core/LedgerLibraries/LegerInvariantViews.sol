library LedgerInvariantViews {
    using MarketManagementLib for uint256;

    function marketAccounting(StorageLib.Storage storage s, uint256 marketId)
        internal
        view
        returns (uint256 lhs, uint256 rhs)
    {
        lhs = s.marketValue[marketId];
        rhs = s.MarketUSDCSpent[marketId] - s.Redemptions[marketId];
    }

    function effectiveMinShares(StorageLib.Storage storage s, uint256 mmId, uint256 marketId)
        internal
        view
        returns (int256 effMin)
    {
        int256 realMin = SolvencyLib.computeRealMinShares(s, mmId, marketId);
        effMin = SolvencyLib.computeEffectiveMinShares(s, mmId, marketId, realMin);
    }

        /// @notice Conceptual "ISC needed" for this market: how far below zero the DMM's
    ///         real min-shares would be without any synthetic collateral.
    /// @dev Defined as:
    ///        realMinShares = USDCSpent + layOffset + minTilt
    ///        iscSpent      = max(0, -realMinShares)
    ///
    ///     This is intentionally *not* clamped by syntheticCollateral[marketId]:
    ///     if iscSpent > syntheticCollateral, that indicates an invariant breach,
    ///     which is exactly what we want to be able to detect in tests / off-chain checks.
    function iscSpent(uint256 marketId) internal view returns (uint256 iscSpent) {
        StorageLib.Storage storage s = StorageLib.getStorage();

        // The designated DMM for this market is the one whose solvency we care about
        uint256 dmmId = s.marketToDMM[marketId];

        // realMin = USDCSpent + layOffset + minTilt (for this DMM in this market)
        int256 realMin = SolvencyLib.computeRealMinShares(s, dmmId, marketId);

        if (realMin >= 0) {
            // Real capital alone is enough; no synthetic "needed"
            return 0;
        }

        // How far below zero realMin is — this is the notional ISC requirement
        return uint256(-realMin);
    }
}
