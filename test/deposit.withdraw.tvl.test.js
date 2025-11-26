// test/deposit.withdraw.tvl.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger — deposits, withdrawals & TVL", function () {
  // helper for 6-decimals USDC
  const usdc = (n) => ethers.parseUnits(n, 6);

  let owner, trader, feeRecipient, other;
  let usdcToken;
  let aUSDC;
  let aavePool;
  let ppUSDC;
  let ledger;

  const EMPTY_PERMIT = {
    value: 0,
    deadline: 0,
    v: 0,
    r: ethers.ZeroHash,
    s: ethers.ZeroHash,
  };

  beforeEach(async () => {
    [owner, trader, feeRecipient, other] = await ethers.getSigners();

    // Deploy mocks
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
      ethers.ZeroAddress,             // permit2 (unused)
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

  describe("basic deposit & withdraw (no fees)", function () {
    it("deposits via allowance and updates freeCollateral, totalFreeCollateral & TVL", async function () {
      // pre-state
      expect(await ledger.getTotalValueLocked()).to.equal(0n);
      expect(await aUSDC.balanceOf(await ledger.getAddress())).to.equal(0n);
      expect(await ledger.realFreeCollateral(trader.address)).to.equal(0n);
      expect(await ledger.realTotalFreeCollateral()).to.equal(0n);

      const amount = usdc("100");
      await depositFromTrader({ amount });

      const tvl = await ledger.getTotalValueLocked();
      const aBal = await aUSDC.balanceOf(await ledger.getAddress());
      const freeTrader = await ledger.realFreeCollateral(trader.address);
      const totalFree = await ledger.realTotalFreeCollateral();

      expect(tvl).to.equal(amount);
      expect(aBal).to.equal(amount);
      expect(freeTrader).to.equal(amount);
      expect(totalFree).to.equal(amount);

      // ppUSDC mirrors freeCollateral
      const ppBal = await ppUSDC.balanceOf(trader.address);
      const ppTotal = await ppUSDC.totalSupply();

      expect(ppBal).to.equal(amount);
      expect(ppTotal).to.equal(amount);
    });

    it("withdraws back to wallet and keeps TVL == aUSDC balance", async function () {
      const amount = usdc("100");
      await depositFromTrader({ amount });

      const half = amount / 2n;

      const traderUSDCBefore = await usdcToken.balanceOf(trader.address);

      await ledger.connect(trader).withdraw(half, trader.address);

      const traderUSDCAfter = await usdcToken.balanceOf(trader.address);
      const tvl = await ledger.getTotalValueLocked();
      const aBal = await aUSDC.balanceOf(await ledger.getAddress());
      const freeTrader = await ledger.realFreeCollateral(trader.address);
      const totalFree = await ledger.realTotalFreeCollateral();
      const ppBal = await ppUSDC.balanceOf(trader.address);
      const ppTotal = await ppUSDC.totalSupply();

      expect(traderUSDCAfter - traderUSDCBefore).to.equal(half);

      expect(tvl).to.equal(half);
      expect(aBal).to.equal(half);

      expect(freeTrader).to.equal(half);
      expect(totalFree).to.equal(half);
      expect(ppBal).to.equal(half);
      expect(ppTotal).to.equal(half);
    });
  });

  describe("protocol fee on deposit", function () {
    it("skims aUSDC fee and credits only net amount to TVL & freeCollateral", async function () {
      const amount = usdc("1000");

      // set 1% fee
      const bps = 100; // 1%
      await ledger
        .connect(owner)
        .setFeeConfig(feeRecipient.address, bps, true);

      await usdcToken.connect(trader).approve(await ledger.getAddress(), amount);

      await ledger
        .connect(trader)
        .deposit(
          trader.address,
          amount,
          0n,                  // minUSDCDeposited
          0,                   // mode = allowance
          EMPTY_PERMIT,
          "0x"
        );

      const feeExpected = (amount * BigInt(bps)) / 10_000n;
      const netExpected = amount - feeExpected;

      const tvl = await ledger.getTotalValueLocked();
      const aBalLedger = await aUSDC.balanceOf(await ledger.getAddress());
      const aBalFee = await aUSDC.balanceOf(feeRecipient.address);
      const freeTrader = await ledger.realFreeCollateral(trader.address);
      const totalFree = await ledger.realTotalFreeCollateral();
      const ppBal = await ppUSDC.balanceOf(trader.address);
      const ppTotal = await ppUSDC.totalSupply();

      expect(aBalFee).to.equal(feeExpected);
      expect(aBalLedger).to.equal(netExpected);
      expect(tvl).to.equal(netExpected);
      expect(freeTrader).to.equal(netExpected);
      expect(totalFree).to.equal(netExpected);
      expect(ppBal).to.equal(netExpected);
      expect(ppTotal).to.equal(netExpected);
    });

    it("reverts if recordedAmount < minUSDCDeposited", async function () {
      const amount = usdc("100");

      // 10% fee
      const bps = 1000;
      await ledger
        .connect(owner)
        .setFeeConfig(feeRecipient.address, bps, true);

      await usdcToken.connect(trader).approve(await ledger.getAddress(), amount);

      const minUSDCDeposited = amount; // but recorded = 90 USDC

      await expect(
        ledger
          .connect(trader)
          .deposit(
            trader.address,
            amount,
            minUSDCDeposited,
            0,
            EMPTY_PERMIT,
            "0x"
          )
      ).to.be.revertedWith("Deposit below minimum");
    });
  });

  describe("withdraw constraints", function () {
    it("reverts when withdrawing more than freeCollateral", async function () {
      const amount = usdc("100");
      await depositFromTrader({ amount });

      const tooMuch = amount + usdc("1");

      await expect(
        ledger.connect(trader).withdraw(tooMuch, trader.address)
      ).to.be.revertedWith("Insufficient free collateral");
    });

    it("reverts when withdrawing to zero address", async function () {
      const amount = usdc("100");
      await depositFromTrader({ amount });

      await expect(
        ledger.connect(trader).withdraw(amount, ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid recipient");
    });
  });

  describe("TVL vs aUSDC balance invariant (mock Aave, no interest)", function () {
    it("keeps TVL equal to aUSDC balance after multiple deposits & withdrawals", async function () {
      // 1) deposit 100
      await depositFromTrader({ amount: usdc("100") });

      // 2) deposit 10 more
      await depositFromTrader({ amount: usdc("10") });

      // 3) withdraw 50
      await ledger.connect(trader).withdraw(usdc("50"), trader.address);

      const tvl = await ledger.getTotalValueLocked();
      const aBal = await aUSDC.balanceOf(await ledger.getAddress());

      expect(tvl).to.equal(aBal);
    });
  });
});
