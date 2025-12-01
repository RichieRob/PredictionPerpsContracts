// test/ledger.multisided.balances.test.js
const { expect } = require("chai");
const { usdc } = require("./helpers/core");
const {
  setupMultiUserTwoPositionFixture,
  multiUserDeposits,
} = require("./helpers/markets.multiuser");

describe("MarketMakerLedger – 3-position market, back/lay + transfer", function () {
  let fx;

  beforeEach(async () => {
    fx = await setupMultiUserTwoPositionFixture();
    const { ledger, marketId } = fx;

    // --- Add third position C ---
    const [posC, tokenC] = await ledger.createPosition.staticCall(
      marketId,
      "Team C",
      "C"
    );
    await ledger.createPosition(marketId, "Team C", "C");

    fx.posC = posC;
    fx.tokenC = tokenC;

    // --- Fund Alice and Bob ---
    await multiUserDeposits(fx, {
      aliceDeposit: usdc("1000"),
      bobDeposit: usdc("1000"),
    });
  });

  it("u1 BACK 100 A → u2 LAY 10 A → u2 → u1 transfer 10 LAY A", async () => {
    const {
      ledger,
      flatMM,
      marketId,
      posA,
      tokenA,
      tokenB,
      tokenC,
      ppUSDC,
      alice,
      bob,
    } = fx;

    const dmm = await flatMM.getAddress();
    const ledgerAddr = await ledger.getAddress();

    // -------------------------------
    // Step 1: Alice buys 100 BACK on A
    // -------------------------------
    await ledger.connect(alice).buyExactTokens(
      dmm,
      marketId,
      posA,
      true,          // isBack
      usdc("100"),   // tokens out
      usdc("1000")   // max USDC in
    );

    // Balances after Step 1
    const aliceA1 = await ledger.erc20BalanceOf(tokenA, alice.address);
    const aliceB1 = await ledger.erc20BalanceOf(tokenB, alice.address);
    const aliceC1 = await ledger.erc20BalanceOf(tokenC, alice.address);
    const alicePP1 = await ppUSDC.balanceOf(alice.address);

    const bobA1 = await ledger.erc20BalanceOf(tokenA, bob.address);
    const bobB1 = await ledger.erc20BalanceOf(tokenB, bob.address);
    const bobC1 = await ledger.erc20BalanceOf(tokenC, bob.address);
    const bobPP1 = await ppUSDC.balanceOf(bob.address);

    const dmmA1 = await ledger.erc20BalanceOf(tokenA, dmm);
    const dmmB1 = await ledger.erc20BalanceOf(tokenB, dmm);
    const dmmC1 = await ledger.erc20BalanceOf(tokenC, dmm);
    const dmmPP1 = await ppUSDC.balanceOf(dmm);

    const ledgerA1 = await ledger.erc20BalanceOf(tokenA, ledgerAddr);
    const ledgerB1 = await ledger.erc20BalanceOf(tokenB, ledgerAddr);
    const ledgerC1 = await ledger.erc20BalanceOf(tokenC, ledgerAddr);
    const ledgerPP1 = await ppUSDC.balanceOf(ledgerAddr);

    // Expectations from the debug run:
    // Alice: A=100, B=0, C=0, ppUSDC=910
    expect(aliceA1).to.equal(usdc("100"));
    expect(aliceB1).to.equal(0n);
    expect(aliceC1).to.equal(0n);
    expect(alicePP1).to.equal(usdc("910"));

    // Bob: all positions 0, ppUSDC=1000
    expect(bobA1).to.equal(0n);
    expect(bobB1).to.equal(0n);
    expect(bobC1).to.equal(0n);
    expect(bobPP1).to.equal(usdc("1000"));

    // DMM: A=99900, B=100000, C=100000, ppUSDC=90
    expect(dmmA1).to.equal(usdc("99900"));
    expect(dmmB1).to.equal(usdc("100000"));
    expect(dmmC1).to.equal(usdc("100000"));
    expect(dmmPP1).to.equal(usdc("90"));

    // Ledger: holds no positions or ppUSDC
    expect(ledgerA1).to.equal(0n);
    expect(ledgerB1).to.equal(0n);
    expect(ledgerC1).to.equal(0n);
    expect(ledgerPP1).to.equal(0n);

    // -------------------------------
    // Step 2: Bob buys 10 LAY on A
    // -------------------------------
    await ledger.connect(bob).buyExactTokens(
      dmm,
      marketId,
      posA,
      false,        // isBack = false → Lay
      usdc("10"),   // lay size
      usdc("1000")
    );

    const alicePP2 = await ppUSDC.balanceOf(alice.address);
    const bobA2 = await ledger.erc20BalanceOf(tokenA, bob.address);
    const bobB2 = await ledger.erc20BalanceOf(tokenB, bob.address);
    const bobC2 = await ledger.erc20BalanceOf(tokenC, bob.address);
    const bobPP2 = await ppUSDC.balanceOf(bob.address);

    const dmmA2 = await ledger.erc20BalanceOf(tokenA, dmm);
    const dmmPP2 = await ppUSDC.balanceOf(dmm);

    // Alice unchanged in this step
    expect(alicePP2).to.equal(usdc("910"));

    // Bob: B=10, C=10, ppUSDC=991, still 0 of A
    expect(bobA2).to.equal(0n);
    expect(bobB2).to.equal(usdc("10"));
    expect(bobC2).to.equal(usdc("10"));
    expect(bobPP2).to.equal(usdc("991"));

    // DMM: A increased to 99910, ppUSDC dropped to 89
    expect(dmmA2).to.equal(usdc("99910"));
    expect(dmmPP2).to.equal(usdc("89"));

    // -------------------------------
    // Step 3: Bob transfers 10 LAY A → Alice
    // -------------------------------
    await ledger.connect(bob).transferPosition(
      alice.address,
      marketId,
      posA,
      false,        // Lay side
      usdc("10")
    );

    const aliceA3 = await ledger.erc20BalanceOf(tokenA, alice.address);
    const aliceB3 = await ledger.erc20BalanceOf(tokenB, alice.address);
    const aliceC3 = await ledger.erc20BalanceOf(tokenC, alice.address);
    const alicePP3 = await ppUSDC.balanceOf(alice.address);

    const bobA3 = await ledger.erc20BalanceOf(tokenA, bob.address);
    const bobB3 = await ledger.erc20BalanceOf(tokenB, bob.address);
    const bobC3 = await ledger.erc20BalanceOf(tokenC, bob.address);
    const bobPP3 = await ppUSDC.balanceOf(bob.address);

    const dmmA3 = await ledger.erc20BalanceOf(tokenA, dmm);
    const dmmB3 = await ledger.erc20BalanceOf(tokenB, dmm);
    const dmmC3 = await ledger.erc20BalanceOf(tokenC, dmm);
    const dmmPP3 = await ppUSDC.balanceOf(dmm);

    // Final expectations from the debug run:
    // Alice should have netted out: A=90, no B/C, ppUSDC=920
    expect(aliceA3).to.equal(usdc("90"));
    expect(aliceB3).to.equal(0n);
    expect(aliceC3).to.equal(0n);
    expect(alicePP3).to.equal(usdc("920"));

    // Bob should be flat in positions and keep 991 ppUSDC
    expect(bobA3).to.equal(0n);
    expect(bobB3).to.equal(0n);
    expect(bobC3).to.equal(0n);
    expect(bobPP3).to.equal(usdc("991"));

    // DMM unchanged from step 2
    expect(dmmA3).to.equal(usdc("99910"));
    expect(dmmB3).to.equal(usdc("100000"));
    expect(dmmC3).to.equal(usdc("100000"));
    expect(dmmPP3).to.equal(usdc("89"));

    // Ledger still not holding positions or ppUSDC
    const ledgerA3 = await ledger.erc20BalanceOf(tokenA, ledgerAddr);
    const ledgerB3 = await ledger.erc20BalanceOf(tokenB, ledgerAddr);
    const ledgerC3 = await ledger.erc20BalanceOf(tokenC, ledgerAddr);
    const ledgerPP3 = await ppUSDC.balanceOf(ledgerAddr);

    expect(ledgerA3).to.equal(0n);
    expect(ledgerB3).to.equal(0n);
    expect(ledgerC3).to.equal(0n);
    expect(ledgerPP3).to.equal(0n);

    // Supply sanity: total A tokens should remain 100000
    const totalA = await ledger.erc20TotalSupply(tokenA);
    expect(totalA).to.equal(usdc("100000"));
  });
});
