// test/lmsr.large-back-then-overcollateral-lay.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { usdc } = require("./helpers/core");
const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");
const {
  expectCoreSystemInvariants,
  expectSolventRedeemability,
} = require("./helpers/markets");

describe("LMSR + Ledger – large Back then Lay buy exceeding free ppUSDC nets out", function () {
  let fx;

  beforeEach(async () => {
    fx = await setupLmsrLedgerFixture();
  });

  it("allows Lay buy > free ppUSDC if it nets against large Back, without reverting", async () => {
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

    // --- 1) Fund and deposit USDC for the trader (enough for large Back + small buffer) ---
    const DEPOSIT = usdc("17100"); // $17,100 ppUSDC initial deposit

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

    // --- 2) Buy massive Back on YES (spend ~$17,000, leave ~$100 free ppUSDC) ---
    // Note: In LMSR, actual cost depends on sizing; use buyForppUSDC to target spend
    const BACK_USDC_IN = usdc("17000"); // Target $17,000 spend on Back
    const MIN_TOKENS_OUT_BACK = 0n;     // Accept any tokens out (for testing)

    const txBack = await ledger.connect(trader).buyForppUSDC(
      dmmAddr,
      marketId,
      yesId,
      true,               // isBack = true (Back YES)
      BACK_USDC_IN,
      MIN_TOKENS_OUT_BACK
    );
    await txBack.wait(); // Should succeed

    const freeTraderAfterBack = await ledger.realFreeCollateral(trader.address);
    const freeDmmAfterBack = await ledger.realFreeCollateral(dmmAddr);

    // Check trader has small free ppUSDC left (~$100 or less, depending on exact cost)
    expect(freeTraderAfterBack).to.be.lte(usdc("100"));
    expect(freeTraderAfterBack).to.be.gt(0n); // Some small amount left

    // Invariants after Back
    await expectCoreSystemInvariants(fx, {
      accounts: [trader.address, dmmAddr],
      marketId,
      checkRedeemabilityFor: [trader.address, dmmAddr],
    });

    // --- 3) Attempt to buy $1,000 Lay on YES (exceeds free ppUSDC, but should net) ---
    const LAY_USDC_IN = usdc("1000");   // $1,000 > free ppUSDC
    const MIN_TOKENS_OUT_LAY = 0n;      // Accept any tokens out

    const txLay = await ledger.connect(trader).buyForppUSDC(
      dmmAddr,
      marketId,
      yesId,
      false,              // isBack = false (Lay YES)
      LAY_USDC_IN,
      MIN_TOKENS_OUT_LAY
    );
    await txLay.wait(); // Should succeed due to netting, despite low free ppUSDC

    const freeTraderAfterLay = await ledger.realFreeCollateral(trader.address);
    const freeDmmAfterLay = await ledger.realFreeCollateral(dmmAddr);

    // Trader's free ppUSDC may increase or adjust due to netting/deallocation
    // But key is tx succeeds; add specific expects as needed (e.g., net position reduced)

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