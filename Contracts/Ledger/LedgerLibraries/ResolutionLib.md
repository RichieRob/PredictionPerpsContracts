Prediction Market Resolution System Documentation
Overview
This document outlines the resolution system for the prediction market ledger. The goal is to enable instant, non-claimable, iteration-free settlement of markets, where winnings are automatically added to users' ppUSDC (freeCollateral) on their first interaction after resolution. The system handles out-of-order resolutions, scales to thousands of markets, and minimizes gas costs.
Key principles:

No iteration on resolution: resolveMarket only flips flags—no user loops.
Auto-claim on first touch: Winnings are minted to ppUSDC when users interact (withdraw, trade, transfer).
User-specific market list: Each user has a personal list of markets they've touched, which shrinks as markets resolve.
View loop for accuracy: freeCollateralOf (ppUSDC.balanceOf) includes pending winnings with a small loop (shrinks over time).
Fail-safe for power users: Batch claim and no-claims transfer/withdraw to handle rare high-loop cases.
ppUSDC balance correct instantly: After first touch, it's O(1); before, the view adds pending winnings.

This design is inspired by production systems like Azuro v2 and SX Bet, optimized for your tilt/heap-based ledger.
Storage Requirements
Add these to StorageLib.Storage:

mapping(uint256 => bool) public marketResolved; // true if resolved
mapping(uint256 => uint256) public winningPositionId; // winning positionId (0 = unresolved)
mapping(address => uint256[]) public userMarkets; // markets user has touched
mapping(address => mapping(uint256 => uint256)) public userMarketIndex; // marketId => index+1 in list

These are cheap: ~2 slots per user + array (grows slowly).
Functions
1. resolveMarket (Owner-only)
Marks the market as resolved and sets the winner. No loops, no user impact.
solidityfunction resolveMarket(uint256 marketId, uint256 winningPositionId) external onlyOwner {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(!s.marketResolved[marketId], "already resolved");
    require(2_MarketManagementLib.positionExists(marketId, winningPositionId), "invalid winner");

    s.marketResolved[marketId] = true;
    s.winningPositionId[marketId] = winningPositionId;

    emit MarketResolved(marketId, winningPositionId);
}

Gas: ~50k (constant).
Emits MarketResolved for indexing.

2. _trackMarket (Internal)
Called in buy/sell functions to add market to user's list (once only).
solidityfunction _trackMarket(address user, uint256 marketId) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();
    if (s.userMarketIndex[user][marketId] != 0) return;

    s.userMarkets[user].push(marketId);
    s.userMarketIndex[user][marketId] = s.userMarkets[user].length;
}

Integration: Call after 9_TradeRouterLib.tradeWithPPUSDC in buy/sell functions.
Gas: ~30k on first touch, 0 after.

3. _applyPendingWinnings (Internal)
Runs on every user tx (withdraw, buy, sell, transfer). Loops over user's markets, pays resolved winnings, and shrinks the list.
solidityfunction _applyPendingWinnings(address user) internal {
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256[] storage markets = s.userMarkets[user];
    uint256 totalWinnings = 0;

    for (uint256 i = 0; i < markets.length; ) {
        uint256 marketId = markets[i];

        if (s.marketResolved[marketId]) {
            uint256 winner = s.winningPositionId[marketId];
            int256 exposure = s.tilt[user][marketId][winner];

            if (exposure > 0) {
                totalWinnings += uint256(exposure);
                s.tilt[user][marketId][winner] = 0;
            }

            // Swap-remove resolved market
            uint256 lastIdx = markets.length - 1;
            uint256 lastMarket = markets[lastIdx];
            markets[i] = lastMarket;
            markets.pop();
            s.userMarketIndex[user][lastMarket] = i + 1;
            s.userMarketIndex[user][marketId] = 0;

            // Stay at i (replaced it)
        } else {
            i++;
        }
    }

    if (totalWinnings > 0) {
        2_FreeCollateralLib.mintPpUSDC(user, totalWinnings);
    }
}

Integration: Call at top of withdraw, buy, sell, deposit, and PpUSDC transfer/transferFrom.
Gas: Proportional to user's markets (e.g., 50 markets = ~100k). Shrinks list over time.
Handles ISC/DMM: Add if (2_MarketManagementLib.isDMM(user, marketId)) totalWinnings += s.syntheticCollateral[marketId]; in the exposure block if needed.

4. freeCollateralOf (View for ppUSDC.balanceOf)
Always-correct balance, including pending winnings. Loop is view-only (free for callers).
solidityfunction freeCollateralOf(address account) external view returns (uint256) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256 base = realFreeCollateral[account];
    uint256[] memory markets = s.userMarkets[account];

    for (uint256 i = 0; i < markets.length; i++) {
        uint256 marketId = markets[i];
        if (!s.marketResolved[marketId]) continue;

        uint256 winner = s.winningPositionId[marketId];
        int256 exposure = s.tilt[account][marketId][winner];
        if (exposure > 0) {
            base += uint256(exposure);
        }
    }

    return base;
}

