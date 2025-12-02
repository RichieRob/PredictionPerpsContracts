// test/ledger.trade.gashammer.basic.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger"); // your existing fixture
const { createLmsrMarket } = require("./helpers/markets.lmsr");

const U = (n) => usdc(String(n));

// ──────────────────────────────────────
// gas helpers
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

async function recordGasWithFirstIgnoreRevert(
  stats,
  firstSeen,
  label,
  comboKey,
  txPromise
) {
  try {
    await recordGasWithFirst(stats, firstSeen, label, comboKey, txPromise);
  } catch {
    // ignore reverts – hammer test
  }
}

function printGasStats(stats) {
  console.log(
    "\n=== Trade gas hammer stats (first vs subsequent, ppUSDC paths only) ==="
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
// TEST 1 – the one you already had working
// ──────────────────────────────────────

describe(
  "MarketMakerLedger – trade gas hammer (multi-user, multi-market, multi-position)",
  function () {
    it("separates first trades from averages across users/markets/positions (ppUSDC paths, Back vs Lay, buyExact + buyFor)", async function () {
      const fx = await setupLmsrLedgerFixture();
      const {
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

      // extra LMSR markets
      const m2 = await createLmsrMarket(fx, {
        name: "Hammer Market 2",
        ticker: "HM2",
        nPositions: 2,
        smallMarket: false,
      });
      const m3 = await createLmsrMarket(fx, {
        name: "Hammer Market 3",
        ticker: "HM3",
        nPositions: 3,
        smallMarket: false,
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

      // seed each trader with ppUSDC
      for (const t of traders) {
        await mintAndDeposit({
          usdc: usdcToken,
          ledger,
          trader: t,
          amount: U(30_000),
        });
      }

      const stats = {};
      const firstSeen = {};

      const N_BUYS_PPUSDC = 10;

      for (const user of traders) {
        for (const combo of marketCombos) {
          const { marketId, positionId } = combo;

          for (const isBack of [true, false]) {
            const sideLabel = isBack ? "BACK" : "LAY";
            const comboKey = `${user.address}:${marketId.toString()}:${positionId.toString()}:${sideLabel}`;

            // buyExactTokens
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

            // buyForppUSDC
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
                  U(100),
                  0n
                )
              );
            }

            // small sells only on BACK
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
                  true,
                  U(10),
                  0n
                )
              );
            }
          }
        }
      }

      printGasStats(stats);

      const finalFree = await ledger.realFreeCollateral(trader0.address);
      expect(finalFree).to.be.gte(0n);
      await ppUSDC.balanceOf(trader0.address);
    });
  }
);
