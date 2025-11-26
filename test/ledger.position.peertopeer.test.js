// test/ledger.position.peertopeer.test.js

const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – peer-to-peer PositionERC20 transfers", function () {
  let owner, dmm, trader1, trader2;
  let usdc, aUSDC, aavePool, ppUSDC, ledger;
  let marketId, positionId, positionToken;

  async function deployCore() {
    [owner, dmm, trader1, trader2] = await ethers.getSigners();

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

    const Ledger = await ethers.getContractFactory("MarketMakerLedger");
    ledger = await Ledger.deploy(
      await usdc.getAddress(),
      await aUSDC.getAddress(),
      await aavePool.getAddress(),
      ethers.ZeroAddress,          // permit2
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    await ppUSDC.setLedger(await ledger.getAddress());
  }

  beforeEach(async function () {
    await deployCore();
  
    await ledger.allowDMM(dmm.address, true);
  
    const iscSeed = ethers.parseUnits("1000", 6);
    const marketTx = await ledger.createMarket(
      "Test Market",
      "TM",
      dmm.address,
      iscSeed,
      false,              // doesResolve
      ethers.ZeroAddress, // oracle
      "0x"                // oracleParams
    );
    const marketReceipt = await marketTx.wait();
  
    // 🔹 Get the real marketId from the MarketCreated event
    const marketEvt = marketReceipt.logs.find(
      (l) => l.fragment && l.fragment.name === "MarketCreated"
    );
    marketId = marketEvt.args.marketId;
  
    const posTx = await ledger.createPosition(marketId, "YES", "YES");
    const posReceipt = await posTx.wait();
  
    const posEvt = posReceipt.logs.find(
      (l) => l.fragment && l.fragment.name === "PositionCreated"
    );
    positionId = posEvt.args.positionId;
    const tokenAddr = posEvt.args.token; // or backToken if that’s the param name
    positionToken = await ethers.getContractAt("PositionERC20", tokenAddr);
  
    // DMM owns all created-shares initially – give some to trader1
    const dmmBal = await positionToken.balanceOf(dmm.address);
    const seedToTrader = dmmBal / 4n;
  
    await positionToken.connect(dmm).transfer(trader1.address, seedToTrader);
  });
  

  it("PositionERC20 transfer moves created-shares between traders and preserves totalSupply", async function () {
    const supplyBefore = await positionToken.totalSupply();
    const bal1Before = await positionToken.balanceOf(trader1.address);
    const bal2Before = await positionToken.balanceOf(trader2.address);

    expect(bal1Before).to.be.gt(0n);

    const transferAmount = bal1Before / 2n;

    await positionToken
      .connect(trader1)
      .transfer(trader2.address, transferAmount);

    const supplyAfter = await positionToken.totalSupply();
    const bal1After = await positionToken.balanceOf(trader1.address);
    const bal2After = await positionToken.balanceOf(trader2.address);

    // totals unchanged, just balances moved
    expect(supplyAfter).to.equal(supplyBefore);
    expect(bal1After).to.equal(bal1Before - transferAmount);
    expect(bal2After).to.equal(bal2Before + transferAmount);
  });

  it("reverts PositionERC20 transfer when sender doesn't have enough shares", async function () {
    const bal1 = await positionToken.balanceOf(trader1.address);
    const tooMuch = bal1 + 1n;

    await expect(
      positionToken.connect(trader1).transfer(trader2.address, tooMuch)
    ).to.be.reverted; // you can tighten this if PositionERC20 has a specific revert message
  });

  it("PositionERC20 P2P transfer preserves solvency & ISC line", async function () {
    // Grab system-level invariants before the transfer
    const [usedBefore, lineBefore] = await ledger.invariant_iscWithinLine(
      marketId
    );
    const effMinBefore = await ledger.invariant_effectiveMin(
      dmm.address,
      marketId
    );
    const fundingBefore = await ledger.invariant_systemFunding(marketId);

    const amount = await positionToken.balanceOf(trader1.address);
    await positionToken.connect(trader1).transfer(trader2.address, amount);

    const [usedAfter, lineAfter] = await ledger.invariant_iscWithinLine(
      marketId
    );
    const effMinAfter = await ledger.invariant_effectiveMin(
      dmm.address,
      marketId
    );
    const fundingAfter = await ledger.invariant_systemFunding(marketId);

    // P2P should not change global accounting / ISC
    expect(usedAfter).to.equal(usedBefore);
    expect(lineAfter).to.equal(lineBefore);
    expect(effMinAfter).to.equal(effMinBefore);
    expect(fundingAfter).to.equal(fundingBefore);
  });
});