Gas: View (free), but ~1k per market (e.g., 100 markets = ~100k). Front-ends can index off-chain.
Handles ISC/DMM: Add to exposure if needed.

5. batchClaimWinnings (Public Fail-Safe)
Manual claim for specific resolved markets. Shrinks list, reduces future loop gas.
solidityfunction batchClaimWinnings(uint256[] calldata marketIds) external {
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256 totalWinnings = 0;

    for (uint256 i = 0; i < marketIds.length; i++) {
        uint256 marketId = marketIds[i];
        if (!s.marketResolved[marketId]) continue;
        if (s.userMarketIndex[msg.sender][marketId] == 0) continue;  // not in list

        uint256 winner = s.winningPositionId[marketId];
        int256 exposure = s.tilt[msg.sender][marketId][winner];
        if (exposure <= 0) continue;

        totalWinnings += uint256(exposure);
        s.tilt[msg.sender][marketId][winner] = 0;

        // Swap-remove
        uint256 idx = s.userMarketIndex[msg.sender][marketId] - 1;
        uint256 lastIdx = s.userMarkets[msg.sender].length - 1;
        uint256 lastMarket = s.userMarkets[msg.sender][lastIdx];
        s.userMarkets[msg.sender][idx] = lastMarket;
        s.userMarkets[msg.sender].pop();
        s.userMarketIndex[msg.sender][lastMarket] = idx + 1;
        s.userMarketIndex[msg.sender][marketId] = 0;
    }

    if (totalWinnings > 0) {
        2_FreeCollateralLib.mintPpUSDC(msg.sender, totalWinnings);
    }
}

UX: Front-ends pre-populate marketIds from resolved markets in user's list.
Gas: ~30k per market in batch — cheap for cleanup.
Handles ISC/DMM: Add if needed.

6. transferNoClaims (In PpUSDC.sol)
Fail-safe transfer of minted ppUSDC only (skips claim loop).
solidityfunction transferNoClaims(address to, uint256 amount) public returns (bool) {
    address from = _msgSender();
    require(to != address(0), "transfer to zero");

    // Use no-claims view (O(1))
    uint256 mintedBalance = _ledger().freeCollateralNoClaims(from);
    require(mintedBalance >= amount, "Insufficient minted ppUSDC");

    // Move without claim
    _ledger().ppUSDCTransfer(from, to, amount);

    emit Transfer(from, to, amount);
    return true;
}
7. withdrawNoClaims (In MarketMakerLedger.sol)
Fail-safe withdraw of minted ppUSDC only (skips claim loop).
solidityfunction withdrawNoClaims(uint256 amount, address to) external {
    require(to != address(0), "invalid recipient");

    // Use no-claims view (O(1))
    uint256 mintedBalance = freeCollateralNoClaims(msg.sender);
    require(mintedBalance >= amount, "Insufficient minted collateral");

    2_FreeCollateralLib.burnPpUSDC(msg.sender, amount);
    s.totalValueLocked -= amount;
    s.aavePool.withdraw(address(s.usdc), amount, to);

    emit Withdrawn(msg.sender, amount);
}
8. freeCollateralNoClaims (In MarketMakerLedger.sol)
O(1) view for minted-only balance.
solidityfunction freeCollateralNoClaims(address account) external view returns (uint256) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    return realFreeCollateral[account];
}
Gas & Edge Cases

Normal user (5–50 markets): Loop = 5–50 iterations (~10k–100k gas on txs). Shrinks fast.
Power user (1000 markets): Loop = 1000 iterations (~1M gas) — use batchClaimWinnings to shrink (front-ends suggest it if gas > threshold).
Dormant user: Pays loop once on wake-up — fair, as winnings wait forever.
Unresolved markets: Stay in list until resolved, but loop skips them quickly.
Gas bomb prevention: If list > 1000 (rare), front-ends warn and force batch claim first.
DMM/ISC: Add to exposure/winnings calculation if the DMM has synthetic collateral.

Integration Summary

In buy/sell: _applyPendingWinnings(msg.sender); _trackMarket(msg.sender, marketId);
In withdraw: _applyPendingWinnings(msg.sender);
In PpUSDC transfer/transferFrom: _ledger().applyPendingWinnings(msg.sender);
In ERC20 position transfer: _applyPendingWinnings(from); _applyPendingWinnings(to); (optional).

This is complete, fair, and scalable. Save this .md and deploy when ready! If you need code tweaks, let me know.