const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PpUSDC mirror behaviour", function () {
  let owner, alice, bob;
  let usdc, aUSDC, aavePool, ppUSDC, ledger;

  beforeEach(async () => {
    [owner, alice, bob] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
    aUSDC = await MockAUSDC.deploy();
    await aUSDC.waitForDeployment();

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress()
    );
    await aavePool.waitForDeployment();

    const PpUSDC = await ethers.getContractFactory("PpUSDC");
    ppUSDC = await PpUSDC.deploy();
    await ppUSDC.waitForDeployment();

    const MarketMakerLedger = await ethers.getContractFactory("MarketMakerLedger");
    ledger = await MarketMakerLedger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress,          // permit2 unused
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());
  });

  it("mirrors freeCollateral and totalFreeCollateral after deposit", async () => {
    const DEPOSIT = ethers.parseUnits("1000", 6); // 1,000 USDC

    // mint + approve to ledger
    await usdc.mint(alice.address, DEPOSIT);
    await usdc.connect(alice).approve(await ledger.getAddress(), DEPOSIT);

    const emptyPermit = {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };

    await ledger.connect(alice).deposit(
      alice.address,
      DEPOSIT,
      0,          // minUSDCDeposited
      0,          // mode = 0 (allowance)
      emptyPermit,
      "0x"
    );

    const ts = await ppUSDC.totalSupply();
    const balAlice = await ppUSDC.balanceOf(alice.address);

    const freeAlice = await ledger.realFreeCollateral(alice.address);
    const totalFree = await ledger.realTotalFreeCollateral();
    const tvl = await ledger.getTotalValueLocked();

    expect(ts).to.equal(DEPOSIT);
    expect(balAlice).to.equal(DEPOSIT);

    expect(freeAlice).to.equal(DEPOSIT);
    expect(totalFree).to.equal(DEPOSIT);

    // all principal sits in ledger after single deposit
    expect(tvl).to.equal(DEPOSIT);
  });

  it("ppUSDC transfers move freeCollateral between accounts and preserve totals", async () => {
    const DEPOSIT = ethers.parseUnits("1000", 6);
    const TRANSFER = ethers.parseUnits("250", 6);

    // mint + approve
    await usdc.mint(alice.address, DEPOSIT);
    await usdc.connect(alice).approve(await ledger.getAddress(), DEPOSIT);

    const emptyPermit = {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };

    // deposit into ledger for alice
    await ledger.connect(alice).deposit(
      alice.address,
      DEPOSIT,
      0,
      0,
      emptyPermit,
      "0x"
    );

    // sanity pre-transfer
    const preFreeAlice = await ledger.realFreeCollateral(alice.address);
    const preFreeBob = await ledger.realFreeCollateral(bob.address);
    const preTotalFree = await ledger.realTotalFreeCollateral();
    const preTs = await ppUSDC.totalSupply();

    expect(preFreeAlice).to.equal(DEPOSIT);
    expect(preFreeBob).to.equal(0n);
    expect(preTotalFree).to.equal(DEPOSIT);
    expect(preTs).to.equal(DEPOSIT);

    // transfer ppUSDC from alice -> bob
    await ppUSDC.connect(alice).transfer(bob.address, TRANSFER);

    const postFreeAlice = await ledger.realFreeCollateral(alice.address);
    const postFreeBob = await ledger.realFreeCollateral(bob.address);
    const postTotalFree = await ledger.realTotalFreeCollateral();
    const postTs = await ppUSDC.totalSupply();

    const balAlice = await ppUSDC.balanceOf(alice.address);
    const balBob = await ppUSDC.balanceOf(bob.address);

    // balances & freeCollateral move in lockstep
    expect(balAlice).to.equal(DEPOSIT - TRANSFER);
    expect(balBob).to.equal(TRANSFER);

    expect(postFreeAlice).to.equal(DEPOSIT - TRANSFER);
    expect(postFreeBob).to.equal(TRANSFER);

    // totals unchanged
    expect(postTotalFree).to.equal(preTotalFree);
    expect(postTs).to.equal(preTs);
  });
});
