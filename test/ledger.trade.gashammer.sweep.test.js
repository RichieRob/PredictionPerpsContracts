// test/ledger.trade.gashammer.sweep.test.js

const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");
const { runSizeGasHammer } = require("./helpers/markets.gas");

describe(
  "MarketMakerLedger – trade gas hammer (large market size sweep)",
  function () {
    it("runs small vs large gas hammer for multiple large market sizes", async function () {
      // NOTE: 1000 should be fine; 10000 may hit gas limits in initMarket,
      // so we catch and just log if it blows up.
      const LARGE_SIZES = [10, 30, 1000, 10000];

      for (const n of LARGE_SIZES) {
        console.log(
          `\n\n===== [GAS SIZE SWEEP] large market with ${n} positions =====`
        );

        const fx = await setupLmsrLedgerFixture();

        try {
          await runSizeGasHammer(fx, n, {
            sampleLargePositions: 8, // tweak if you want
          });
        } catch (err) {
          console.log(
            `[size sweep] largeN=${n} failed with error: ${err.message}`
          );
          // we don't rethrow so the sweep can continue for other sizes
        }
      }
    });
  }
);
