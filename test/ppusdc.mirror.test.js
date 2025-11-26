// test/ppusdc.mirror.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

// Simple 6-decimals USDC helper with BigInt
const usdc = (n) => {
  if (typeof n === "string") return BigInt(n) * 1_000_000n;
  return BigInt(n) * 1_000_000n;
};

const ZERO_HASH = "0x" + "0".repeat(64);

describe("PpUSDC mirror behaviour", function () {
  let owner, trader, other;
  let usdcToken;
  let aUSDC;
  let aavePool;
  let ppUSDC;
  let ledger;

  const EMPTY_PERMIT = {
    value: 0n,
    deadline: 0n,
    v: 0,
    r: ZERO_HASH,
    s: ZERO_HASH,
  };

  beforeEach(async () => {
    [owner, trader, other] = await ethers.getSigners();

    // --- Deploy mocks ---
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdcToken = await MockUSDC.deploy();
    await usdcToken.waitForDeployment();

    const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
    aUSDC = await MockAUSDC.deploy();
    await aUSDC.waitForDeployment();

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(
      await usdcToken.getAddress(),
      await aUSDC.getAddress()
    );
    await aavePool.waitForDeployment();

    const PpUSDC = await ethers.getContractFactory("PpUSDC");
    ppUSDC = await PpUSDC.deploy();
    await ppUSDC.waitForDeployment();

    const MarketMakerLedger = await ethers.getContractFactory("MarketMakerLedger");
    ledger = await MarketMakerLedger.deploy(
      await usdcToken.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      "0x0000000000000000000000000000000000000000", // permit2 unused
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // Fund trader with some USDC
    await usdcToken.mint(trader.address, usdc("1000"));
  });

  async function depositFromTrader({
    to = trader.address,
    amount = usdc("100"),
    minUSDCDeposited = 0n,
    mode = 0, // allowance
  } = {}) {
    await usdcToken.connect(trader).approve(await ledger.getAddress(), amount);

    await ledger
      .connect(trader)
      .deposit(
        to,
        amount,
        minUSDCDeposited,
        mode,
        EMPTY_PERMIT,
        "0x" // permit2Calldata
      );
  }

  it("mirrors freeCollateral and totalFreeCollateral after deposit", async function () {
    const DEPOSIT = usdc("250");

    await depositFromTrader({ amount: DEPOSIT });

    const free = await ledger.realFreeCollateral(trader.address);
    const totalFree = await ledger.realTotalFreeCollateral();

    expect(free).to.equal(DEPOSIT);
    expect(totalFree).to.equal(DEPOSIT);

    // PpUSDC mirrors ledger views
    const ppBal = await ppUSDC.balanceOf(trader.address);
    const ppTotal = await ppUSDC.totalSupply();

    expect(ppBal).to.equal(DEPOSIT);
    expect(ppTotal).to.equal(DEPOSIT);
  });

  it("ppUSDC transfers move freeCollateral between accounts and preserve totals", async function () {
    const DEPOSIT = usdc("300");
    await depositFromTrader({ amount: DEPOSIT });

    const half = DEPOSIT / 2n;

    // Pre state
    expect(await ledger.realFreeCollateral(trader.address)).to.equal(DEPOSIT);
    expect(await ledger.realFreeCollateral(other.address)).to.equal(0n);
    expect(await ledger.realTotalFreeCollateral()).to.equal(DEPOSIT);

    expect(await ppUSDC.balanceOf(trader.address)).to.equal(DEPOSIT);
    expect(await ppUSDC.balanceOf(other.address)).to.equal(0n);

    // Transfer ppUSDC from trader -> other
    await ppUSDC.connect(trader).transfer(other.address, half);

    // Ledger bookkeeping
    const traderFree = await ledger.realFreeCollateral(trader.address);
    const otherFree = await ledger.realFreeCollateral(other.address);
    const totalFree = await ledger.realTotalFreeCollateral();

    expect(traderFree).to.equal(DEPOSIT - half);
    expect(otherFree).to.equal(half);
    expect(totalFree).to.equal(DEPOSIT); // invariant

    // PpUSDC mirrors state
    const traderPP = await ppUSDC.balanceOf(trader.address);
    const otherPP = await ppUSDC.balanceOf(other.address);
    const totalPP = await ppUSDC.totalSupply();

    expect(traderPP).to.equal(DEPOSIT - half);
    expect(otherPP).to.equal(half);
    expect(totalPP).to.equal(DEPOSIT);
  });
});
