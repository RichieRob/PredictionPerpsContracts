// test/deposit.withdraw.fee.test.js
const { expect } = require("chai");
const {
  usdc,
  deployCore,
  depositFromTrader,
  EMPTY_PERMIT,
} = require("./helpers/core");

describe("MarketMakerLedger — deposit with protocol fee skim", function () {
  let owner, trader, feeRecipient, other;
  let usdcToken, aUSDC, aavePool, ppUSDC, ledger;

  beforeEach(async () => {
    ({
      owner,
      trader,
      feeRecipient,
      other,
      usdc: usdcToken,
      aUSDC,
      aavePool,
      ppUSDC,
      ledger,
    } = await deployCore());

    // Fund trader
    await usdcToken.mint(trader.address, usdc("1000"));

    // Enable protocol fee: 1% (100 bps) to feeRecipient
    await ledger
      .connect(owner)
      .setFeeConfig(feeRecipient.address, 100, true);
  });

  it("skims aUSDC fee and credits only net amount to TVL and freeCollateral", async function () {
    const DEPOSIT = usdc("100");
    const FEE_BPS = 100n; // 1%
    const FEE = (DEPOSIT * FEE_BPS) / 10_000n;
    const NET = DEPOSIT - FEE;

    // pre-state sanity
    expect(await ledger.getTotalValueLocked()).to.equal(0n);
    expect(await ledger.realTotalFreeCollateral()).to.equal(0n);
    expect(await aUSDC.balanceOf(await ledger.getAddress())).to.equal(0n);
    expect(await aUSDC.balanceOf(feeRecipient.address)).to.equal(0n);

    await depositFromTrader({
      ledger,
      usdc: usdcToken,
      trader,
      amount: DEPOSIT,
    });

    const free = await ledger.realFreeCollateral(trader.address);
    const totalFree = await ledger.realTotalFreeCollateral();
    const tvl = await ledger.getTotalValueLocked();

    const ledgerABal = await aUSDC.balanceOf(await ledger.getAddress());
    const feeABal = await aUSDC.balanceOf(feeRecipient.address);
    const totalASupply = await aUSDC.totalSupply();

    expect(free).to.equal(NET);
    expect(totalFree).to.equal(NET);
    expect(tvl).to.equal(NET);
    expect(ledgerABal).to.equal(NET);
    expect(feeABal).to.equal(FEE);
    expect(totalASupply).to.equal(DEPOSIT);

    const [tvlView, aBalView] = await ledger.invariant_tvl();
    expect(tvlView).to.equal(NET);
    expect(aBalView).to.equal(NET);
  });
});
