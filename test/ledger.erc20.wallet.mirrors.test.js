const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – ERC20 mirrors under wallet flows", function () {
  let owner, alice, dmm;
  let usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM;
  let marketId, posId, tokenA;

  async function deployCore() {
    [owner, alice, dmm] = await ethers.getSigners();

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
    flatMM = await FlatMockMarketMaker.connect(dmm).deploy();
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

    // --- single-position market with ISC ---
    const ISC = ethers.parseUnits("100000", 6);
    await ledger.createMarket(
      "ERC20 Wallet Flow Market",
      "EWF",
      await flatMM.getAddress(),
      ISC,
      false,
      ethers.ZeroAddress,
      "0x"
    );
    const markets = await ledger.getMarkets();
    marketId = markets[0];

    // Predict ID/token, then execute once so ERC20 is registered
    const [predPosId, predToken] =
      await ledger.createPosition.staticCall(marketId, "YES", "YES");
    await ledger.createPosition(marketId, "YES", "YES");

    posId = predPosId;
    tokenA = predToken;
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

  it("keeps ERC20 created-shares mirror consistent when selling to wallet", async () => {
    const dmmAddr    = await flatMM.getAddress();
    const ledgerAddr = await ledger.getAddress();

    const DEPOSIT = ethers.parseUnits("10000", 6);
    await depositFor(alice, DEPOSIT);

    const TOKENS_BUY  = ethers.parseUnits("50", 6);
    const MAX_USDC_IN = ethers.parseUnits("5000", 6);

    // Alice buys YES from DMM using ppUSDC path
    await ledger.connect(alice).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      posId,
      true,
      TOKENS_BUY,
      MAX_USDC_IN
    );

    // Balances before wallet-sell
    const tsBefore       = await ledger.erc20TotalSupply(tokenA);
    const balAliceBefore = await ledger.erc20BalanceOf(tokenA, alice.address);
    const balDmmBefore   = await ledger.erc20BalanceOf(tokenA, dmmAddr);
    const balOwnerBefore = await ledger.erc20BalanceOf(tokenA, owner.address);
    const balLedgerBefore= await ledger.erc20BalanceOf(tokenA, ledgerAddr);

    const sumBefore =
      balAliceBefore + balDmmBefore + balOwnerBefore + balLedgerBefore;
    expect(tsBefore).to.equal(sumBefore);

    // Now Alice sells some YES and takes USDC back to wallet
    const TOKENS_SELL = ethers.parseUnits("20", 6);

    await ledger.connect(alice).sellExactTokensForUSDCToWallet(
      await flatMM.getAddress(),
      marketId,
      posId,
      true,
      TOKENS_SELL,
      0,
      alice.address
    );

    // Balances after wallet-sell
    const tsAfter       = await ledger.erc20TotalSupply(tokenA);
    const balAliceAfter = await ledger.erc20BalanceOf(tokenA, alice.address);
    const balDmmAfter   = await ledger.erc20BalanceOf(tokenA, dmmAddr);
    const balOwnerAfter = await ledger.erc20BalanceOf(tokenA, owner.address);
    const balLedgerAfter= await ledger.erc20BalanceOf(tokenA, ledgerAddr);

    // No phantom balances for owner/ledger
    expect(balOwnerAfter).to.equal(0n);
    expect(balLedgerAfter).to.equal(0n);

    // Sum of balances must equal totalSupply
    const sumAfter =
      balAliceAfter + balDmmAfter + balOwnerAfter + balLedgerAfter;
    expect(tsAfter).to.equal(sumAfter);

    // Directional sanity: Alice's created shares shouldn't increase,
    // DMM's shouldn't decrease, when she sells tokens back.
    expect(balAliceAfter).to.be.lte(balAliceBefore);
    expect(balDmmAfter).to.be.gte(balDmmBefore);

    // TVL invariant still holds
    const [tvl, aUSDCBal] = await ledger.invariant_tvl();
    expect(tvl).to.equal(aUSDCBal);

    // DMM still passes solvency/redeemability checks
    const effMin = await ledger.invariant_effectiveMin(dmmAddr, marketId);
    expect(effMin).to.be.gte(0n);

    const [netAlloc, redeemable, margin] =
      await ledger.invariant_redeemabilityState(dmmAddr, marketId);
    expect(margin).to.be.gte(0n);
    if (redeemable > 0n) {
      expect(netAlloc).to.be.gte(redeemable);
    }

    const okAll = await ledger.invariant_checkSolvencyAllMarkets(dmmAddr);
    expect(okAll).to.equal(true);
  });
});
