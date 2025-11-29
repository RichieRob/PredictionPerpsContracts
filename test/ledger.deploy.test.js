// test/ledger.deployment.basic-deposit.test.js
const { expect } = require("chai");
const {
  usdc,
  deployCore,
  EMPTY_PERMIT,
} = require("./helpers/core");
const {
  expectDepositMirrorsEverything,
  withdrawAndCheckFlat,
} = require("./helpers/deposits");

describe("MarketMakerLedger – deployment & basic deposit", () => {
  let fx; // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }

  beforeEach(async () => {
    fx = await deployCore();
  });

  it("wires mocks & ppUSDC correctly", async () => {
    const { ledger, ppUSDC } = fx;

    expect(await ppUSDC.ledger()).to.equal(await ledger.getAddress());
    expect(await ledger.getTotalValueLocked()).to.equal(0n);
    expect(await ledger.realTotalFreeCollateral()).to.equal(0n);
  });

  it("allows a user to deposit USDC and updates TVL / ppUSDC mirror", async () => {
    const {
      trader: user,
      usdc: usdcToken,
      aUSDC,
      aavePool,
      ppUSDC,
      ledger,
    } = fx;

    const amount = usdc("1000"); // 1,000 USDC

    // Mint + deposit (inline here so we can assert the event)
    await usdcToken.mint(user.address, amount);
    await usdcToken
      .connect(user)
      .approve(await ledger.getAddress(), amount);

    await expect(
      ledger
        .connect(user)
        .deposit(
          user.address,
          amount,
          0n,           // minUSDCDeposited
          0,            // mode = allowance
          EMPTY_PERMIT,
          "0x"
        )
    ).to.emit(ledger, "Deposited");

    // One helper checks all the mirrors and flows
    await expectDepositMirrorsEverything({
      ledger,
      aUSDC,
      ppUSDC,
      usdcToken,
      aavePool,
      account: user,
      amount,
    });
  });

  it("allows a user to withdraw back to wallet", async () => {
    await withdrawAndCheckFlat(fx, {
      account: fx.trader,
      depositAmount: usdc("500"),
      withdrawAmount: usdc("200"),
    });
  });
});
