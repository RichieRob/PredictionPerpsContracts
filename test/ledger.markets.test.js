const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – markets & positions", function () {
  let owner, trader, dmm;
  let usdc, aUSDC, aavePool, ppUSDC, ledger;

  beforeEach(async () => {
    [owner, trader, dmm] = await ethers.getSigners();

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
      ethers.ZeroAddress,          // permit2 (unused for now)
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // wire ppUSDC -> ledger
    await ppUSDC.setLedger(await ledger.getAddress());

        // 🔑 allow a dummy DMM
        await ledger.allowDMM(dmm.address, true);

  });

  it("creates a market and stores name/ticker", async () => {
    const iscAmount = 0;

    await ledger.createMarket("Premier League Winner", "EPL24", dmm.address, iscAmount);

    const markets = await ledger.getMarkets();
    expect(markets.length).to.equal(1);

    const marketId = markets[0];
    const [name, ticker] = await ledger.getMarketDetails(marketId);

    expect(name).to.equal("Premier League Winner");
    expect(ticker).to.equal("EPL24");
  });

  it("creates positions and ERC20 clones with proper metadata", async () => {
    const iscAmount = 0;

    await ledger.createMarket("Premier League Winner", "EPL24", dmm.address, iscAmount);
    const markets = await ledger.getMarkets();
    const marketId = markets[0];

    const positions = [
      { name: "Arsenal", ticker: "ARS" },
      { name: "Liverpool", ticker: "LIV" },
      { name: "Manchester City", ticker: "MCI" },
    ];

    await ledger.createPositions(marketId, positions);
    const positionIds = await ledger.getMarketPositions(marketId);

    expect(positionIds.length).to.equal(3);

    for (let i = 0; i < positionIds.length; i++) {
      const pid = positionIds[i];

      const [name, ticker] = await ledger.getPositionDetails(marketId, pid);
      expect(name).to.equal(positions[i].name);
      expect(ticker).to.equal(positions[i].ticker);

      const symbol = await ledger.erc20Symbol(marketId, pid);
      const fullName = await ledger.erc20Name(marketId, pid);

      expect(symbol).to.equal(`${positions[i].ticker}-EPL24`);
      expect(fullName).to.equal(`${positions[i].name} in Premier League Winner`);
    }
  });

});
