// test/ppusdc.mirror.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, EMPTY_PERMIT } = require("./helpers/core");

describe("PpUSDC mirror behaviour", function () {
  let fx;        // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let other;     // extra signer

  beforeEach(async () => {
    fx = await deployCore();
    const signers = await ethers.getSigners();
    // deployCore uses [owner, trader, feeRecipient, ...]
    other = signers[3];
  });

  async function depositFromTrader({
    to = fx.trader.address,
    amount = usdc("100"),
    minUSDCDeposited = 0n,
    mode = 0, // allowance
  } = {}) {
    const { usdc: usdcToken, ledger, trader } = fx;

    // 🔹 Mint USDC to the trader first
    await usdcToken.mint(trader.address, amount);

    // 🔹 Then approve + deposit
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), amount);

    await ledger
      .connect(trader)
      .deposit(
        to,
        amount,
        minUSDCDeposited,
        mode,
        EMPTY_PERMIT
      );
  }

  it("mirrors freeCollateral and totalFreeCollateral after deposit", async function () {
    const DEPOSIT = usdc("250");

    await depositFromTrader({ amount: DEPOSIT });

    const free      = await fx.ledger.realFreeCollateral(fx.trader.address);
    const totalFree = await fx.ledger.realTotalFreeCollateral();

    expect(free).to.equal(DEPOSIT);
    expect(totalFree).to.equal(DEPOSIT);

    // PpUSDC mirrors ledger views
    const ppBal   = await fx.ppUSDC.balanceOf(fx.trader.address);
    const ppTotal = await fx.ppUSDC.totalSupply();

    expect(ppBal).to.equal(DEPOSIT);
    expect(ppTotal).to.equal(DEPOSIT);
  });

  it("ppUSDC transfers move freeCollateral between accounts and preserve totals", async function () {
    const DEPOSIT = usdc("300");
    await depositFromTrader({ amount: DEPOSIT });

    const half = DEPOSIT / 2n;

    const { ledger, ppUSDC } = fx;
    const traderAddr = fx.trader.address;
    const otherAddr  = other.address;

    // Pre state
    expect(await ledger.realFreeCollateral(traderAddr)).to.equal(DEPOSIT);
    expect(await ledger.realFreeCollateral(otherAddr)).to.equal(0n);
    expect(await ledger.realTotalFreeCollateral()).to.equal(DEPOSIT);

    expect(await ppUSDC.balanceOf(traderAddr)).to.equal(DEPOSIT);
    expect(await ppUSDC.balanceOf(otherAddr)).to.equal(0n);

    // Transfer ppUSDC from trader -> other
    await ppUSDC.connect(fx.trader).transfer(otherAddr, half);

    // Ledger bookkeeping
    const traderFree = await ledger.realFreeCollateral(traderAddr);
    const otherFree  = await ledger.realFreeCollateral(otherAddr);
    const totalFree  = await ledger.realTotalFreeCollateral();

    expect(traderFree).to.equal(DEPOSIT - half);
    expect(otherFree).to.equal(half);
    expect(totalFree).to.equal(DEPOSIT); // invariant

    // PpUSDC mirrors state
    const traderPP = await ppUSDC.balanceOf(traderAddr);
    const otherPP  = await ppUSDC.balanceOf(otherAddr);
    const totalPP  = await ppUSDC.totalSupply();

    expect(traderPP).to.equal(DEPOSIT - half);
    expect(otherPP).to.equal(half);
    expect(totalPP).to.equal(DEPOSIT);
  });
});
