// test/deposit.withdraw.fee.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

// Simple 6-decimals USDC helper with BigInt (no ethers.parseUnits)
const usdc = (n) => {
  if (typeof n === "string") return BigInt(n) * 1_000_000n;
  return BigInt(n) * 1_000_000n;
};

// 0x00..00 for r/s in EMPTY_PERMIT (avoid ethers.ZeroHash at top level)
const ZERO_HASH = "0x" + "0".repeat(64);

describe("MarketMakerLedger — deposit with protocol fee skim", function () {
  let owner, trader, feeRecipient, other;
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
    [owner, trader, feeRecipient, other] = await ethers.getSigners();

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
      "0x0000000000000000000000000000000000000000", // permit2 (unused)
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // Fund trader with some USDC
    await usdcToken.mint(trader.address, usdc("1000"));

    // --- Enable protocol fee: 1% (100 bps) to feeRecipient ---
    await ledger
      .connect(owner)
      .setFeeConfig(feeRecipient.address, 100, true); // 100 bps = 1%
  });

  async function depositFromTrader({
    to = trader.address,
    amount = usdc("100"),
    minUSDCDeposited = 0n,
    mode = 0, // allowance
  } = {}) {
    // trader approves ledger
    await usdcToken.connect(trader).approve(await ledger.getAddress(), amount);

    const tx = await ledger
      .connect(trader)
      .deposit(
        to,
        amount,
        minUSDCDeposited,
        mode,
        EMPTY_PERMIT,
        "0x" // permit2Calldata
      );
    await tx.wait();
    return amount;
  }

  it("skims aUSDC fee and credits only net amount to TVL and freeCollateral", async function () {
    const DEPOSIT = usdc("100"); // 100 USDC
    const FEE_BPS = 100n;       // 1%
    const FEE = (DEPOSIT * FEE_BPS) / 10_000n; // 1 USDC
    const NET = DEPOSIT - FEE;  // 99 USDC

    // --- Pre-state sanity ---
    expect(await ledger.getTotalValueLocked()).to.equal(0n);
    expect(await ledger.realTotalFreeCollateral()).to.equal(0n);
    expect(await aUSDC.balanceOf(await ledger.getAddress())).to.equal(0n);
    expect(await aUSDC.balanceOf(feeRecipient.address)).to.equal(0n);

    // --- Deposit with fee enabled ---
    await depositFromTrader({ amount: DEPOSIT });

    // freeCollateral[trader] == NET
    const free = await ledger.realFreeCollateral(trader.address);
    expect(free).to.equal(NET);

    // totalFreeCollateral == NET
    const totalFree = await ledger.realTotalFreeCollateral();
    expect(totalFree).to.equal(NET);

    // totalValueLocked == NET
    const tvl = await ledger.getTotalValueLocked();
    expect(tvl).to.equal(NET);

    // aUSDC:
    //  - total minted = DEPOSIT
    //  - ledger keeps NET
    //  - feeRecipient gets FEE
    const ledgerABal = await aUSDC.balanceOf(await ledger.getAddress());
    const feeABal = await aUSDC.balanceOf(feeRecipient.address);
    const totalASupply = await aUSDC.totalSupply();

    expect(ledgerABal).to.equal(NET);
    expect(feeABal).to.equal(FEE);
    expect(totalASupply).to.equal(DEPOSIT);

    // tvlAccounting invariant: aUSDCBalance == tvl in mock (no interest)
    const [tvlView, aBalView] = await ledger.invariant_tvl();
    expect(tvlView).to.equal(NET);
    expect(aBalView).to.equal(NET);
  });
});
