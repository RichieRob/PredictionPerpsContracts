// test/ledger.autoconsolidate.test.js
const { expect } = require("chai");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupMarketFixture } = require("./helpers/markets");

describe("MarketMakerLedger – auto consolidation of back/lay", function () {
  let fx;

  beforeEach(async () => {
    // deploy core + flatMM + market with ISC + single position
    fx = await setupMarketFixture();
  });

  it("back 100, then buy lay 10 → net back 90", async () => {
    const {
      trader,
      ledger,
      usdc: usdcToken,
      flatMM,
      marketId,
      positionId,
      positionToken,
    } = fx;

    const dmmAddr = await flatMM.getAddress();

    // 1) deposit some USDC so trader can trade
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: usdc("1000"),
    });

    // 2) buy 100 BACK
    await ledger.connect(trader).buyExactTokens(
      dmmAddr,
      marketId,
      positionId,
      true,             // isBack = true
      usdc("100"),      // tokensToBuy
      usdc("1000")      // maxUsdcIn (loose bound)
    );

    const backBefore = await ledger.erc20BalanceOf(
      positionToken,
      trader.address
    );
    expect(backBefore).to.equal(usdc("100"));

    // 3) buy 10 LAY against the same position
    await ledger.connect(trader).buyExactTokens(
      dmmAddr,
      marketId,
      positionId,
      false,            // isBack = false → LAY
      usdc("10"),       // tokensToBuy as lay
      usdc("1000")      // maxUsdcIn
    );

    // 4) after auto-consolidation, net BACK should be 80
    const backAfter = await ledger.erc20BalanceOf(
      positionToken,
      trader.address
    );
    expect(backAfter).to.equal(usdc("90"));
  });
});
