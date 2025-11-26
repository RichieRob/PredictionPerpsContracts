const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – peer-to-peer ppUSDC transfers", function () {
  let owner, traderA, traderB, dmm;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId;

  // ----------------- core deploy helper (matches your other tests) -----------------

  async function deployCore() {
    [owner, traderA, traderB, dmm] = await ethers.getSigners();

    // --- deploy tokens & mocks ---
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
    ppUSDC = await PpUSDC.deploy(); // ledger wired later via setLedger
    await ppUSDC.waitForDeployment();

    const FlatMockMarketMaker = await ethers.getContractFactory("FlatMockMarketMaker");
    flatMM = await FlatMockMarketMaker.deploy();
    await flatMM.waitForDeployment();

    const MarketMakerLedger = await ethers.getContractFactory("MarketMakerLedger");
    ledger = await MarketMakerLedger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress,           // permit2 (unused in these tests)
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC → ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // allow DMM
    await ledger.allowDMM(await dmm.getAddress(), true);

    // simple 2-way market
    const tx = await ledger.createMarket(
      "Test Market",
      "TEST",
      await dmm.getAddress(),
      ethers.parseUnits("1000", 6),   // ISC amount
      false,                          // doesResolve
      ethers.ZeroAddress,             // oracle
      "0x"                            // oracleParams
    );
    const rc = await tx.wait();
    const ev = rc.logs.find(
      (l) =>
        l.fragment &&
        l.fragment.name === "MarketCreated"
    );
    marketId = ev ? ev.args.marketId : 0n; // if you don't have this event, hardcode 0

    // create one YES position so trading works if we ever need it
    await ledger.createPosition(marketId, "YES", "YES");
  }

  beforeEach(async () => {
    await deployCore();

    // Seed USDC to traders
    const mintAmount = ethers.parseUnits("1000", 6);
    await usdc.mint(await traderA.getAddress(), mintAmount);
    await usdc.mint(await traderB.getAddress(), mintAmount);

    // Approvals
    await usdc.connect(traderA).approve(await ledger.getAddress(), mintAmount);
    await usdc.connect(traderB).approve(await ledger.getAddress(), mintAmount);
  });

  // ----------------- helpers -----------------

  async function depositFor(trader, amount) {
    const EIP2612_EMPTY = {
      owner: ethers.ZeroAddress,
      spender: ethers.ZeroAddress,
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };

    await ledger
      .connect(trader)
      .deposit(
        await trader.getAddress(),
        amount,
        0,                // minUSDCDeposited
        0,                // mode = allowance
        EIP2612_EMPTY,
        "0x"              // permit2Calldata
      );
  }

  // ----------------- tests -----------------

  it("ppUSDC transfer moves realFreeCollateral between traders and preserves totals", async () => {
    const amountA = ethers.parseUnits("500", 6);
    const amountB = ethers.parseUnits("200", 6);

    await depositFor(traderA, amountA);
    await depositFor(traderB, amountB);

    const aAddr = await traderA.getAddress();
    const bAddr = await traderB.getAddress();

    const beforeA = await ledger.realFreeCollateral(aAddr);
    const beforeB = await ledger.realFreeCollateral(bAddr);
    const beforeTotal = await ledger.realTotalFreeCollateral();

    expect(beforeA).to.equal(amountA);
    expect(beforeB).to.equal(amountB);
    expect(beforeTotal).to.equal(amountA + amountB);

    const transferAmount = ethers.parseUnits("123", 6);

    // P2P transfer via PpUSDC (which calls ppUSDCTransfer on the ledger)
    await ppUSDC.connect(traderA).transfer(bAddr, transferAmount);

    const afterA = await ledger.realFreeCollateral(aAddr);
    const afterB = await ledger.realFreeCollateral(bAddr);
    const afterTotal = await ledger.realTotalFreeCollateral();

    expect(afterA).to.equal(beforeA - transferAmount);
    expect(afterB).to.equal(beforeB + transferAmount);
    expect(afterTotal).to.equal(beforeTotal); // invariant: total free collateral unchanged

    // Mirror checks
    const balA = await ppUSDC.balanceOf(aAddr);
    const balB = await ppUSDC.balanceOf(bAddr);

    expect(balA).to.equal(afterA);
    expect(balB).to.equal(afterB);

    // TVL invariant still holds
    const [tvl, aUSDCBalance] = await ledger.invariant_tvl();
    expect(tvl).to.equal(aUSDCBalance);
  });

  it("reverts ppUSDC transfer when sender doesn't have enough free collateral", async () => {
    const amountA = ethers.parseUnits("100", 6);
    await depositFor(traderA, amountA);

    const aAddr = await traderA.getAddress();
    const bAddr = await traderB.getAddress();

    const balance = await ppUSDC.balanceOf(aAddr);
    expect(balance).to.equal(amountA);

    const tooMuch = amountA + 1n;

    await expect(
      ppUSDC.connect(traderA).transfer(bAddr, tooMuch)
    ).to.be.revertedWith("Insufficient ppUSDC");
  });

  it("ppUSDC transfer preserves solvency & redeemability in a simple market", async () => {
    const amountA = ethers.parseUnits("500", 6);
    const amountB = ethers.parseUnits("500", 6);

    await depositFor(traderA, amountA);
    await depositFor(traderB, amountB);

    const aAddr = await traderA.getAddress();
    const bAddr = await traderB.getAddress();

    // initial solvency
    const okA0 = await ledger.invariant_checkSolvencyAllMarkets(aAddr);
    const okB0 = await ledger.invariant_checkSolvencyAllMarkets(bAddr);
    expect(okA0).to.equal(true);
    expect(okB0).to.equal(true);

    const transferAmount = ethers.parseUnits("250", 6);
    await ppUSDC.connect(traderA).transfer(bAddr, transferAmount);

    const okA1 = await ledger.invariant_checkSolvencyAllMarkets(aAddr);
    const okB1 = await ledger.invariant_checkSolvencyAllMarkets(bAddr);
    expect(okA1).to.equal(true);
    expect(okB1).to.equal(true);

    // system balance invariant still holds
    const [lhs, rhs] = await ledger.invariant_systemBalance();
    expect(lhs).to.equal(rhs);
  });
});
