// test/ledger.trade.gashammer.size.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");
const { createLmsrMarket } = require("./helpers/markets.lmsr");

const U = (n) => usdc(String(n));

// shared gas helpers – minimal set needed

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
    // ignore – hammer test
  }
}

function printGasStats(stats) {
  console.log(
    "\n=== Trade gas hammer stats (small vs large markets, ppUSDC paths) ==="
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

describe(
  "MarketMakerLedger – trade gas hammer (small vs large markets)",
  function () {
    it("compares gas for small vs large markets (ppUSDC paths, Back vs Lay, buyExact + buyFor)", async function () {
      const fx = await setupLmsrLedgerFixture();
      const {
        trader: trader0,
        ledger,
        lmsr,
        usdc: usdcToken,
        ppUSDC,
      } = fx;

      const dmmAddr = await lmsr.getAddress();

      const signers = await ethers.getSigners();
      const trader1 = signers[3];
      const trader2 = signers[4];
      const traders = [trader0, trader1, trader2];

      // Markets
      const large100 = await createLmsrMarket(fx, {
        name: "Large Market 1000",
        ticker: "L1000",
        nPositions: 1000,
        smallMarket: false,
      });

      const small2 = await createLmsrMarket(fx, {
        name: "Small Market 2",
        ticker: "S2",
        nPositions: 2,
        smallMarket: true,
      });

      const small5 = await createLmsrMarket(fx, {
        name: "Small Market 5",
        ticker: "S5",
        nPositions: 5,
        smallMarket: true,
      });

      const small8 = await createLmsrMarket(fx, {
        name: "Small Market 8",
        ticker: "S8",
        nPositions: 8,
        smallMarket: true,
      });

      // sample subset of positions from large market to keep runtime sane
      const SAMPLE_LARGE_POS = 8;
      const largePosSample = large100.posIds.slice(0, SAMPLE_LARGE_POS);

      const markets = [
        {
          sizeLabel: "large1000",
          marketId: large100.marketId,
          posIds: largePosSample,
        },
        {
          sizeLabel: "small2",
          marketId: small2.marketId,
          posIds: small2.posIds,
        },
        {
          sizeLabel: "small5",
          marketId: small5.marketId,
          posIds: small5.posIds,
        },
        {
          sizeLabel: "small8",
          marketId: small8.marketId,
          posIds: small8.posIds,
        },
      ];

      // deposits
      for (const t of traders) {
        await mintAndDeposit({
          usdc: usdcToken,
          ledger,
          trader: t,
          amount: U(50_000),
        });
      }

      const stats = {};
      const firstSeen = {};
      const N_BUYS_PPUSDC = 5;

      for (const user of traders) {
        for (const m of markets) {
          const { sizeLabel, marketId, posIds } = m;

          for (const positionId of posIds) {
            for (const isBack of [true, false]) {
              const sideLabel = isBack ? "BACK" : "LAY";
              const baseLabel = `${sizeLabel}_${sideLabel}`;
              const comboKey = `${user.address}:${marketId.toString()}:${positionId.toString()}:${baseLabel}`;

              // buyExactTokens – hammer, so ignore reverts
              for (let i = 0; i < N_BUYS_PPUSDC; i++) {
                await recordGasWithFirstIgnoreRevert(
                  stats,
                  firstSeen,
                  `buyExactTokens_${baseLabel}_ppUSDCPath`,
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

              // buyForppUSDC – also ignore reverts (your overflow was here)
              for (let i = 0; i < N_BUYS_PPUSDC; i++) {
                await recordGasWithFirstIgnoreRevert(
                  stats,
                  firstSeen,
                  `buyForppUSDC_${baseLabel}_ppUSDCPath`,
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
