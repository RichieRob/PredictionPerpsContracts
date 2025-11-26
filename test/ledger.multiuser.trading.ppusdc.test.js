const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – multi-user trading & ppUSDC mirrors", function () {
  let owner, alice, bob;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, posA, posB, tokenA, tokenB;

  async function deployCore() {
    [owner, alice, bob] = await ethers.getSigners();

    // --- tokens & mocks ---
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

    const FlatMockMarketMaker = await ethers.getContractFactory(
      "FlatMockMarketMaker"
    );
    flatMM = await FlatMockMarketMaker.deploy();
    await flatMM.waitForDeployment();

    const MarketMakerLedger = await ethers.getContractFactory(
      "MarketMakerLedger"
    );
    ledger = await MarketMakerLedger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress,
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    await ppUSDC.setLedger(await ledger.getAddress());
    await ledger.allowDMM(await flatMM.getAddress(), true);

    // --- market ---
    const ISC = ethers.parseUnits("100000", 6);
    await ledger.createMarket(
      "Multi-User Test Market",
      "MUTI",
      await flatMM.getAddress(),
      ISC,
      false,
      ethers.ZeroAddress,
      "0x"
    );
    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // --- create 2 positions (A/B) via createPosition so ERC20s are fully registered ---
    const [posA_, tokenA_] = await ledger.createPosition.staticCall(
      marketId,
      "Team A",
      "A"
    );
    await ledger.createPosition(marketId, "Team A", "A");

    const [posB_, tokenB_] = await ledger.createPosition.staticCall(
      marketId,
      "Team B",
      "B"
    );
    await ledger.createPosition(marketId, "Team B", "B");

    posA = posA_;
    tokenA = tokenA_;
    posB = posB_;
    tokenB = tokenB_;
  }

  function emptyPermit() {
    return {
      value: 0,
      deadline: 0,
      v: 0,
      r: ethers.ZeroHash,
      s: ethers.ZeroHash,
    };
  }

  async function depositFor(account, amount) {
    await usdc.mint(account.address, amount);
    await usdc.connect(account).approve(await ledger.getAddress(), amount);

    await ledger.connect(account).deposit(
      account.address,
      amount,
      0,
      0,
      emptyPermit(),
      "0x"
    );
  }

  beforeEach(async () => {
    await deployCore();
  });

  it("keeps ppUSDC + ERC20 mirrors correct after multi-user buys & sells", async () => {
    const DEPOSIT_ALICE = ethers.parseUnits("10000", 6);
    const DEPOSIT_BOB   = ethers.parseUnits("8000", 6);

    await depositFor(alice, DEPOSIT_ALICE);
    await depositFor(bob, DEPOSIT_BOB);

    // --- some trades ---
    const MAX_IN_ALICE = ethers.parseUnits("5000", 6);
    const MAX_IN_BOB   = ethers.parseUnits("4000", 6);

    // Alice buys A then B
    await ledger.connect(alice).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      posA,
      true,
      ethers.parseUnits("50", 6),
      MAX_IN_ALICE
    );

    await ledger.connect(alice).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      posB,
      true,
      ethers.parseUnits("30", 6),
      MAX_IN_ALICE
    );

    // Bob buys B then A
    await ledger.connect(bob).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      posB,
      true,
      ethers.parseUnits("40", 6),
      MAX_IN_BOB
    );

    await ledger.connect(bob).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      posA,
      true,
      ethers.parseUnits("20", 6),
      MAX_IN_BOB
    );

    // Some sells back into the market
    await ledger.connect(alice).sellExactTokens(
      await flatMM.getAddress(),
      marketId,
      posA,
      true,
      ethers.parseUnits("10", 6),
      0
    );

    await ledger.connect(bob).sellExactTokens(
      await flatMM.getAddress(),
      marketId,
      posB,
      true,
      ethers.parseUnits("15", 6),
      0
    );

    // ----------------- ppUSDC mirror checks -----------------

    const tsPp = await ppUSDC.totalSupply();

    const freeAlice  = await ledger.realFreeCollateral(alice.address);
    const freeBob    = await ledger.realFreeCollateral(bob.address);
    const freeDmm    = await ledger.realFreeCollateral(await flatMM.getAddress());
    const freeOwner  = await ledger.realFreeCollateral(owner.address);
    const freeLedger = await ledger.realFreeCollateral(await ledger.getAddress());

    // owner/ledger shouldn't be phantom holders of ppUSDC in this scenario
    expect(freeOwner).to.equal(0n);
    expect(freeLedger).to.equal(0n);

    const totalFree = freeAlice + freeBob + freeDmm + freeOwner + freeLedger;
    expect(totalFree).to.equal(await ledger.realTotalFreeCollateral());
    expect(tsPp).to.equal(totalFree);

    // per-account ppUSDC mirrors freeCollateral
    expect(await ppUSDC.balanceOf(alice.address)).to.equal(freeAlice);
    expect(await ppUSDC.balanceOf(bob.address)).to.equal(freeBob);
    expect(await ppUSDC.balanceOf(await flatMM.getAddress())).to.equal(freeDmm);

    // ----------------- ERC20 position mirrors -----------------

    // A: totalSupply == Alice + Bob + DMM (no owner/ledger leakage)
    const tsA      = await ledger.erc20TotalSupply(tokenA);
    const balA_A   = await ledger.erc20BalanceOf(tokenA, alice.address);
    const balA_B   = await ledger.erc20BalanceOf(tokenA, bob.address);
    const balA_DMM = await ledger.erc20BalanceOf(
      tokenA,
      await flatMM.getAddress()
    );
    const balA_Owner  = await ledger.erc20BalanceOf(tokenA, owner.address);
    const balA_Ledger = await ledger.erc20BalanceOf(
      tokenA,
      await ledger.getAddress()
    );

    // owner / ledger should not accumulate position tokens magically
    expect(balA_Owner).to.equal(0n);
    expect(balA_Ledger).to.equal(0n);

    const sumA = balA_A + balA_B + balA_DMM;
    expect(tsA).to.equal(sumA);

    // B: totalSupply == Alice + Bob + DMM
    const tsB      = await ledger.erc20TotalSupply(tokenB);
    const balB_A   = await ledger.erc20BalanceOf(tokenB, alice.address);
    const balB_B   = await ledger.erc20BalanceOf(tokenB, bob.address);
    const balB_DMM = await ledger.erc20BalanceOf(
      tokenB,
      await flatMM.getAddress()
    );
    const balB_Owner  = await ledger.erc20BalanceOf(tokenB, owner.address);
    const balB_Ledger = await ledger.erc20BalanceOf(
      tokenB,
      await ledger.getAddress()
    );

    expect(balB_Owner).to.equal(0n);
    expect(balB_Ledger).to.equal(0n);

    const sumB = balB_A + balB_B + balB_DMM;
    expect(tsB).to.equal(sumB);
  });
});
