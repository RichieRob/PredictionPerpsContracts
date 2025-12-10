// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./1_StorageLib.sol";

/// @title FeeLib
/// @notice All logic for creator/protocol fees on markets.
/// @dev Design:
///      - Fees are configured *per market* via FeesConfig in StorageLib.
///      - A global `newMarketProtocolFeeShareBps` is snapshotted into each
///        new market's FeesConfig at creation.
///      - Actual fee charging is done on *increases* in the MM's net USDC
///        allocation to a market:
///
///            netAlloc(account, marketId) = USDCSpent - redeemedUSDC
///
///        We maintain a high watermark:
///
///            netAllocHWM(account, marketId)
///
///        and charge fees on the positive delta:
///
///            delta = netAlloc_now - netAllocHWM_prev   (if > 0)
///
///        Fees are paid entirely via internal movements of realFreeCollateral:
///          - debited from the payer (MM / payee)
///          - credited to the market creator and protocol (s.owner)
///        No change to totalValueLocked or realTotalFreeCollateral.
///        No ppUSDC events here – this is 100% ledger-internal accounting.
library FeeLib {
    // -----------------------------------------------------------------------
    // Global config for future markets
    // -----------------------------------------------------------------------

    /// @notice Set the protocol's share of creator fees for *future* markets.
    /// @dev To be wrapped by an onlyOwner function on the Ledger:
    ///
    ///     function setNewMarketProtocolFeeShareBps(uint16 bps)
    ///         external
    ///         onlyOwner
    ///     {
    ///         FeeLib.setNewMarketProtocolFeeShareBps(bps);
    ///     }
    ///
    /// This does NOT retroactively affect existing markets; it only changes
    /// what will be snapshotted into FeesConfig for newly created markets.
    function setNewMarketProtocolFeeShareBps(uint16 bps) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        require(bps <= 10_000, "FeeLib: bps > 100%");
        s.newMarketProtocolFeeShareBps = bps;
    }

    // -----------------------------------------------------------------------
    // Per-market init (called at market creation)
    // -----------------------------------------------------------------------

    /// @notice Initialise fee config + whitelist for a new market.
    /// @dev To be called from your Ledger.createMarket wrapper *after*
    ///      MarketManagementLib.createMarket has returned a marketId.
    function initMarketFees(
        uint256 marketId,
        uint16  feeBps,
        address marketCreator,
        address[] memory feeWhitelistAccounts,
        address dmm,
        bool    hasWhitelist        // true = whitelist enabled, false = no whitelist
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();

        FeesConfig storage cfg = s.feesConfig[marketId];
        cfg.feeBps           = feeBps;
        cfg.protocolShareBps = s.newMarketProtocolFeeShareBps;
        cfg.creator          = marketCreator;
        cfg.hasWhitelist     = hasWhitelist;

        // If whitelist disabled — do nothing else
        if (!hasWhitelist) return;

        // Initial whitelist
        for (uint256 i = 0; i < feeWhitelistAccounts.length; i++) {
            address addr = feeWhitelistAccounts[i];
            if (addr != address(0)) {
                s.feeWhiteList[marketId][addr] = true;
            }
        }

        // Auto-whitelist DMM if provided
        if (dmm != address(0)) {
            s.feeWhiteList[marketId][dmm] = true;
        }
    }

    // -----------------------------------------------------------------------
    // Fee application on net allocation increases (HWM-style)
    // -----------------------------------------------------------------------

    function applyNetAllocationFee(
        StorageLib.Storage storage s,
        address account,
        uint256 marketId
    ) internal {
        FeesConfig storage cfg = s.feesConfig[marketId];

        // 1) Fast exits: no fee on this market or account is whitelisted
        if (cfg.feeBps == 0) return;
        if (s.feeWhiteList[marketId][account]) return;

        // 2) Current net allocation in this market
        uint256 spent    = s.USDCSpent[account][marketId];
        uint256 redeemed = s.redeemedUSDC[account][marketId];

        // If netAlloc <= 0, no fee or HWM update
        if (spent <= redeemed) return;

        uint256 currentNet = spent - redeemed;

        // 3) Compare against stored high watermark
        uint256 prevHwm = s.netUSDCAllocationHighWatermark[account][marketId];
        if (currentNet <= prevHwm) {
            return; // no new high, no fee
        }

        uint256 delta = currentNet - prevHwm;
        s.netUSDCAllocationHighWatermark[account][marketId] = currentNet;

        // 4) Compute fee on Δ(netAlloc)
        uint256 feeBase = (delta * uint256(cfg.feeBps)) / 10_000;
        if (feeBase == 0) return;

        // Split between creator and protocol share
        uint256 feeProtocol = 0;
        uint256 feeCreator  = feeBase;

        if (cfg.protocolShareBps > 0) {
            feeProtocol = (feeBase * uint256(cfg.protocolShareBps)) / 10_000;
            feeCreator  = feeBase - feeProtocol;
        }

        // 5) Debit payer's free collateral (reverts if insufficient)
        s.realFreeCollateral[account] -= feeBase;

        // 6) Credit creator
        if (feeCreator > 0 && cfg.creator != address(0)) {
            s.realFreeCollateral[cfg.creator] += feeCreator;
        }

        // 7) Credit protocol (owner) as a normal ledger user
        if (feeProtocol > 0) {
            s.realFreeCollateral[s.owner] += feeProtocol;
        }
    }

    // -----------------------------------------------------------------------
    // Whitelist management (post-market-creation)
    // -----------------------------------------------------------------------

    function setFeeWhitelist(
        uint256 marketId,
        address account,
        bool isFree
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        FeesConfig storage cfg = s.feesConfig[marketId];

        require(cfg.hasWhitelist, "FeeLib: whitelist disabled");
        require(account != address(0), "FeeLib: zero addr");
        require(
            msg.sender == cfg.creator || msg.sender == s.owner,
            "FeeLib: not authorised"
        );

        s.feeWhiteList[marketId][account] = isFree;
    }
}
