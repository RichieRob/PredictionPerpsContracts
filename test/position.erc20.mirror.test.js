// test/position.erc20.mirror.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore } = require("./helpers/core");

describe("PositionERC20 mirrors + ISC seeding", function () {
  let fx;        // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let other;     // extra signer for sanity checks

  beforeEach(async () => {
    fx = await deployCore();
    const signers = await ethers.getSigners();
    // deployCore will have used [owner, trader, feeRecipient, ...]
    // so we can safely treat index 3 as "other"
    other = signers[3];
  });

  /// Helper: create a market with ISC seeded to `owner` as DMM,
  /// and one Back position with an ERC20 mirror.
  async function setupISCSeededPosition() {
    const { ledger, owner } = fx;

    const iscAmount = usdc("100"); // 100 full sets synthetic line

    // allow owner as DMM for this market
    await ledger.allowDMM(owner.address, true);

    // create market with synthetic collateral
    await ledger.createMarket(
      "ISC Seeded Market",
      "ISM",
      owner.address, // DMM account
      iscAmount,
      false,
      ethers.ZeroAddress,
      "0x"
    );

    const markets = await ledger.getMarkets();
    expect(markets.length).to.equal(1);
    const marketId = markets[0];

    // create one position (Back) with ERC20 mirror via staticCall
    const [positionId, tokenAddr] = await ledger.createPosition.staticCall(
      marketId,
      "Outcome A",
      "OA"
    );
    await ledger.createPosition(marketId, "Outcome A", "OA");

    const positionToken = await ethers.getContractAt(
      "PositionERC20",
      tokenAddr
    );

    return { marketId, positionId, positionToken, iscAmount };
  }

  it("seeds DMM balances from syntheticCollateral for each PositionERC20", async function () {
    const { marketId, positionId, positionToken, iscAmount } =
      await setupISCSeededPosition();

    const { ledger, owner, trader } = fx;

    // Sanity check: market meta wired
    const [mName, mTicker] = await ledger.getMarketDetails(marketId);
    const [pName, pTicker] = await ledger.getPositionDetails(
      marketId,
      positionId
    );

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

    // totalSupply = ISC line (no real capital yet)
    const mv = await ledger.getMarketValue(marketId);
    expect(mv).to.equal(0n);
    expect(supply).to.equal(iscAmount);

    // all ISC-seeded shares live on the DMM (owner) by design
    expect(ownerBal).to.equal(iscAmount);
    expect(traderBal).to.equal(0n);
    expect(otherBal).to.equal(0n);
  });

  it("PositionERC20 transfers move balances but keep totalSupply constant", async function () {
    const { positionToken, iscAmount } = await setupISCSeededPosition();
    const { owner, trader } = fx;

    const transferAmount = iscAmount / 4n; // 25% of ISC line

    const supplyBefore = await positionToken.totalSupply();
    const ownerBefore = await positionToken.balanceOf(owner.address);
    const traderBefore = await positionToken.balanceOf(trader.address);

    expect(supplyBefore).to.equal(iscAmount);
    expect(ownerBefore).to.equal(iscAmount);
    expect(traderBefore).to.equal(0n);

    // Transfer from DMM (owner) to trader
    await positionToken
      .connect(owner)
      .transfer(trader.address, transferAmount);

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
