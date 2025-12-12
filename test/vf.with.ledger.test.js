// test/vf.with.ledger.test.js
const { expect } = require("chai");
const { usdc } = require("./helpers/core");
const {
  setupVfLedgerFixture,
  traderDepositsAndBuysVf,
} = require("./helpers/vf.ledger");

const WAD = 10n ** 18n;

function wadToFloat(x) {
  return Number(x) / 1e18;
}

function absDiff(a, b) {
  return a > b ? (a - b) : (b - a);
}

// For fee model: gross = base + ceil(base * feeBps / 10_000)
// Recover (base, fee) exactly (or within 1-2 units) from gross.
function splitGrossIntoBaseAndFee(gross, feeBps) {
  const BPS = 10_000n;
  const FEE = BigInt(feeBps);

  // initial guess (floor)
  let base = (gross * BPS) / (BPS + FEE);

  const feeFor = (b) => (b * FEE + (BPS - 1n)) / BPS; // ceil
  const grossFor = (b) => b + feeFor(b);

  // adjust up/down to hit exact gross (usually moves by <= 1)
  while (grossFor(base) < gross) base += 1n;
  while (grossFor(base) > gross) base -= 1n;

  const fee = gross - base;
  return { base, fee };
}

describe("VFMarketMaker + Ledger integration", () => {
  it("starts ~uniform, lay=1-back, sum(back)=1", async () => {
    const fx = await setupVfLedgerFixture({ outcomes: ["A", "B", "C"] });
    const { vf, marketId, positionIds } = fx;

    let sum = 0n;
    for (const pid of positionIds) {
      const p = await vf.getBackPriceWad(marketId, pid);
      const lay = await vf.getLayPriceWad(marketId, pid);

      console.log(
        `initial price ${pid}: back=${wadToFloat(p)}, lay=${wadToFloat(lay)}`
      );

      expect(p + lay).to.equal(WAD);
      sum += p;
    }

    expect(sum).to.be.closeTo(WAD, WAD / 1_000_000n);
  });

  it("back buy moves that outcome price up; lay buy moves it down", async () => {
    const fx = await setupVfLedgerFixture({ outcomes: ["A", "B", "C"] });
    const { vf, marketId, pos0 } = fx;

    const p0_before = await vf.getBackPriceWad(marketId, pos0);

    await traderDepositsAndBuysVf(fx, {
      depositAmount: usdc("1000"),
      positionId: pos0,
      isBack: true,
      tokensToBuy: usdc("10"),
      maxUsdcIn: usdc("500"),
    });

    const p0_afterBack = await vf.getBackPriceWad(marketId, pos0);

    await traderDepositsAndBuysVf(fx, {
      depositAmount: 0n,
      positionId: pos0,
      isBack: false,
      tokensToBuy: usdc("5"),
      maxUsdcIn: usdc("500"),
    });

    const p0_afterLay = await vf.getBackPriceWad(marketId, pos0);

    console.log(
      "price path:",
      wadToFloat(p0_before),
      "→ back →",
      wadToFloat(p0_afterBack),
      "→ lay →",
      wadToFloat(p0_afterLay)
    );

    expect(p0_afterBack).to.be.gt(p0_before);
    expect(p0_afterLay).to.be.lt(p0_afterBack);
  });

  it("batched prices: getAllBackPricesWad + getAllLayPricesWad consistent", async () => {
    const fx = await setupVfLedgerFixture({ outcomes: ["A", "B", "C"] });
    const { vf, marketId } = fx;

    const [idsBack, backs] = await vf.getAllBackPricesWad(marketId);
    const [idsLay, lays] = await vf.getAllLayPricesWad(marketId);

    expect(idsBack.length).to.equal(idsLay.length);

    let sum = 0n;

    for (let i = 0; i < idsBack.length; i++) {
      expect(idsBack[i]).to.equal(idsLay[i]);
      expect(backs[i] + lays[i]).to.equal(WAD);
      sum += backs[i];

      console.log(
        `batched ${idsBack[i]}: back=${wadToFloat(
          backs[i]
        )}, lay=${wadToFloat(lays[i])}`
      );
    }

    expect(sum).to.be.closeTo(WAD, WAD / 1_000_000n);
  });

  it("multiple back buys are monotonic in price", async () => {
    const fx = await setupVfLedgerFixture({ outcomes: ["A", "B", "C"] });
    const { vf, marketId, pos0 } = fx;

    let last = await vf.getBackPriceWad(marketId, pos0);
    console.log("start price:", wadToFloat(last));

    await traderDepositsAndBuysVf(fx, {
      depositAmount: usdc("2000"),
      positionId: pos0,
      isBack: true,
      tokensToBuy: usdc("5"),
      maxUsdcIn: usdc("500"),
    });

    for (let i = 0; i < 5; i++) {
      await traderDepositsAndBuysVf(fx, {
        depositAmount: 0n,
        positionId: pos0,
        isBack: true,
        tokensToBuy: usdc("2"),
        maxUsdcIn: usdc("500"),
      });

      const p = await vf.getBackPriceWad(marketId, pos0);
      console.log(`after buy ${i + 1}:`, wadToFloat(p));

      expect(p).to.be.gt(last);
      last = p;
    }
  });

it("liquidation model: buy BACK(t) then buy LAY(t) costs ~2x fee and roughly restores price", async () => {
  const fx = await setupVfLedgerFixture({ outcomes: ["A", "B", "C"] });
  const { ledger, vf, marketId, trader, pos0 } = fx;

  const DEPOSIT = usdc("50000");
  const T = usdc("2000");
  const MAX = usdc("50000");

  // Deposit only
  await traderDepositsAndBuysVf(fx, {
    depositAmount: DEPOSIT,
    positionId: pos0,
    isBack: true,
    tokensToBuy: 0n,
    maxUsdcIn: 0n,
  });

  const p0 = await vf.getBackPriceWad(marketId, pos0);
  const free0 = await ledger.realFreeCollateral(trader.address);

  // ---- BUY BACK ----
  await ledger.connect(trader).buyExactTokens(
    await vf.getAddress(),
    marketId,
    pos0,
    true,
    T,
    MAX
  );

  const p1 = await vf.getBackPriceWad(marketId, pos0);
  const free1 = await ledger.realFreeCollateral(trader.address);

  // ---- BUY LAY (UNWIND) ----
  await ledger.connect(trader).buyExactTokens(
    await vf.getAddress(),
    marketId,
    pos0,
    false,
    T,
    MAX
  );

  const p2 = await vf.getBackPriceWad(marketId, pos0);
  const free2 = await ledger.realFreeCollateral(trader.address);

  // ---- COSTS ----
  const deltaBack = free1 - free0; // signed
const deltaLay  = free2 - free1; // signed
const deltaNet  = free2 - free0; // signed

const spentBack = free0 - free1; // expects positive
const spentLay  = free1 - free2; // can be negative (refund)
const netCost   = free0 - free2; // expects positive

console.log("collateral deltas (signed):");
console.log("  Δback:", deltaBack.toString());
console.log("  Δlay :", deltaLay.toString());
console.log("  Δnet :", deltaNet.toString());

console.log("collateral view (spend/refund):");
console.log("  spentBack :", spentBack.toString());
if (spentLay >= 0n) console.log("  spentLay  :", spentLay.toString());
else console.log("  refundLay :", (free2 - free1).toString());
console.log("  netCost   :", netCost.toString());


  // ---- PRICE ROUND-TRIP ----
  expect(p1).to.be.gt(p0);
  expect(p2).to.be.lt(p1);

  const drift = p0 > p2 ? (p0 - p2) : (p2 - p0);
  expect(drift).to.be.lt(5n * 10n ** 15n); // <0.5%

  // ---- FEE ASSERTION ----
const FEE_BPS = 100n;
const BPS = 10_000n;

const expected = (T * FEE_BPS + (BPS - 1n)) / BPS; // ceil(1% of T)
expect(netCost).to.be.closeTo(expected, 10n); // 10 micro-USDC dust

});

  it("large buys cause visible slippage (sanity)", async () => {
    const fx = await setupVfLedgerFixture({ outcomes: ["A", "B", "C"] });
    const { vf, marketId, trader, ledger, pos0 } = fx;

    const DEPOSIT = usdc("200000");
    await traderDepositsAndBuysVf(fx, {
      depositAmount: DEPOSIT,
      positionId: pos0,
      isBack: true,
      tokensToBuy: 0n, // deposit only
      maxUsdcIn: 0n,
    });

    const free0 = await ledger.realFreeCollateral(trader.address);
    const p0 = await vf.getBackPriceWad(marketId, pos0);
    console.log("start:", "p=", Number(p0) / 1e18, "free=", free0.toString());

    const steps = [usdc("1000"), usdc("5000"), usdc("20000")];
    for (const t of steps) {
      const beforeFree = await ledger.realFreeCollateral(trader.address);
      const beforeP = await vf.getBackPriceWad(marketId, pos0);

      await traderDepositsAndBuysVf(fx, {
        depositAmount: 0n,
        positionId: pos0,
        isBack: true,
        tokensToBuy: t,
        maxUsdcIn: DEPOSIT,
      });

      const afterFree = await ledger.realFreeCollateral(trader.address);
      const afterP = await vf.getBackPriceWad(marketId, pos0);

      const spent = beforeFree - afterFree;

      console.log(
        `buy t=${t.toString()} | price ${
          Number(beforeP) / 1e18
        } → ${Number(afterP) / 1e18} | spent=${spent.toString()}`
      );

      expect(afterP).to.be.gt(beforeP);
      expect(afterP).to.be.lt(10n ** 18n);
    }
  });

  it("sanity: average cost per token increases with trade size (convexity)", async () => {
    const outcomes = ["A", "B", "C"];
    const DEPOSIT = usdc("200000");
    const MAX = usdc("200000");

    const tSmall = usdc("1000");
    const tBig = usdc("20000");

    async function runOnce(tokensToBuy) {
      const fx = await setupVfLedgerFixture({ outcomes });
      const { ledger, vf, trader, marketId, pos0 } = fx;

      await traderDepositsAndBuysVf(fx, {
        depositAmount: DEPOSIT,
        positionId: pos0,
        isBack: true,
        tokensToBuy: 0n,
        maxUsdcIn: 0n,
      });

      const freeBefore = await ledger.realFreeCollateral(trader.address);
      const pBefore = await vf.getBackPriceWad(marketId, pos0);

      await traderDepositsAndBuysVf(fx, {
        depositAmount: 0n,
        positionId: pos0,
        isBack: true,
        tokensToBuy,
        maxUsdcIn: MAX,
      });

      const freeAfter = await ledger.realFreeCollateral(trader.address);
      const pAfter = await vf.getBackPriceWad(marketId, pos0);

      const spent = freeBefore - freeAfter; // 1e-6 USDC
      const avg = (spent * WAD) / tokensToBuy; // WAD avg “price”

      console.log(
        `size=${tokensToBuy.toString()} | p: ${wadToFloat(
          pBefore
        )} → ${wadToFloat(pAfter)} | spent=${spent.toString()} | avg=${wadToFloat(
          avg
        )}`
      );

      return { spent, avg };
    }

    const small = await runOnce(tSmall);
    const big = await runOnce(tBig);

    expect(big.avg).to.be.gt(small.avg);
    expect(big.spent).to.be.gt(small.spent);
  });
});
