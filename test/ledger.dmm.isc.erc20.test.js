// test/ledger.dmm.isc.erc20.test.js
const {
    setupMarketFixture,
    expectDmmIscMirrorState,
  } = require("./helpers/markets");
  
  describe("MarketMakerLedger – DMM ISC + ERC20 mirrors", function () {
    let fx;
  
    beforeEach(async () => {
      fx = await setupMarketFixture();
    });
  
    it("gives the DMM the full ISC as created shares and matches ERC20 supply", async () => {
      await expectDmmIscMirrorState(fx);
    });
  });
  