// test/lmsr.init.capacity.test.js

const { setupLmsrLedgerFixture } = require("./helpers/lmsr.ledger");
const { createLmsrMarket } = require("./helpers/markets.lmsr");

/**
 * This test is purely exploratory / diagnostic:
 * it keeps creating LMSR markets with larger and larger numbers
 * of positions (always smallMarket=false so we hit the full heap path)
 * and logs the largest N for which initMarket succeeds.
 *
 * It does NOT assert on specific thresholds; it just stops on first failure.
 */

describe("LMSR – initMarket capacity by number of positions", function () {
  // bump timeout a bit because we're doing a bunch of deployments
  this.timeout(120000);

  it("logs the largest N for which initMarket succeeds (large-market path only)", async function () {
    const fx = await setupLmsrLedgerFixture();
    const sizes = [
      2,
      5,
      10,
      20,
      30,
      40,
      50,
      60,
      80,
      100,
      150,
      200,
      210,
      215,
      220,
      221,
      222,
      223,
      224,
      225,
      250,
      300,
      400,
      600,
      800,
      1000,
    ];

    let lastSuccess = null;

    for (const n of sizes) {
      console.log(`\n[LMSR init capacity] trying nPositions = ${n}`);

      try {
        await createLmsrMarket(fx, {
          name: `InitCap_${n}`,
          ticker: `IC${n}`,
          nPositions: n,
          // IMPORTANT: force the large-market path so we hit the full heap logic
          smallMarket: false,
        });

        console.log(`[LMSR init capacity] ✅ SUCCESS for nPositions = ${n}`);
        lastSuccess = n;
      } catch (err) {
        console.log(
          `[LMSR init capacity] ❌ FAILED for nPositions = ${n}: ${err.message}`
        );
        break;
      }
    }

    console.log(
      `\n[LMSR init capacity] largest successful nPositions on this config: ${
        lastSuccess === null ? "none" : lastSuccess
      }`
    );
  });
});
