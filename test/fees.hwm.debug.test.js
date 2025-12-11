// test/fees.hwm.debug.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");

const fmt = (x) => x.toString();

async function runScenario({ feeBps }) {
  const fx = await deployCore();
  const { ledger } = fx;

  const [owner, traderSigner, mmFunder, marketCreator] =
    await ethers.getSigners();

  // Just use the FlatMockMarketMaker as an identity / MM address.
  const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
  const mm = await Flat.deploy();
  await mm.waitForDeployment();
  const mmAddr = await mm.getAddress();

  // Protocol share for this test: 20%
  await ledger
    .connect(owner)
    .setNewMarketProtocolFeeShareBps(2_000); // 20%

  const hasWhitelist = false;
  const whitelistAccounts = [];

  // IMPORTANT:
  //  - dmm = address(0) → there is NO DMM for this market.
  //  - iscAmount = 0    → no synthetic line.
  await ledger
    .connect(owner)
    .createMarket(
      feeBps === 0 ? "NoFeeMarket" : "FeeMarket",
      feeBps === 0 ? "NF" : "FEE",
      ethers.ZeroAddress,     // dmm = 0 → nobody is treated as DMM
      0,                      // iscAmount = 0
      false,                  // doesResolve
      ethers.ZeroAddress,
      "0x",
      feeBps,
      marketCreator.address,
      whitelistAccounts,
      hasWhitelist
    );

  const marketId = (await ledger.getMarkets())[0];

  // Single YES position
  await ledger.connect(marketCreator).createPosition(marketId, "YES", "Y");
  const [posYes] = await ledger.getMarketPositions(marketId);

  // Fund trader
  await mintAndDeposit({
    usdc: fx.usdc,
    ledger,
    trader: traderSigner,
    amount: usdc("1000"),
  });

  // Fund MM as a normal account (not DMM)
  await mintAndDeposit({
    usdc: fx.usdc,
    ledger,
    trader: mmFunder,
    to: mmAddr,
    amount: usdc("1000"),
  });

  const accounts = [
    { label: "MM", addr: mmAddr },
    { label: "Trader", addr: traderSigner.address },
    { label: "Creator", addr: marketCreator.address },
    { label: "Owner", addr: owner.address },
  ];

  const before = {};
  console.log(`\n=== Scenario feeBps=${feeBps} BEFORE (per-account) ===`);
  console.log("Label    | realFree      | YES_back     | spent        | redeemed     | hwm");

  for (const { label, addr } of accounts) {
    const [feeState, realFree, yesBal] = await Promise.all([
      ledger.debugFeeState(addr, marketId),
      ledger.realFreeCollateral(addr),
      ledger.balanceOf(marketId, posYes, addr),
    ]);

    before[label] = { feeState, realFree, yesBal };

    console.log(
      `${label.padEnd(7)} | ` +
        `${fmt(realFree).padEnd(13)} | ` +
        `${fmt(yesBal).padEnd(11)} | ` +
        `${fmt(feeState.spent).padEnd(12)} | ` +
        `${fmt(feeState.redeemed).padEnd(11)} | ` +
        `${fmt(feeState.hwm)}`
    );
  }

  // Trader buys 200 YES from the MM
  await ledger
    .connect(traderSigner)
    .buyExactTokens(
      mmAddr,
      marketId,
      posYes,
      true,           // isBack
      usdc("200"),    // 200 YES
      usdc("1000")    // max 1000 quote
    );

  const after = {};
  console.log(`\n=== Scenario feeBps=${feeBps} AFTER (per-account) ===`);
  console.log("Label    | realFree      | YES_back     | spent        | redeemed     | hwm");

  for (const { label, addr } of accounts) {
    const [feeState, realFree, yesBal] = await Promise.all([
      ledger.debugFeeState(addr, marketId),
      ledger.realFreeCollateral(addr),
      ledger.balanceOf(marketId, posYes, addr),
    ]);

    after[label] = { feeState, realFree, yesBal };

    console.log(
      `${label.padEnd(7)} | ` +
        `${fmt(realFree).padEnd(13)} | ` +
        `${fmt(yesBal).padEnd(11)} | ` +
        `${fmt(feeState.spent).padEnd(12)} | ` +
        `${fmt(feeState.redeemed).padEnd(11)} | ` +
        `${fmt(feeState.hwm)}`
    );
  }

  return { feeBps, marketId, posYes, accounts, before, after };
}

describe("FeeLib – HWM fee comparison", () => {
  it("logs no-fee vs fee scenario and shows fee impact on MM + creator + protocol", async () => {
    const noFee   = await runScenario({ feeBps: 0 });
    const withFee = await runScenario({ feeBps: 10_000 }); // 100%

    console.log("\n================ DELTAS (noFee vs withFee) ================\n");

    const deltas = {};

    for (const { label } of noFee.accounts) {
      const bNo = noFee.before[label];
      const aNo = noFee.after[label];
      const bF  = withFee.before[label];
      const aF  = withFee.after[label];

      const deltaNo_real  = aNo.realFree - bNo.realFree;
      const deltaFee_real = aF.realFree - bF.realFree;

      const deltaNo_yes   = aNo.yesBal - bNo.yesBal;
      const deltaFee_yes  = aF.yesBal - bF.yesBal;

      deltas[label] = {
        deltaNo_real,
        deltaFee_real,
        deltaNo_yes,
        deltaFee_yes,
        bNo,
        aNo,
        bF,
        aF,
      };

      console.log(`[[ ${label} ]]`);
      console.log(
        `  noFee:  ΔrealFree = ${deltaNo_real.toString()}, ΔYES = ${deltaNo_yes.toString()}`
      );
      console.log(
        `  fee:    ΔrealFree = ${deltaFee_real.toString()}, ΔYES = ${deltaFee_yes.toString()}`
      );
      console.log(
        `  noFee:   hwm: ${bNo.feeState.hwm.toString()} → ${aNo.feeState.hwm.toString()}`
      );
      console.log(
        `  withFee: hwm: ${bF.feeState.hwm.toString()} → ${aF.feeState.hwm.toString()}`
      );
    }

    const dTrader  = deltas["Trader"];
    const dMM      = deltas["MM"];
    const dCreator = deltas["Creator"];
    const dOwner   = deltas["Owner"];

    // Trader should buy something in both scenarios
    expect(dTrader.deltaNo_yes).to.be.gt(0n);
    expect(dTrader.deltaFee_yes).to.be.gt(0n);

    // No-fee market: creator+protocol should not receive anything
    expect(dCreator.deltaNo_real).to.equal(0n);
    expect(dOwner.deltaNo_real).to.equal(0n);

    // Fee market: creator+protocol should gain something aggregated
    const creatorPlusProtocol_fee =
      dCreator.deltaFee_real + dOwner.deltaFee_real;
    expect(creatorPlusProtocol_fee).to.be.gt(0n);

    // MM should be strictly worse off in the fee market
    expect(dMM.deltaFee_real).to.be.lt(dMM.deltaNo_real);
  });
});
