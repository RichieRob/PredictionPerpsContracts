// test/ledger.trade.gasprofile.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");

const U = (n) => usdc(String(n));

// ──────────────────────────────────────
// basic gas helpers
// ──────────────────────────────────────

async function gasOf(txPromise) {
  const tx = await txPromise;
  const receipt = await tx.wait();
  return Number(receipt.gasUsed);
}

function printTable(title, rows) {
  console.log(`\n=== ${title} ===`);
  if (!rows.length) {
    console.log("(no data)");
    return;
  }
  const headers = Object.keys(rows[0]);
  const widths = {};
  for (const h of headers) {
    widths[h] = h.length;
  }
  for (const row of rows) {
    for (const h of headers) {
      widths[h] = Math.max(widths[h], String(row[h]).length);
    }
  }

  const headerLine = headers
    .map((h) => String(h).padEnd(widths[h]))
    .join("  |  ");
  console.log(headerLine);
  console.log(
    headers
      .map((h) => "-".repeat(widths[h]))
      .join("--+--")
  );

  for (const row of rows) {
    console.log(
      headers
        .map((h) => String(row[h]).padEnd(widths[h]))
        .join("  |  ")
    );
  }
}

// ──────────────────────────────────────
// helper: create an extra LMSR market
// reusing the same ledger + lmsr
// ──────────────────────────────────────

