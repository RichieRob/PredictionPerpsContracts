// test/ledger.ppusdc.peertopeer.test.js

const { expect } = require("chai");
const { usdc, deployCore, mintAndDeposit } = require("./helpers/core");

describe("MarketMakerLedger – peer-to-peer ppUSDC transfers", function () {
  let fx;
  let owner, traderA, traderB;
  let usdcToken, ppUSDC, ledger;

  beforeEach(async () => {
    // fx: { owner, trader, feeRecipient, other, usdc, aUSDC, aavePool, ppUSDC, ledger }
    fx = await deployCore();

    owner     = fx.owner;
    traderA   = fx.trader;        // first user
    traderB   = fx.feeRecipient;  // second user
    usdcToken = fx.usdc;
    ppUSDC    = fx.ppUSDC;
    ledger    = fx.ledger;
  });

  // ----------------- tests -----------------

  it("ppUSDC transfer moves realFreeCollateral between traders and preserves totals", async () => {
    const amountA = usdc("500");
    const amountB = usdc("200");

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: traderA,
      amount: amountA,
    });

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: traderB,
      amount: amountB,
    });

    const aAddr = traderA.address;
    const bAddr = traderB.address;

    const beforeA      = await ledger.realFreeCollateral(aAddr);
    const beforeB      = await ledger.realFreeCollateral(bAddr);
    const beforeTotal  = await ledger.realTotalFreeCollateral();

    expect(beforeA).to.equal(amountA);
    expect(beforeB).to.equal(amountB);
    expect(beforeTotal).to.equal(amountA + amountB);

    const transferAmount = usdc("123");

    // P2P transfer via PpUSDC (which calls ppUSDCTransfer on the ledger)
    await ppUSDC.connect(traderA).transfer(bAddr, transferAmount);

    const afterA     = await ledger.realFreeCollateral(aAddr);
    const afterB     = await ledger.realFreeCollateral(bAddr);
    const afterTotal = await ledger.realTotalFreeCollateral();

    expect(afterA).to.equal(beforeA - transferAmount);
    expect(afterB).to.equal(beforeB + transferAmount);
    expect(afterTotal).to.equal(beforeTotal); // invariant: total free collateral unchanged

    // Mirror checks
    const balA = await ppUSDC.balanceOf(aAddr);
    const balB = await ppUSDC.balanceOf(bAddr);

    expect(balA).to.equal(afterA);
    expect(balB).to.equal(afterB);

    // TVL invariant still holds
    const [tvl, aUSDCBalance] = await ledger.invariant_tvl();
    expect(tvl).to.equal(aUSDCBalance);
  });

  it("reverts ppUSDC transfer when sender doesn't have enough free collateral", async () => {
    const amountA = usdc("100");

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: traderA,
      amount: amountA,
    });

    const aAddr   = traderA.address;
    const bAddr   = traderB.address;
    const balance = await ppUSDC.balanceOf(aAddr);

    expect(balance).to.equal(amountA);

    const tooMuch = amountA + 1n;

    await expect(
      ppUSDC.connect(traderA).transfer(bAddr, tooMuch)
    ).to.be.reverted;
  });

  it("ppUSDC transfer preserves solvency & redeemability in a simple setup", async () => {
    const amountA = usdc("500");
    const amountB = usdc("500");

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: traderA,
      amount: amountA,
    });

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: traderB,
      amount: amountB,
    });

    const aAddr = traderA.address;
    const bAddr = traderB.address;

    // initial solvency
    const okA0 = await ledger.invariant_checkSolvencyAllMarkets(aAddr);
    const okB0 = await ledger.invariant_checkSolvencyAllMarkets(bAddr);
    expect(okA0).to.equal(true);
    expect(okB0).to.equal(true);

    const transferAmount = usdc("250");
    await ppUSDC.connect(traderA).transfer(bAddr, transferAmount);

    const okA1 = await ledger.invariant_checkSolvencyAllMarkets(aAddr);
    const okB1 = await ledger.invariant_checkSolvencyAllMarkets(bAddr);
    expect(okA1).to.equal(true);
    expect(okB1).to.equal(true);

    // system balance invariant still holds
    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });
});
