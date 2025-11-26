// test/ledger.wallet-buys.test.js

const { expect } = require("chai");
const { usdc, EMPTY_PERMIT } = require("./helpers/core");
const {
  setupMarketFixture,
  expectSolventRedeemability,
} = require("./helpers/markets");

describe("MarketMakerLedger – wallet-based buys", function () {
  let fx; // { owner, trader, usdc, aUSDC, aavePool, ppUSDC, ledger, flatMM, marketId, positionId }

  beforeEach(async () => {
    fx = await setupMarketFixture();
  });

  it("routes buyExactTokensWithUSDC via depositFromTraderUnified + maintains invariants", async () => {
    const WALLET_USDC = usdc("5000");
    const TOKENS_OUT  = usdc("100");
    const MAX_USDC_IN = usdc("5000");

    const {
      trader,
      usdc: usdcToken,
      ppUSDC,
      ledger,
      flatMM,
      marketId,
      positionId,
    } = fx;

    // fund trader wallet
    await usdcToken.mint(trader.address, WALLET_USDC);
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), WALLET_USDC);

    const walletBefore = await usdcToken.balanceOf(trader.address);
    const ppBefore     = await ppUSDC.balanceOf(trader.address);
    const freeBefore   = await ledger.realFreeCollateral(trader.address);
    const [tvlBefore, aUSDCBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(aUSDCBefore);
    expect(ppBefore).to.equal(freeBefore);

    // mode = 0 (allowance)
    await ledger.connect(trader).buyExactTokensWithUSDC(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,              // isBack
      TOKENS_OUT,
      MAX_USDC_IN,
      0,                 // mode: allowance
      EMPTY_PERMIT,
      "0x"               // permit2 calldata
    );

    const walletAfter = await usdcToken.balanceOf(trader.address);
    const ppAfter     = await ppUSDC.balanceOf(trader.address);
    const freeAfter   = await ledger.realFreeCollateral(trader.address);
    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();

    // wallet spent some USDC
    expect(walletAfter).to.be.lt(walletBefore);

    // trader now has some freeCollateral, mirrored by ppUSDC
    expect(freeAfter).to.be.gte(0n);
    expect(ppAfter).to.equal(freeAfter);

    // TVL and aUSDC still in lockstep and increased
    expect(tvlAfter).to.equal(aUSDCAfter);
    expect(tvlAfter).to.be.gt(tvlBefore);

    // trader solvency / redeemability via shared helper
    await expectSolventRedeemability(fx, {
      account: trader.address,
      marketId,
    });
  });

  it("routes buyForUSDCWithUSDC correctly and keeps TVL == aUSDC", async () => {
    const WALLET_USDC = usdc("2000");
    const USDC_IN     = usdc("800");

    const {
      trader,
      usdc: usdcToken,
      ledger,
      flatMM,
      marketId,
      positionId,
    } = fx;

    await usdcToken.mint(trader.address, WALLET_USDC);
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), WALLET_USDC);

    const walletBefore = await usdcToken.balanceOf(trader.address);
    const [tvlBefore, aUSDCBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(aUSDCBefore);

    await ledger.connect(trader).buyForUSDCWithUSDC(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,             // isBack
      USDC_IN,
      0,                // minTokensOut
      0,                // mode: allowance
      EMPTY_PERMIT,
      "0x"
    );

    const walletAfter = await usdcToken.balanceOf(trader.address);
    const freeAfter   = await ledger.realFreeCollateral(trader.address);
    const [tvlAfter, aUSDCAfter] = await ledger.invariant_tvl();

    // wallet spent some USDC
    expect(walletAfter).to.be.lt(walletBefore);

    // freeCollateral is >= 0 (might be 0 if all spend was instant)
    expect(freeAfter).to.be.gte(0n);

    // TVL vs aUSDC invariant
    expect(tvlAfter).to.equal(aUSDCAfter);
    expect(tvlAfter).to.be.gt(tvlBefore);

    // trader still globally solvent
    await expectSolventRedeemability(fx, {
      account: trader.address,
      marketId,
    });
  });
});
