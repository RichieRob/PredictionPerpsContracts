const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MarketMakerLedger – gas for market + 7 positions", function () {
  let owner, dmm;
  let usdc, aUSDC, aavePool, ppUSDC, ledger;

  beforeEach(async () => {
    [owner, dmm] = await ethers.getSigners();

    // Deploy mocks and core contracts (minimal setup for creation)
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
      ethers.ZeroAddress, // permit2 (unused)
      await ppUSDC.getAddress()
    );
    await ledger.waitForDeployment();

    // Wire ppUSDC to ledger
    await ppUSDC.setLedger(await ledger.getAddress());

    // Allow DMM (optional for creation, but matching other tests)
    await ledger.allowDMM(dmm.address, true);
  });

  it("creates market and 7 positions, logs gas usage", async () => {
    // Prepare 7 positions metadata
    const positions = Array.from({ length: 7 }, (_, i) => ({
      name: `Position name is ${i + 1}`,
      ticker: `POS${String(i + 1).padStart(2, "0")}`, // e.g., POS01, POS02, ...
    }));

    // Create market
    const createMarketTx = await ledger.createMarket(
      "Test Market with 7 Positions",
      "TM7",
      dmm.address, // DMM address
      0, // iscAmount (minimal)
      false, // doesResolve
      ethers.ZeroAddress, // oracle
      "0x" // oracleParams
    );
    const createMarketReceipt = await createMarketTx.wait();
    console.log("createMarket gas used:", createMarketReceipt.gasUsed.toString());

    const markets = await ledger.getMarkets();
    const marketId = markets[0];
    expect(markets.length).to.equal(1);

    // Verify market details
    const [marketName, marketTicker] = await ledger.getMarketDetails(marketId);
    expect(marketName).to.equal("Test Market with 7 Positions");
    expect(marketTicker).to.equal("TM7");

    // Create 7 positions in batch
    const createPositionsTx = await ledger.createPositions(marketId, positions);
    const createPositionsReceipt = await createPositionsTx.wait();
    console.log("createPositions (7 positions) gas used:", createPositionsReceipt.gasUsed.toString());

    // Verify positions created
    const positionIds = await ledger.getMarketPositions(marketId);
    expect(positionIds.length).to.equal(7);

    // Optional: Spot-check a few positions and ERC20 wiring
    for (let i = 0; i < Math.min(3, positions.length); i++) {
      const pid = positionIds[i];
      const [posName, posTicker] = await ledger.getPositionDetails(marketId, pid);
      expect(posName).to.equal(positions[i].name);
      expect(posTicker).to.equal(positions[i].ticker);

      // ERC20 name/symbol
      const erc20Name = await ledger.erc20Name(marketId, pid);
      const erc20Symbol = await ledger.erc20Symbol(marketId, pid);
      expect(erc20Name).to.equal(`${positions[i].name} in Test Market with 7 Positions`);
      expect(erc20Symbol).to.equal(`${positions[i].ticker}-TM7`);
    }

    // Total gas (sum of both txs)
    const totalGas = createMarketReceipt.gasUsed + createPositionsReceipt.gasUsed;
    console.log("Total gas for market + 7 positions:", totalGas.toString());
    console.log("Average gas per position:", (createPositionsReceipt.gasUsed / BigInt(7)).toString());
  });
});