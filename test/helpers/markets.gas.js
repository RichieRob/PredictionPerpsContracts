// test/helpers/markets.gas.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./core");
const { createLmsrMarket } = require("./markets.lmsr");

const U = (n) => usdc(String(n));

// ──────────────────────────────────────
// Simple gas helper: market + N positions
// ──────────────────────────────────────

async function expectGasForMarketWithPositions(
  fx,
  {
    marketName,
    marketTicker,
    dmmAddress,
    iscAmount = 0n,
    positions,
  }
) {
  const { ledger, owner } = fx;

  // Make sure the DMM is allowed before creating the market
  await ledger.connect(owner).allowDMM(dmmAddress, true);

  // Create market (NEW SIGNATURE)
  const createMarketTx = await ledger.createMarket(
    marketName,
    marketTicker,
    dmmAddress,          // dmm
    iscAmount,           // iscAmount
    false,               // doesResolve (gas test non-resolving)
    ethers.ZeroAddress,  // oracle
    "0x",                // oracleParams
    0,                   // feeBps
    owner.address,       // marketCreator
    [],                  // feeWhitelistAccounts
    false                // hasWhitelist
  );
  const createMarketReceipt = await createMarketTx.wait();
  console.log(
    "createMarket gas used:",
    createMarketReceipt.gasUsed.toString()
  );

  const markets = await ledger.getMarkets();
  expect(markets.length).to.equal(1);
  const marketId = markets[0];

  // Verify market details
  const [marketNameOnChain, marketTickerOnChain] =
    await ledger.getMarketDetails(marketId);
  expect(marketNameOnChain).to.equal(marketName);
  expect(marketTickerOnChain).to.equal(marketTicker);

  // Create positions in batch (ONLY OWNER)
  const createPositionsTx = await ledger
    .connect(owner)
    .createPositions(marketId, positions);
  const createPositionsReceipt = await createPositionsTx.wait();
  console.log(
    `createPositions (${positions.length} positions) gas used:`,
    createPositionsReceipt.gasUsed.toString()
  );

  // Verify positions created
  const positionIds = await ledger.getMarketPositions(marketId);
  expect(positionIds.length).to.equal(positions.length);

  // Spot-check up to 3 positions & ERC20 wiring
  for (let i = 0; i < Math.min(3, positions.length); i++) {
    const pid = positionIds[i];

    const [posName, posTicker] =
      await ledger.getPositionDetails(marketId, pid);
    expect(posName).to.equal(positions[i].name);
    expect(posTicker).to.equal(positions[i].ticker);

    const erc20Name   = await ledger.erc20Name(marketId, pid);
    const erc20Symbol = await ledger.erc20Symbol(marketId, pid);

    expect(erc20Name).to.equal(
      `${positions[i].name} in ${marketName}`
    );
    expect(erc20Symbol).to.equal(
      `${positions[i].ticker}-${marketTicker}`
    );
  }

  const totalGas =
    createMarketReceipt.gasUsed + createPositionsReceipt.gasUsed;
  console.log(
    "Total gas for market + positions:",
    totalGas.toString()
  );
  console.log(
    "Average gas per position:",
    (createPositionsReceipt.gasUsed / BigInt(positions.length)).toString()
  );

  return {
    marketId,
    positionIds,
    gasCreateMarket: createMarketReceipt.gasUsed,
    gasCreatePositions: createPositionsReceipt.gasUsed,
  };
}

// ──────────────────────────────────────
// Shared hammer helpers
// ─────────────────────────────────────-

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
    // ignore – hammer test: we only care about successful txs
  }
}

function printGasStats(stats, heading) {
  console.log(
    `\n=== Trade gas hammer stats (${heading}) ===`
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

/**
 * Run the "small vs large market" gas hammer for an arbitrary large market size.
 *
 * @param {object} fx         fixture from setupLmsrLedgerFixture()
 * @param {number} largeN     number of positions in the large market (e.g. 10, 30, 1000, 10000)
 * @param {object} options
 *    - sampleLargePositions: how many positions from the large market to sample (default: 8)
 */
async function runSizeGasHammer(fx, largeN, options = {}) {
  const {
    trader: trader0,
    ledger,
    lmsr,
    usdc: usdcToken,
    ppUSDC,
  } = fx;

  const sampleLargePositions = options.sampleLargePositions ?? 8;

  const dmmAddr = await lmsr.getAddress();

  const signers = await ethers.getSigners();
  const trader1 = signers[3];
  const trader2 = signers[4];
  const traders = [trader0, trader1, trader2];

  // ──────────────────────────────────────
  // Markets: 1 large + 3 small
  // ─────────────────────────────────────-

  const large = await createLmsrMarket(fx, {
    name: `Large Market ${largeN}`,
    ticker: `L${largeN}`,
    nPositions: largeN,
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
  const largePosSample = large.posIds.slice(0, sampleLargePositions);

  const markets = [
    {
      sizeLabel: `large${largeN}`,
      marketId: large.marketId,
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

  // ──────────────────────────────────────
  // Deposits
  // ─────────────────────────────────────-

  for (const t of traders) {
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: t,
      amount: U(50_000),
    });
  }

  // ──────────────────────────────────────
  // Hammer
  // ─────────────────────────────────────-

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

          // buyExactTokens – hammer, ignore reverts
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

          // buyForppUSDC – hammer, ignore reverts
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

  printGasStats(
    stats,
    `small vs large markets, large=${largeN} positions, ppUSDC paths`
  );

  const finalFree = await ledger.realFreeCollateral(trader0.address);
  if (finalFree < 0n) {
    throw new Error("finalFree collateral went negative");
  }
  await ppUSDC.balanceOf(trader0.address);

  return { stats };
}

module.exports = {
  expectGasForMarketWithPositions,
  gasOf,
  recordGasWithFirst,
  recordGasWithFirstIgnoreRevert,
  printGasStats,
  runSizeGasHammer,
};
