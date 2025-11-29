// test/ledger.ppusdc.mirror.test.js

const { expect } = require("chai");
const {
  usdc,
  deployCore,
  mintAndDeposit,
  expectFlatLedgerForTrader,
} = require("./helpers/core");

describe("PpUSDC mirror behaviour", function () {
  let fx;
  let owner, alice, bob;
  let usdcToken, aUSDC, ppUSDC, ledger;

  beforeEach(async () => {
    // fx: { owner, trader, feeRecipient, other, usdc, aUSDC, aavePool, ppUSDC, ledger }
    fx = await deployCore();

    owner     = fx.owner;
    alice     = fx.trader;        // reuse trader as alice
    bob       = fx.feeRecipient;  // reuse feeRecipient as bob
    usdcToken = fx.usdc;
    aUSDC     = fx.aUSDC;
    ppUSDC    = fx.ppUSDC;
    ledger    = fx.ledger;
  });

  it("mirrors freeCollateral and totalFreeCollateral after deposit", async () => {
    const DEPOSIT = usdc("1000"); // 1,000 USDC

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: alice,
      amount: DEPOSIT,
    });

    await expectFlatLedgerForTrader({
      ledger,
      aUSDC,
      ppUSDC,
      trader: alice,
      expected: DEPOSIT,
    });
  });

  it("ppUSDC transfers move freeCollateral between accounts and preserve totals", async () => {
    const DEPOSIT  = usdc("1000");
    const TRANSFER = usdc("250");

    // Deposit for Alice only
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: alice,
      amount: DEPOSIT,
    });

    // sanity pre-transfer
    const preFreeAlice = await ledger.realFreeCollateral(alice.address);
    const preFreeBob   = await ledger.realFreeCollateral(bob.address);
    const preTotalFree = await ledger.realTotalFreeCollateral();
    const preTs        = await ppUSDC.totalSupply();

    expect(preFreeAlice).to.equal(DEPOSIT);
    expect(preFreeBob).to.equal(0n);
    expect(preTotalFree).to.equal(DEPOSIT);
    expect(preTs).to.equal(DEPOSIT);

    // transfer ppUSDC from alice -> bob
    await ppUSDC.connect(alice).transfer(bob.address, TRANSFER);

    const postFreeAlice = await ledger.realFreeCollateral(alice.address);
    const postFreeBob   = await ledger.realFreeCollateral(bob.address);
    const postTotalFree = await ledger.realTotalFreeCollateral();
    const postTs        = await ppUSDC.totalSupply();

    const balAlice = await ppUSDC.balanceOf(alice.address);
    const balBob   = await ppUSDC.balanceOf(bob.address);

    // balances & freeCollateral move in lockstep
    expect(balAlice).to.equal(DEPOSIT - TRANSFER);
    expect(balBob).to.equal(TRANSFER);

    expect(postFreeAlice).to.equal(DEPOSIT - TRANSFER);
    expect(postFreeBob).to.equal(TRANSFER);

    // totals unchanged
    expect(postTotalFree).to.equal(preTotalFree);
    expect(postTs).to.equal(preTs);
  });
});
