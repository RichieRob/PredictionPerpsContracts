const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – deployment & basic deposit", () => {
  let owner, user;
  let usdc, aUSDC, aavePool, ppUSDC, ledger;

  beforeEach(async () => {
    [owner, user, feeRecipient, ...others] = await ethers.getSigners();

    // 1) Deploy mock USDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    // 2) Deploy mock aUSDC
    const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
    aUSDC = await MockAUSDC.deploy();
    await aUSDC.waitForDeployment();

    // 3) Deploy MockAavePool(underlying, aToken)
    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress()
    );
    await aavePool.waitForDeployment();

    // 4) Deploy ppUSDC (ledger-less for now)
    const PpUSDC = await ethers.getContractFactory("PpUSDC");
    ppUSDC = await PpUSDC.deploy();
    await ppUSDC.waitForDeployment();

    // 5) Deploy Ledger
    const MarketMakerLedger = await ethers.getContractFactory(
      "MarketMakerLedger"
    );
    ledger = await MarketMakerLedger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress,            // permit2 not used yet
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // 6) Wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());
  });

  it("wires mocks & ppUSDC correctly", async () => {
    // Just basic sanity checks
    expect(await ppUSDC.ledger()).to.equal(await ledger.getAddress());
    expect(await ledger.getTotalValueLocked()).to.equal(0n);
    expect(await ledger.realTotalFreeCollateral()).to.equal(0n);
  });

  it("allows a user to deposit USDC and updates TVL / ppUSDC mirror", async () => {
    const amount = ethers.parseUnits("1000", 6); // 1,000 USDC

    // 1) Mint USDC to user
    await usdc.mint(user.address, amount);

    // 2) User approves ledger to pull USDC
    await usdc.connect(user).approve(await ledger.getAddress(), amount);

    // 3) Call ledger.deposit with mode = 0 (allowance)
    const emptyPermit = {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };
    const emptyBytes = "0x";

    await expect(
      ledger
        .connect(user)
        .deposit(
          user.address,      // to: ledger account to credit
          amount,            // amount
          0,                 // minUSDCDeposited
          0,                 // mode = 0 (allowance)
          emptyPermit,       // unused when mode=0
          emptyBytes         // unused when mode=0
        )
    )
      .to.emit(ledger, "Deposited");

    // 4) Check ledger accounting
    const free = await ledger.realFreeCollateral(user.address);
    const totalFree = await ledger.realTotalFreeCollateral();
    const tvl = await ledger.getTotalValueLocked();
    const aBal = await aUSDC.balanceOf(await ledger.getAddress());
    const poolUSDC = await usdc.balanceOf(await aavePool.getAddress());

    expect(free).to.equal(amount);
    expect(totalFree).to.equal(amount);
    expect(tvl).to.equal(amount);

    // Our mock mints aUSDC 1:1 to the ledger on supply
    expect(aBal).to.equal(amount);

    // USDC has moved from user to Aave pool
    expect(poolUSDC).to.equal(amount);
    expect(await usdc.balanceOf(user.address)).to.equal(0n);

    // 5) ppUSDC mirror: same freeCollateral & ERC20 balance
    expect(await ppUSDC.totalSupply()).to.equal(amount);
    expect(await ppUSDC.balanceOf(user.address)).to.equal(amount);
  });

  it("allows a user to withdraw back to wallet", async () => {
    const amount = ethers.parseUnits("500", 6); // 500 USDC

    // Mint & deposit 500
    await usdc.mint(user.address, amount);
    await usdc.connect(user).approve(await ledger.getAddress(), amount);

    const emptyPermit = {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };
    const emptyBytes = "0x";

    await ledger
      .connect(user)
      .deposit(
        user.address,
        amount,
        0,
        0,
        emptyPermit,
        emptyBytes
      );

    // Now withdraw half
    const withdrawAmt = ethers.parseUnits("200", 6);

    await expect(
      ledger.connect(user).withdraw(withdrawAmt, user.address)
    )
      .to.emit(ledger, "Withdrawn");

    const free = await ledger.realFreeCollateral(user.address);
    const totalFree = await ledger.realTotalFreeCollateral();
    const tvl = await ledger.getTotalValueLocked();
    const userUSDC = await usdc.balanceOf(user.address);

    // 500 deposited - 200 withdrawn = 300 remaining
    expect(free).to.equal(amount - withdrawAmt);
    expect(totalFree).to.equal(amount - withdrawAmt);
    expect(tvl).to.equal(amount - withdrawAmt);
    expect(userUSDC).to.equal(withdrawAmt);

    // ppUSDC mirror
    expect(await ppUSDC.totalSupply()).to.equal(amount - withdrawAmt);
    expect(await ppUSDC.balanceOf(user.address)).to.equal(amount - withdrawAmt);
  });
});
