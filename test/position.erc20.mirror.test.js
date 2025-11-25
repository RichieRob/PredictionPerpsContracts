// test/position.erc20.mirror.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

// 6-decimals helper
const usdc = (n) => {
  if (typeof n === "string") return BigInt(n) * 1_000_000n;
  return BigInt(n) * 1_000_000n;
};

describe("PositionERC20 mirrors + ISC seeding", function () {
  let owner, trader, other;
  let usdcToken;
  let aUSDC;
  let aavePool;
  let ppUSDC;
  let ledger;

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
  });

  /// Helper: create a market with ISC seeded to `owner` as DMM,
  /// and one Back position with an ERC20 mirror.
  async function setupISCSeededPosition() {
    const iscAmount = usdc("100"); // 100 full sets synthetic line

    // allow owner as DMM for this market
    await ledger.allowDMM(owner.address, true);

    // create market with synthetic collateral
    await ledger.createMarket(
      "ISC Seeded Market",
      "ISM",
      owner.address, // DMM account
      iscAmount
    );

    const markets = await ledger.getMarkets();
    expect(markets.length).to.equal(1);
    const marketId = markets[0];

    // create one position (Back) with ERC20 mirror
    const tx = await ledger.createPosition(
      marketId,
      "Outcome A",
      "OA"
    );
    const receipt = await tx.wait();

    const iface = ledger.interface;
    let tokenAddr;
    let positionId;

    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed.name === "PositionCreated") {
          tokenAddr = parsed.args.token;
          positionId = parsed.args.positionId;
          break;
        }
      } catch (_) {
        // ignore non-ledger logs
      }
    }

    // Simple JS sanity checks to avoid BigInt vs null chai issues
    if (!tokenAddr || positionId === undefined || positionId === null) {
      throw new Error("PositionCreated event not found");
    }

    const PositionERC20 = await ethers.getContractFactory("PositionERC20");
    const positionToken = PositionERC20.attach(tokenAddr);

    return { marketId, positionId, positionToken, iscAmount };
  }

  it("seeds DMM balances from syntheticCollateral for each PositionERC20", async function () {
    const { marketId, positionId, positionToken, iscAmount } =
      await setupISCSeededPosition();

    // Sanity check: market meta wired
    const [mName, mTicker] = await ledger.getMarketDetails(marketId);
    const [pName, pTicker] = await ledger.getPositionDetails(marketId, positionId);

    expect(mName).to.equal("ISC Seeded Market");
    expect(mTicker).to.equal("ISM");
    expect(pName).to.equal("Outcome A");
    expect(pTicker).to.equal("OA");

    // ERC20 meta from PositionERC20 -> ledger
    const name = await positionToken.name();
    const symbol = await positionToken.symbol();
    expect(name).to.equal("Outcome A in ISC Seeded Market");
    expect(symbol).to.equal("OA-ISM");

    // --- Core ISC mirror assertions ---

    const supply = await positionToken.totalSupply();
    const ownerBal = await positionToken.balanceOf(owner.address);
    const traderBal = await positionToken.balanceOf(trader.address);
    const otherBal = await positionToken.balanceOf(other.address);

    // totalSupply = marketValue + syntheticCollateral
    const mv = await ledger.getMarketValue(marketId);
    expect(mv).to.equal(0n); // no real capital yet
    expect(supply).to.equal(iscAmount);

    // all ISC-seeded shares live on the DMM (owner) by design
    expect(ownerBal).to.equal(iscAmount);
    expect(traderBal).to.equal(0n);
    expect(otherBal).to.equal(0n);
  });

  it("PositionERC20 transfers move balances but keep totalSupply constant", async function () {
    const { positionToken, iscAmount } = await setupISCSeededPosition();

    const transferAmount = iscAmount / 4n; // 25% of ISC line

    const supplyBefore = await positionToken.totalSupply();
    const ownerBefore = await positionToken.balanceOf(owner.address);
    const traderBefore = await positionToken.balanceOf(trader.address);

    expect(supplyBefore).to.equal(iscAmount);
    expect(ownerBefore).to.equal(iscAmount);
    expect(traderBefore).to.equal(0n);

    // Transfer from DMM (owner) to trader
    await positionToken.connect(owner).transfer(trader.address, transferAmount);

    const supplyAfter = await positionToken.totalSupply();
    const ownerAfter = await positionToken.balanceOf(owner.address);
    const traderAfter = await positionToken.balanceOf(trader.address);

    // totalSupply is derived from ledger (mv + isc), so unchanged
    expect(supplyAfter).to.equal(iscAmount);

    // balances reflected as expected
    expect(ownerAfter).to.equal(iscAmount - transferAmount);
    expect(traderAfter).to.equal(transferAmount);
  });
});
