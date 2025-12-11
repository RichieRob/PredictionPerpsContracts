// test/fees.hwm.steps.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");

// Reusable setup for a single-position fee market
async function setupFeeMarket({ feeBps }) {
  const fx = await deployCore();
  const { ledger } = fx;
  const [owner, trader, mmFunder, marketCreator] = await ethers.getSigners();

  // Flat MM
  const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
  const mm = await Flat.deploy();
  await mm.waitForDeployment();
  const mmAddr = await mm.getAddress();

  // Protocol share = 20% of fee
  await ledger.connect(owner).setNewMarketProtocolFeeShareBps(2_000); // 20%

  const hasWhitelist = false;
  const whitelistAccounts = [];

  await ledger.connect(owner).createMarket(
    "FeeMarketSteps",
    "FMS",
    mmAddr,
    usdc("0"),              // ⚠ no ISC → MM is NOT auto-whitelisted
    false,
    ethers.ZeroAddress,
    "0x",
    feeBps,
    marketCreator.address,
    whitelistAccounts,
    hasWhitelist
  );

  const marketId = (await ledger.getMarkets())[0];

  await ledger.connect(marketCreator).createPosition(marketId, "YES", "Y");
  const [posYes] = await ledger.getMarketPositions(marketId);

  await ledger.connect(owner).allowDMM(mmAddr, true);

  await mintAndDeposit({ usdc: fx.usdc, ledger, trader, amount: usdc("1000") });
  await mintAndDeposit({
    usdc: fx.usdc,
    ledger,
    trader: mmFunder,
    to: mmAddr,
    amount: usdc("1000"),
  });

  return { fx, ledger, owner, trader, mmFunder, marketCreator, mmAddr, marketId, posYes };
}

describe("FeeLib – HWM stepwise behaviour", () => {
  it("only charges fees on *increments* in net allocation", async () => {
    const feeBps = 5_000n; // 50% for loud numbers
    const {
      ledger,
      trader,
      mmAddr,
      marketId,
      posYes,
      marketCreator,
      owner,
    } = await setupFeeMarket({ feeBps: Number(feeBps) });

    const readAccount = async (account) => {
      const feeState = await ledger.debugFeeState(account, marketId);
      return {
        feeState,
        realFree: await ledger.realFreeCollateral(account),
      };
    };

    const before = {
      mm: await readAccount(mmAddr),
      creator: await readAccount(marketCreator.address),
      owner: await readAccount(owner.address),
    };

    // ----------------------------------------------------
    // Trade 1: HWM 0 → 100
    // ----------------------------------------------------
    await ledger
      .connect(trader)
      .buyExactTokens(
        mmAddr,
        marketId,
        posYes,
        true,
        usdc("100"),
        usdc("1000")
      );

    const after1 = {
      mm: await readAccount(mmAddr),
      creator: await readAccount(marketCreator.address),
      owner: await readAccount(owner.address),
    };

    const hwmDelta1 =
      after1.mm.feeState.hwm - before.mm.feeState.hwm; // BigInt
    expect(hwmDelta1).to.equal(usdc("100"));

    // total fee = ΔHWM * feeBps / 1e4
    const feeTotal1 = (hwmDelta1 * feeBps) / 10_000n;
    // protocolShareBps was set to 2000 (20%), so creator gets 80%
    const creatorShare1 = (feeTotal1 * 8n) / 10n;
    const protocolShare1 = feeTotal1 - creatorShare1;

    expect(after1.creator.realFree - before.creator.realFree).to.equal(
      creatorShare1
    );
    expect(after1.owner.realFree - before.owner.realFree).to.equal(
      protocolShare1
    );

    // ----------------------------------------------------
    // Trade 2: HWM 100 → 150 (fees only on +50)
    // ----------------------------------------------------
    await ledger
      .connect(trader)
      .buyExactTokens(
        mmAddr,
        marketId,
        posYes,
        true,
        usdc("50"),
        usdc("1000")
      );

    const after2 = {
      mm: await readAccount(mmAddr),
      creator: await readAccount(marketCreator.address),
      owner: await readAccount(owner.address),
    };

    const hwmDelta2 =
      after2.mm.feeState.hwm - after1.mm.feeState.hwm; // BigInt
    expect(hwmDelta2).to.equal(usdc("50"));

    const feeTotal2 = (hwmDelta2 * feeBps) / 10_000n;
    const creatorShare2 = (feeTotal2 * 8n) / 10n;
    const protocolShare2 = feeTotal2 - creatorShare2;

    expect(after2.creator.realFree - after1.creator.realFree).to.equal(
      creatorShare2
    );
    expect(after2.owner.realFree - after1.owner.realFree).to.equal(
      protocolShare2
    );

    // Sanity: creator+protocol total gain = fee(HWM=150)
    const totalHwm = after2.mm.feeState.hwm;
    expect(totalHwm).to.equal(usdc("150"));
  });
});
