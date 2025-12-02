// test/ledger.trade.gashammer.flat.sweep.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupMarketFixture } = require("./helpers/markets");

// ──────────────────────────────────────
// gas helpers (same pattern as LMSR tests)
// ──────────────────────────────────────

async function gasOf(txPromise) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  return Number(receipt.gasUsed);
}

async function recordGasWithFirst(stats, firstSeen, label, comboKey, txPromise) {
  const g = await gasOf(txPromise);

  if (!firstSeen[label]) firstSeen[label] = new Set();
  if (!stats[label]) stats[label] = { first: [], subsequent: [] };

  const set = firstSeen[label];
  if (!set.has(comboKey)) {
    set.add(comboKey);
    stats[label].first.push(g);
  } else {
    stats[label].subsequent.push(g);
  }
}

function printGasStats(stats, nPositions) {
  console.log(
    `\n=== [FLAT GAS SWEEP] market with ${nPositions} positions (ppUSDC paths) ===`
  );

  const labels = Object.keys(stats);
  if (!labels.length) {
    console.log("(no data)");
    return;
  }

  const headers = [
    "label",
    "first_count",
    "first_min",
    "first_max",
    "first_avg",
    "sub_count",
    "sub_min",
    "sub_max",
    "sub_avg",
  ];

  const rows = [];

  for (const label of labels) {
    const { first, subsequent } = stats[label];
    const row = { label };

    if (first.length) {
      row.first_count = first.length;
      row.first_min = Math.min(...first);
      row.first_max = Math.max(...first);
      row.first_avg = Math.round(
        first.reduce((a, b) => a + b, 0) / first.length
      );
    } else {
      row.first_count = 0;
      row.first_min = "-";
      row.first_max = "-";
      row.first_avg = "-";
    }

    if (subsequent.length) {
      row.sub_count = subsequent.length;
      row.sub_min = Math.min(...subsequent);
      row.sub_max = Math.max(...subsequent);
      row.sub_avg = Math.round(
        subsequent.reduce((a, b) => a + b, 0) / subsequent.length
      );
    } else {
      row.sub_count = 0;
      row.sub_min = "-";
      row.sub_max = "-";
      row.sub_avg = "-";
    }

    rows.push(row);
  }

  const widths = {};
  for (const h of headers) widths[h] = h.length;
  for (const r of rows) {
    for (const h of headers) {
      const v = r[h] !== undefined ? String(r[h]) : "";
      widths[h] = Math.max(widths[h], v.length);
    }
  }

  const headerLine = headers.map((h) => String(h).padEnd(widths[h])).join("  |  ");
  console.log(headerLine);
  console.log(
    headers
      .map((h) => "-".repeat(widths[h]))
      .join("--+--")
  );

  for (const r of rows) {
    console.log(
      headers
        .map((h) => String(r[h] ?? "").padEnd(widths[h]))
        .join("  |  ")
    );
  }
}

// ──────────────────────────────────────
// helper: expand the flat market to N positions
// ──────────────────────────────────────

async function buildFlatMarketWithPositions(fx, nPositions) {
  const { ledger, marketId } = fx;

  // setupMarketFixture already created 1 position; add more up to nPositions
  const existing = await ledger.getMarketPositions(marketId);
  const existingCount = existing.length;

  for (let i = existingCount; i < nPositions; i++) {
    const label = `P${i}`;
    await ledger.createPosition(marketId, label, label);
  }

  const posIds = await ledger.getMarketPositions(marketId);
  return { marketId, posIds };
}

// ──────────────────────────────────────
//core runner for one N
// ─────────────────────────────────────-

async function runFlatSizeSweepForN(nPositions) {
  console.log(`\n===== [FLAT GAS SWEEP] market with ${nPositions} positions =====\n`);

  // single-market flatMM fixture
  const fx = await setupMarketFixture();
  const { trader, ledger, usdc: usdcToken, flatMM } = fx;
  const dmmAddr = await flatMM.getAddress();

  const { marketId, posIds } = await buildFlatMarketWithPositions(fx, nPositions);

  // seed trader with plenty of ppUSDC liquidity
  await mintAndDeposit({
    usdc: usdcToken,
    ledger,
    trader,
    amount: usdc("50000"),
  });

  const stats = {};
  const firstSeen = {};

  // keep runtime sane:
  // - small markets: hammer all positions
  // - large markets: just sample a prefix
  const MAX_POSITIONS_TO_HAMMER =
    nPositions <= 30 ? nPositions : Math.min(nPositions, 20);

  const hammeredPosIds = posIds.slice(0, MAX_POSITIONS_TO_HAMMER);

  // fewer buys per combo – we only care about first vs subsequent
  const N_BUYS_PPUSDC = 3;

  for (const positionId of hammeredPosIds) {
    for (const isBack of [true, false]) {
      const sideLabel = isBack ? "BACK" : "LAY";
      const baseLabel = `flat_${nPositions}_${sideLabel}`;
      const comboKey = `${trader.address}:${marketId.toString()}:${positionId.toString()}:${sideLabel}`;

      // buyExactTokens – ppUSDC path
      for (let i = 0; i < N_BUYS_PPUSDC; i++) {
        await recordGasWithFirst(
          stats,
          firstSeen,
          `buyExactTokens_${baseLabel}_ppUSDCPath`,
          comboKey,
          ledger.connect(trader).buyExactTokens(
            dmmAddr,
            marketId,
            positionId,
            isBack,
            usdc("10"),
            usdc("1000")
          )
        );
      }

      // buyForppUSDC – ppUSDC path
      for (let i = 0; i < N_BUYS_PPUSDC; i++) {
        await recordGasWithFirst(
          stats,
          firstSeen,
          `buyForppUSDC_${baseLabel}_ppUSDCPath`,
          comboKey,
          ledger.connect(trader).buyForppUSDC(
            dmmAddr,
            marketId,
            positionId,
            isBack,
            usdc("20"),
            0n
          )
        );
      }
    }
  }

  printGasStats(stats, nPositions);

  // sanity: system still solvent (if this ever fails, it's a big bug)
  const finalFree = await ledger.realFreeCollateral(trader.address);
  expect(finalFree).to.be.gte(0n);
}

// ──────────────────────────────────────
// test suite
// ─────────────────────────────────────-

describe("MarketMakerLedger – trade gas hammer (flat MM size sweep)", function () {
  // let this one breathe – we’re doing a lot of txs
  this.timeout(120_000);

  it("sweeps gas for flatMM across increasing market sizes", async function () {
    // you can tweak this list as you like
    const sizes = [2, 10, 30, 100, 1000, 10000];

    for (const n of sizes) {
      await runFlatSizeSweepForN(n);
    }
  });
});
