const { ethers } = require("hardhat");
const { expect } = require("chai");

// ---------- shared units / constants ----------

const usdc = (n) => ethers.parseUnits(String(n), 6);

const ZERO_HASH = "0x" + "0".repeat(64);

const EMPTY_PERMIT = {
  value: 0n,
  deadline: 0n,
  v: 0,
  r: ZERO_HASH,
  s: ZERO_HASH,
};

// ---------- core deployment ----------

async function deployCore() {
  const [owner, trader, feeRecipient, other, ...rest] =
    await ethers.getSigners();

  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdcToken = await MockUSDC.deploy();
  await usdcToken.waitForDeployment();

  const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
  const aUSDC = await MockAUSDC.deploy();
  await aUSDC.waitForDeployment();

  const MockAavePool = await ethers.getContractFactory("MockAavePool");
  const aavePool = await MockAavePool.deploy(
    await usdcToken.getAddress(),
    await aUSDC.getAddress()
  );
  await aavePool.waitForDeployment();

  const PpUSDC = await ethers.getContractFactory("PpUSDC");
  const ppUSDC = await PpUSDC.deploy();
  await ppUSDC.waitForDeployment();

  const Ledger = await ethers.getContractFactory("Ledger");
  const ledger = await Ledger.deploy(
    await usdcToken.getAddress(),
    await aUSDC.getAddress(),
    await aavePool.getAddress(),
    ethers.ZeroAddress, // permit2 unused
    await ppUSDC.getAddress()
  );
  await ledger.waitForDeployment();

  await ppUSDC.setLedger(await ledger.getAddress());

  // Deploy PositionERC20 and set it on ledger
  const PositionERC20 = await ethers.getContractFactory("PositionERC20");
  const positionImpl = await PositionERC20.deploy(await ledger.getAddress());
  await positionImpl.waitForDeployment();

  await ledger
    .connect(owner)
    .setPositionERC20Implementation(await positionImpl.getAddress());

  // 🔹 NEW: Deploy IntentContract and register it on the ledger
  const IntentContract = await ethers.getContractFactory("IntentContract");
  const intentContract = await IntentContract.deploy(
    await ledger.getAddress()
  );
  await intentContract.waitForDeployment();

  await ledger
    .connect(owner)
    .setIntentContract(await intentContract.getAddress(), true);

  return {
    owner,
    trader,
    feeRecipient,
    other,
    usdc: usdcToken,
    aUSDC,
    aavePool,
    ppUSDC,
    ledger,
    positionImpl,
    intentContract,
  };
}

// ---------- flows ----------

// just mint
async function fundTrader({ usdc, trader, amount }) {
  await usdc.mint(trader.address, amount);
}

// approve + deposit (no mint)
async function depositFromTrader({
  ledger,
  usdc,
  trader,
  to = trader.address,
  amount,
  minUSDCDeposited = 0n,
  mode = 0, // allowance
}) {
  await usdc.connect(trader).approve(await ledger.getAddress(), amount);

  await ledger.connect(trader).deposit(
    to,
    amount,
    minUSDCDeposited,
    mode,
    EMPTY_PERMIT
  );

  return amount;
}

// mint + approve + deposit in one go
async function mintAndDeposit(opts) {
  const { usdc, trader, amount } = opts;
  await fundTrader({ usdc, trader, amount });
  return depositFromTrader(opts);
}

// ---------- assertion helpers ----------

async function expectFlatLedgerForTrader({
  ledger,
  aUSDC,
  ppUSDC,
  trader,
  expected,
}) {
  const tvl = await ledger.getTotalValueLocked();
  const aBal = await aUSDC.balanceOf(await ledger.getAddress());
  const freeTrader = await ledger.realFreeCollateral(trader.address);
  const totalFree = await ledger.realTotalFreeCollateral();
  const ppBal = await ppUSDC.balanceOf(trader.address);
  const ppTotal = await ppUSDC.totalSupply();

  expect(tvl).to.equal(expected);
  expect(aBal).to.equal(expected);
  expect(freeTrader).to.equal(expected);
  expect(totalFree).to.equal(expected);
  expect(ppBal).to.equal(expected);
  expect(ppTotal).to.equal(expected);
}

module.exports = {
  usdc,
  ZERO_HASH,
  EMPTY_PERMIT,
  deployCore,
  fundTrader,
  depositFromTrader,
  mintAndDeposit,
  expectFlatLedgerForTrader,
};