async function createLmsrMarket(fx, opts = {}) {
  const { owner, ledger, lmsr } = fx;

  const {
    name = "Extra Market",
    ticker = "EXTRA",
    nPositions = 2,
  } = opts;

  const lmsrAddr = await lmsr.getAddress();

  // 1) create the market with an ISC line
  const iscAmount = U(100_000);
  await ledger
    .connect(owner)
    .createMarket(
      name,
      ticker,
      lmsrAddr,
      iscAmount,
      false,
      ethers.ZeroAddress,
      "0x",
      0,                 // feeBps
      owner.address,     // marketCreator
      [],                // feeWhitelistAccounts
      false              // hasWhitelist
    );

  const markets = await ledger.getMarkets();
  const marketId = markets[markets.length - 1];

  // 2) create positions
  const posIds = [];
  for (let i = 0; i < nPositions; i++) {
    const label = `P${i}`;
    await ledger.connect(owner).createPosition(marketId, label, label);
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
// main profiling test
// ──────────────────────────────────────

describe("MarketMakerLedger – trade gas profiling", function () {
  it("profiles first vs subsequent gas across users/markets/positions", async function () {
    const fx = await setupLmsrLedgerFixture();
    const {
      owner,
      trader: trader0,
      ledger,
      lmsr,
      usdc: usdcToken,
      marketId: m1,
      yesId: m1_yes,
    } = fx;

    const dmmAddr = await lmsr.getAddress();

    // extra traders
    const signers = await ethers.getSigners();
    const trader1 = signers[3];
    const trader2 = signers[4];
    const traders = [trader0, trader1, trader2];

    // extra markets
    const m2 = await createLmsrMarket(fx, {
      name: "Market 2",
      ticker: "M2",
      nPositions: 2,
    });
    const m3 = await createLmsrMarket(fx, {
      name: "Market 3",
      ticker: "M3",
      nPositions: 3, // multi-outcome for position profiling
    });

    const m2_id = m2.marketId;
    const m2_pos0 = m2.posIds[0];

    const m3_id = m3.marketId;
    const [m3_pos0, m3_pos1, m3_pos2] = m3.posIds;

    // seed each trader with ppUSDC (deposit once)
    for (const t of traders) {
      await mintAndDeposit({
        usdc: usdcToken,
        ledger,
        trader: t,
        amount: U(10_000),
      });
    }

    // ──────────────────────────────────────
    // Scenario A: same user, same market
    // first vs subsequent buys
    // ──────────────────────────────────────

    const A_first = [];
    const A_rest = [];
    const targetTrader = trader0;

    for (let i = 0; i < 5; i++) {
      const g = await gasOf(
        ledger.connect(targetTrader).buyExactTokens(
          dmmAddr,
          m1,
          m1_yes,
          true,
          U(50),
          U(1_000)
        )
      );
      if (i === 0) A_first.push(g);
      else A_rest.push(g);
    }

    // ──────────────────────────────────────
    // Scenario B: first trade per user
    // (same market m1, same position)
    // ──────────────────────────────────────

    const B_rows = [];
    for (let i = 0; i < traders.length; i++) {
      const t = traders[i];
      const g = await gasOf(
        ledger.connect(t).buyExactTokens(
          dmmAddr,
          m1,
          m1_yes,
          true,
          U(50),
          U(1_000)
        )
      );
      B_rows.push({
        userIndex: i,
        userAddress: t.address,
        gas_firstTradeOn_m1: g,
      });
    }

    // ──────────────────────────────────────
    // Scenario C: first trade per market
    // (same user, different markets)
    // ──────────────────────────────────────

    const C_rows = [];

    const g_m1 = await gasOf(
      ledger.connect(targetTrader).buyExactTokens(
        dmmAddr,
        m1,
        m1_yes,
        true,
        U(50),
        U(1_000)
      )
    );
    C_rows.push({
      market: "m1_yes",
      marketId: String(m1),
      gas_firstTrade: g_m1,
    });

    const g_m2 = await gasOf(
      ledger.connect(targetTrader).buyExactTokens(
        dmmAddr,
        m2_id,
        m2_pos0,
        true,
        U(50),
        U(1_000)
      )
    );
    C_rows.push({
      market: "m2_pos0",
      marketId: String(m2_id),
      gas_firstTrade: g_m2,
    });

    const g_m3 = await gasOf(
      ledger.connect(targetTrader).buyExactTokens(
        dmmAddr,
        m3_id,
        m3_pos0,
        true,
        U(50),
        U(1_000)
      )
    );
    C_rows.push({
      market: "m3_pos0",
      marketId: String(m3_id),
      gas_firstTrade: g_m3,
    });

    // ──────────────────────────────────────
    // Scenario D: first trade per position
    // within the multi-outcome market m3
    // ──────────────────────────────────────

    const D_rows = [];

    const g_p0 = await gasOf(
      ledger.connect(targetTrader).buyExactTokens(
        dmmAddr,
        m3_id,
        m3_pos0,
        true,
        U(50),
        U(1_000)
      )
    );
    const g_p1 = await gasOf(
      ledger.connect(targetTrader).buyExactTokens(
        dmmAddr,
        m3_id,
        m3_pos1,
        true,
        U(50),
        U(1_000)
      )
    );
    const g_p2 = await gasOf(
      ledger.connect(targetTrader).buyExactTokens(
        dmmAddr,
        m3_id,
        m3_pos2,
        true,
        U(50),
        U(1_000)
      )
    );

    D_rows.push(
      { position: "P0", posId: String(m3_pos0), gas_firstTrade: g_p0 },
      { position: "P1", posId: String(m3_pos1), gas_firstTrade: g_p1 },
      { position: "P2", posId: String(m3_pos2), gas_firstTrade: g_p2 }
    );

    // ──────────────────────────────────────
    // Print tables
    // ──────────────────────────────────────

    printTable("Scenario A – same user, same market (m1_yes): first vs subsequent", [
      {
        label: "first",
        count: A_first.length,
        min: Math.min(...A_first),
        max: Math.max(...A_first),
        avg: Math.round(
          A_first.reduce((a, b) => a + b, 0) / A_first.length
        ),
      },
      {
        label: "subsequent",
        count: A_rest.length,
        min: Math.min(...A_rest),
        max: Math.max(...A_rest),
        avg: Math.round(
          A_rest.reduce((a, b) => a + b, 0) / A_rest.length
        ),
      },
    ]);

    printTable("Scenario B – first trade per user on same market (m1_yes)", B_rows);

    printTable("Scenario C – first trade per market for same user", C_rows);

    printTable(
      "Scenario D – first trade per position in multi-outcome market m3",
      D_rows
    );

    // sanity: system still sane-ish
    const finalFree = await ledger.realFreeCollateral(targetTrader.address);
    expect(finalFree).to.be.gte(0n);
  });
});
