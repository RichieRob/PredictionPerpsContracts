// test/ledger.trade.gashammer.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, EMPTY_PERMIT, mintAndDeposit } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");

// 6-dp helper
const U = (n) => usdc(String(n));

// ──────────────────────────────────────
// gas helpers
// ──────────────────────────────────────

async function recordGas(txPromise, label, stats) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  const g = Number(receipt.gasUsed);
  stats[label] = stats[label] || [];
  stats[label].push(g);
}

// For paths that *might* revert (e.g. sells near solvency edge)
async function recordGasIgnoreRevert(txPromise, label, stats) {
  try {
    await recordGas(txPromise, label, stats);
  } catch (e) {
    // ignore reverts – this is a hammer test, not a correctness test
    // console.log(`[gas-hammer] ${label} reverted:`, e.message);
  }
}

function printStats(stats) {
  console.log("\n=== Trade gas hammer stats ===");
  for (const [label, arr] of Object.entries(stats)) {
    if (!arr || arr.length === 0) continue;
    const min = Math.min(...arr);
    const max = Math.max(...arr);
    const avg = Math.round(arr.reduce((a, b) => a + b, 0) / arr.length);
    console.log(
      `${label.padEnd(45)} -> calls: ${arr.length
        .toString()
        .padStart(3)},  min: ${min},  max: ${max},  avg: ${avg}`
    );
  }
}

// ──────────────────────────────────────
// main test
// ──────────────────────────────────────

describe("MarketMakerLedger – trade gas hammer", function () {
  it("hammers buys and sells in one LMSR market and logs gas", async function () {
    const fx = await setupLmsrLedgerFixture();
    const {
      ledger,
      lmsr,
      trader,
      usdc: usdcToken,
      ppUSDC,
      marketId,
      yesId,
    } = fx;

    const dmmAddr = await lmsr.getAddress();
    const ledgerAddr = await ledger.getAddress();

    const stats = {};

    // --- Seed trader with ppUSDC once ---

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: U(100_000),
    });

    // convenience wrappers

    const buyExact = (amountTokens, maxPpIn) =>
      ledger.connect(trader).buyExactTokens(
        dmmAddr,
        marketId,
        yesId,
        true,
        amountTokens,
        maxPpIn
      );

    const buyForPp = (ppIn, minTokensOut) =>
      ledger.connect(trader).buyForppUSDC(
        dmmAddr,
        marketId,
        yesId,
        true,
        ppIn,
        minTokensOut
      );

    const sellExact = (amountTokens, minPpOut) =>
      ledger.connect(trader).sellExactTokens(
        dmmAddr,
        marketId,
        yesId,
        true,
        amountTokens,
        minPpOut
      );

    const sellExactToWallet = (amountTokens, minUsdcOut) =>
      ledger.connect(trader).sellExactTokensForUSDCToWallet(
        dmmAddr,
        marketId,
        yesId,
        true,
        amountTokens,
        minUsdcOut
      );

    const sellForUsdcToWallet = (usdcTarget, maxTokensIn) =>
      ledger.connect(trader).sellForUSDCToWallet(
        dmmAddr,
        marketId,
        yesId,
        true,
        usdcTarget,
        maxTokensIn
      );

    // ── Phase 1: ppUSDC-based buys (these should not revert) ──

    for (let i = 0; i < 10; i++) {
      await recordGas(
        buyExact(U(100), U(1_000)),
        "buyExactTokens_ppUSDCPath",
        stats
      );

      await recordGas(
        buyForPp(U(200), 0n),
        "buyForppUSDC_ppUSDCPath",
        stats
      );
    }

    // ── Phase 2: sells back into ppUSDC (may hit solvency edge) ──

    for (let i = 0; i < 10; i++) {
      await recordGasIgnoreRevert(
        sellExact(U(50), 0n),
        "sellExactTokens_ppUSDCPath",
        stats
      );
    }

    // ── Phase 3: wallet-based paths ──

    await usdcToken.mint(trader.address, U(10_000));
    await usdcToken
      .connect(trader)
      .approve(ledgerAddr, U(10_000));

    for (let i = 0; i < 5; i++) {
      await recordGas(
        ledger.connect(trader).buyExactTokensWithUSDC(
          dmmAddr,
          marketId,
          yesId,
          true,
          U(100),
          U(1_000),
          0,              // mode: allowance
          EMPTY_PERMIT,
          "0x"
        ),
        "buyExactTokensWithUSDC_walletPath",
        stats
      );

      await recordGas(
        ledger.connect(trader).buyForUSDCWithUSDC(
          dmmAddr,
          marketId,
          yesId,
          true,
          U(200),
          0n,
          0,              // mode: allowance
          EMPTY_PERMIT,
          "0x"
        ),
        "buyForUSDCWithUSDC_walletPath",
        stats
      );
    }

    // Sells to wallet – also potentially bumping into solvency / redeemability
    for (let i = 0; i < 5; i++) {
      await recordGasIgnoreRevert(
        sellExactToWallet(U(50), 0n),
        "sellExactTokensForUSDCToWallet_walletPath",
        stats
      );

      await recordGasIgnoreRevert(
        sellForUsdcToWallet(U(50), U(1_000)),
        "sellForUSDCToWallet_walletPath",
        stats
      );
    }

    printStats(stats);

    // light sanity check (all the real invariants are in other tests)
    const finalFree = await ledger.realFreeCollateral(trader.address);
    expect(finalFree).to.be.gte(0n);
    await ppUSDC.balanceOf(trader.address); // just ensure view doesn't revert
  });
});
