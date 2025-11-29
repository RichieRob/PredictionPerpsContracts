const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc } = require("./helpers/core");
const {
  setupLmsrLedgerFixture,
  traderDepositsAndBuysLmsr,
} = require("./helpers/lmsr.ledger");

describe("LMSR + MarketMakerLedger integration", () => {
  it("starts ~50/50 and moves price after a trade", async () => {
    const fx = await setupLmsrLedgerFixture();
    const { lmsr, marketId, yesId } = fx;

    const half = ethers.parseEther("0.5");

    const pBefore = await lmsr.getBackPriceWad(marketId, yesId);
    expect(pBefore).to.be.closeTo(half, half / 1_000_000n);

    await traderDepositsAndBuysLmsr(fx, {
      depositAmount: usdc("1000"),
      tokensToBuy:   usdc("10"),
      maxUsdcIn:     usdc("500"),
    });

    const pAfter = await lmsr.getBackPriceWad(marketId, yesId);
    expect(pAfter).to.be.gt(pBefore);
  });
});
