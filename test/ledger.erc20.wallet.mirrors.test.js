// test/ledger.erc20.walletflows.test.js
const {
    setupMarketFixture,
    expectErc20MirrorsWalletSellFlow,
  } = require("./helpers/markets");
  
  describe("MarketMakerLedger – ERC20 mirrors under wallet flows", function () {
    let fx;
  
    beforeEach(async () => {
      fx = await setupMarketFixture();
    });
  
    it("keeps ERC20 created-shares mirror consistent when selling to wallet", async () => {
      await expectErc20MirrorsWalletSellFlow(fx);
    });
  });
  