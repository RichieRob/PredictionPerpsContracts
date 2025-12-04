// test/lmsr.large-lay.solvency.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { usdc } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");
const {
  expectCoreSystemInvariants,
  expectSolventRedeemability,
} = require("./helpers/markets");

describe("LMSR + Ledger – large Lay trades remain solvent", function () {
  let fx;

  beforeEach(async () => {
    fx = await setupLmsrLedgerFixture();
  });

  it("allows a large Lay buy without breaking DMM or trader solvency", async () => {
    const {
      usdc: usdcToken,
      ledger,
      lmsr,
      trader,
      marketId,
      yesId,
    } = fx;

    const dmmAddr = await lmsr.getAddress();
    const ledgerAddr = await ledger.getAddress();

    // --- 1) Fund and deposit a big amount of USDC for the trader ---
    const DEPOSIT = usdc("100000"); // 100k ppUSDC buffer

    await usdcToken.mint(trader.address, DEPOSIT);
    await usdcToken.connect(trader).approve(ledgerAddr, DEPOSIT);

    await ledger.connect(trader).deposit(
      trader.address,
      DEPOSIT,
      0n,   // minUSDCDeposited
      0,    // mode = allowance
      {
        value: 0n,
        deadline: 0n,
        v: 0,
        r: "0x" + "0".repeat(64),
        s: "0x" + "0".repeat(64),
      }
    );

    // Baseline invariants pre-trade
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, dmmAddr],
      marketId,
      checkRedeemabilityFor: [trader.address, dmmAddr],
    });

    const freeTraderBefore = await ledger.realFreeCollateral(trader.address);
    const freeDmmBefore = await ledger.realFreeCollateral(dmmAddr);

    // --- 2) Large Lay on YES ---
    const LAY_SIZE = usdc("1000");        // large lay size
    const MAX_USDC_IN = usdc("20000");    // generous bound

    const tx = await ledger.connect(trader).buyExactTokens(
      dmmAddr,
      marketId,
      yesId,
      false,              // isBack = false → true Lay
      LAY_SIZE,
      MAX_USDC_IN
    );
    await tx.wait(); // should NOT revert

    const freeTraderAfter = await ledger.realFreeCollateral(trader.address);
    const freeDmmAfter = await ledger.realFreeCollateral(dmmAddr);

    // Trader must have spent some ppUSDC
    expect(freeTraderAfter).to.be.lt(freeTraderBefore);

    // DMM must have received ppUSDC
    expect(freeDmmAfter).to.be.gt(freeDmmBefore);

    // --- 3) System invariants + solvency / redeemability checks ---
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, dmmAddr],
      marketId,
      checkRedeemabilityFor: [trader.address, dmmAddr],
    });

    await expectSolventRedeemability(fx, {
      account: dmmAddr,
      marketId,
    });
    await expectSolventRedeemability(fx, {
      account: trader.address,
      marketId,
    });
  });

  it("small Back then large Lay keeps DMM + trader solvent", async () => {
    const {
      usdc: usdcToken,
      ledger,
      lmsr,
      trader,
      marketId,
      yesId,
    } = fx;

    const dmmAddr = await lmsr.getAddress();
    const ledgerAddr = await ledger.getAddress();

    // --- 1) Fund and deposit a big amount of USDC for the trader ---
    const DEPOSIT = usdc("100000"); // 100k ppUSDC buffer

    await usdcToken.mint(trader.address, DEPOSIT);
    await usdcToken.connect(trader).approve(ledgerAddr, DEPOSIT);

    await ledger.connect(trader).deposit(
      trader.address,
      DEPOSIT,
      0n,   // minUSDCDeposited
      0,    // mode = allowance
      {
        value: 0n,
        deadline: 0n,
        v: 0,
        r: "0x" + "0".repeat(64),
        s: "0x" + "0".repeat(64),
      }
    );

    // Baseline invariants pre-trade
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, dmmAddr],
      marketId,
      checkRedeemabilityFor: [trader.address, dmmAddr],
    });

    const freeTraderBefore = await ledger.realFreeCollateral(trader.address);
    const freeDmmBefore = await ledger.realFreeCollateral(dmmAddr);

    // --- 2) Small BACK on YES (e.g. 10) ---
    const BACK_SIZE = usdc("10");
    const MAX_USDC_IN_BACK = usdc("1000");

    const txBack = await ledger.connect(trader).buyExactTokens(
      dmmAddr,
      marketId,
      yesId,
      true,               // isBack = true
      BACK_SIZE,          // tokensToBuy
      MAX_USDC_IN_BACK    // maxUsdcIn
    );
    await txBack.wait(); // should not revert

    // --- 3) Large Lay on YES ---
    const LAY_SIZE = usdc("1000");        // large lay size
    const MAX_USDC_IN_LAY = usdc("20000"); // generous bound

    const txLay = await ledger.connect(trader).buyExactTokens(
      dmmAddr,
      marketId,
      yesId,
      false,              // isBack = false → true Lay
      LAY_SIZE,
      MAX_USDC_IN_LAY
    );
    await txLay.wait(); // should NOT revert

    const freeTraderAfter = await ledger.realFreeCollateral(trader.address);
    const freeDmmAfter = await ledger.realFreeCollateral(dmmAddr);

    // Trader must have spent some ppUSDC vs baseline
    expect(freeTraderAfter).to.be.lt(freeTraderBefore);

    // DMM must have received ppUSDC vs baseline
    expect(freeDmmAfter).to.be.gt(freeDmmBefore);

    // --- 4) System invariants + solvency / redeemability checks ---
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, dmmAddr],
      marketId,
      checkRedeemabilityFor: [trader.address, dmmAddr],
    });

    await expectSolventRedeemability(fx, {
      account: dmmAddr,
      marketId,
    });
    await expectSolventRedeemability(fx, {
      account: trader.address,
      marketId,
    });
  });
});
