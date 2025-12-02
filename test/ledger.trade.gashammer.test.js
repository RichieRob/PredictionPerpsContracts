// test/ledger.trade.gashammer.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");

const U = (n) => usdc(String(n));

// ──────────────────────────────────────
// gas helpers
// ──────────────────────────────────────

async function gasOf(txPromise) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  return Number(receipt.gasUsed);
}

/**
 * stats shape:
 * {
 *   [label]: {
 *     first: number[],
 *     subsequent: number[],
 *   }
 * }
 *
 * firstSeen[label] is a Set of comboKeys that already had a "first"
 */
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

// For paths that *might* revert (e.g. sells / weird edge cases)
async function recordGasWithFirstIgnoreRevert(
  stats,
  firstSeen,
  label,
  comboKey,
  txPromise
) {
  try {
    await recordGasWithFirst(stats, firstSeen, label, comboKey, txPromise);
  } catch (e) {
    // hammer test: we only care about gas where it succeeds
    // console.log(`[gas-hammer] ${label} (${comboKey}) reverted:`, e.message);
  }
}

function printGasStats(stats) {
  console.log("\n=== Trade gas hammer stats (first vs subsequent, ppUSDC paths only) ===");

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
      row.first_min = first.length ? Math.min(...first) : "-";
      row.first_max = first.length ? Math.max(...first) : "-";
      row.first_avg = Math.round(first.reduce((a, b) => a + b, 0) / first.length);
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

  // pretty-print table
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
// helper: create extra LMSR markets
// ──────────────────────────────────────

async function createLmsrMarket({ owner, ledger, lmsr }, opts = {}) {
  const {
    name = "Extra Market",
    ticker = "EXTRA",
    nPositions = 2,
  } = opts;

  const lmsrAddr = await lmsr.getAddress();

  // 1) create the market with an ISC line
  const iscAmount = U(100_000);
  await ledger.createMarket(
    name,
    ticker,
    lmsrAddr,
    iscAmount,
    false,
    ethers.ZeroAddress,
    "0x"
  );

  const markets = await ledger.getMarkets();
  const marketId = markets[markets.length - 1];

  // 2) create positions
  const posIds = [];
  for (let i = 0; i < nPositions; i++) {
    const label = `P${i}`;
    await ledger.createPosition(marketId, label, label);
  }
  const created = await ledger.getMarketPositions(marketId);
  for (const p of created) posIds.push(p);

  // 3) init LMSR priors (equal split)
  const r = ethers.parseEther(String(1 / posIds.length));
  const priors = posIds.map((positionId) => ({ positionId, r }));
  const liabilityUSDC = U(1_000);

  await lmsr
    .connect(owner)
    .initMarket(
      marketId,
      priors,
      liabilityUSDC,
      0, // reserve0
      false
    );

  return { marketId, posIds };
}

// ──────────────────────────────────────
// main test (ppUSDC paths only)
// ──────────────────────────────────────

describe(
  "MarketMakerLedger – trade gas hammer (multi-user, multi-market, multi-position)",
  function () {
    it("separates first trades from averages across users/markets/positions (ppUSDC paths, Back vs Lay, buyExact + buyFor)", async function () {
      const fx = await setupLmsrLedgerFixture();
      const {
        owner,
        trader: trader0,
        ledger,
        lmsr,
        usdc: usdcToken,
        marketId: baseMarketId,
        yesId: baseYesId,
        ppUSDC,
      } = fx;

      const dmmAddr = await lmsr.getAddress();

      // extra traders
      const signers = await ethers.getSigners();
      const trader1 = signers[3];
      const trader2 = signers[4];
      const traders = [trader0, trader1, trader2];

      // extra LMSR markets (1 simple, 1 multi-outcome)
      const m2 = await createLmsrMarket(fx, {
        name: "Hammer Market 2",
        ticker: "HM2",
        nPositions: 2,
      });
      const m3 = await createLmsrMarket(fx, {
        name: "Hammer Market 3",
        ticker: "HM3",
        nPositions: 3,
      });

      const m1_id = baseMarketId;
      const m1_pos = baseYesId;

      const m2_id = m2.marketId;
      const [m2_pos0, m2_pos1] = m2.posIds;

      const m3_id = m3.marketId;
      const [m3_pos0, m3_pos1, m3_pos2] = m3.posIds;

      const marketCombos = [
        { marketId: m1_id, positionId: m1_pos },
        { marketId: m2_id, positionId: m2_pos0 },
        { marketId: m2_id, positionId: m2_pos1 },
        { marketId: m3_id, positionId: m3_pos0 },
        { marketId: m3_id, positionId: m3_pos1 },
        { marketId: m3_id, positionId: m3_pos2 },
      ];

      // seed each trader with ppUSDC (deposit once)
      for (const t of traders) {
        await mintAndDeposit({
          usdc: usdcToken,
          ledger,
          trader: t,
          amount: U(30_000),
        });
      }

      const stats = {};
      const firstSeen = {}; // per-label Set of combo keys

      // a bit more hammering than before
      const N_BUYS_PPUSDC = 10;

      // ──────────────────────────────────────
      // ppUSDC-based buys (Back + Lay) + small sells (Back only)
      // ──────────────────────────────────────

      for (const user of traders) {
        for (const combo of marketCombos) {
          const { marketId, positionId } = combo;

          for (const isBack of [true, false]) {
            const sideLabel = isBack ? "BACK" : "LAY";
            const comboKey = `${user.address}:${marketId.toString()}:${positionId.toString()}:${sideLabel}`;

            // --- buyExactTokens (Back / Lay) ---
            for (let i = 0; i < N_BUYS_PPUSDC; i++) {
              await recordGasWithFirst(
                stats,
                firstSeen,
                `buyExactTokens_${sideLabel}_ppUSDCPath`,
                comboKey,
                ledger.connect(user).buyExactTokens(
                  dmmAddr,
                  marketId,
                  positionId,
                  isBack,
                  U(50),
                  U(1_000)
                )
              );
            }

            // --- buyForppUSDC (Back / Lay) ---
            for (let i = 0; i < N_BUYS_PPUSDC; i++) {
              await recordGasWithFirst(
                stats,
                firstSeen,
                `buyForppUSDC_${sideLabel}_ppUSDCPath`,
                comboKey,
                ledger.connect(user).buyForppUSDC(
                  dmmAddr,
                  marketId,
                  positionId,
                  isBack,
                  U(100), // ppUSDC in
                  0n      // minTokensOut
                )
              );
            }

            // For now, small sells only on BACK side (lays are already a bit more
            // complex in how they net against backs; we just want one sell row).
            if (isBack) {
              await recordGasWithFirstIgnoreRevert(
                stats,
                firstSeen,
                "sellExactTokens_BACK_ppUSDCPath",
                comboKey,
                ledger.connect(user).sellExactTokens(
                  dmmAddr,
                  marketId,
                  positionId,
                  true,    // Back side
                  U(10),
                  0n
                )
              );
            }
          }
        }
      }

      // ──────────────────────────────────────
      // print stats + light sanity
      // ──────────────────────────────────────

      printGasStats(stats);

      const finalFree = await ledger.realFreeCollateral(trader0.address);
      expect(finalFree).to.be.gte(0n);

      // just ensure ppUSDC views still behave
      await ppUSDC.balanceOf(trader0.address);
    });
  }
);
