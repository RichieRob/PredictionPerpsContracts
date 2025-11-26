// test/ledger.markets.positions.test.js
const { deployCore } = require("./helpers/core");
const {
  createMarketWithDetails,
  expectPositionsBatchMetaForMarket,
  expectPositionsStaticMetaAndZeroBalances,
} = require("./helpers/markets");

describe("MarketMakerLedger – markets & positions", function () {
  let fx; // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }

  beforeEach(async () => {
    fx = await deployCore();
  });

  it("creates a market and stores name/ticker", async () => {
    await createMarketWithDetails(fx, {
      name:       "Premier League Winner",
      ticker:     "EPL24",
      dmmAddress: fx.owner.address, // dummy DMM
      iscAmount:  0n,
    });
  });

  it("creates positions and ERC20 clones with proper metadata", async () => {
    const marketName   = "Premier League Winner";
    const marketTicker = "EPL24";

    const marketId = await createMarketWithDetails(fx, {
      name:       marketName,
      ticker:     marketTicker,
      dmmAddress: fx.owner.address,
      iscAmount:  0n,
    });

    const positions = [
      { name: "Arsenal",          ticker: "ARS" },
      { name: "Liverpool",        ticker: "LIV" },
      { name: "Manchester City",  ticker: "MCI" },
    ];

    await expectPositionsBatchMetaForMarket(fx, {
      marketId,
      positions,
      marketName,
      marketTicker,
    });
  });

  it("wires ERC20 clones to ledger meta + balance views", async () => {
    const marketName   = "Premier League Winner";
    const marketTicker = "EPL24";

    const marketId = await createMarketWithDetails(fx, {
      name:       marketName,
      ticker:     marketTicker,
      dmmAddress: fx.owner.address,
      iscAmount:  0n,
    });

    const teams = [
      { name: "Arsenal",         ticker: "ARS" },
      { name: "Liverpool",       ticker: "LIV" },
      { name: "Manchester City", ticker: "MCI" },
    ];

    await expectPositionsStaticMetaAndZeroBalances(fx, {
      marketId,
      teams,
      marketName,
      marketTicker,
    });
  });
});
