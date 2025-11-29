// test/ledger.gas.market-7-positions.test.js
const { deployCore } = require("./helpers/core");
const { expectGasForMarketWithPositions } = require("./helpers/markets");

describe("MarketMakerLedger – gas for market + 7 positions", function () {
  let fx; // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }

  beforeEach(async () => {
    fx = await deployCore();
  });

  it("creates market and 7 positions, logs gas usage", async () => {
    const positions = Array.from({ length: 7 }, (_, i) => ({
      name: `Position name is ${i + 1}`,
      ticker: `POS${String(i + 1).padStart(2, "0")}`, // POS01, POS02, ...
    }));

    await expectGasForMarketWithPositions(fx, {
      marketName:  "Test Market with 7 Positions",
      marketTicker: "TM7",
      dmmAddress:  fx.owner.address,   // any address is fine for gas test
      iscAmount:   0n,
      positions,
    });
  });
});
