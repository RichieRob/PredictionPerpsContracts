// test/position.erc20.lay.mirror.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, mintAndDeposit } = require("./helpers/core");
const { setupMarketFixture } = require("./helpers/markets");

//
// MULTI-POSITION EXPANDING MARKET – DEBUG LOGGING
//
describe("Lay PositionERC20 mirrors – buy + transfer (debug logging, expanding market)", function () {
  let fx;
  let other;

  beforeEach(async () => {
    // fx: { owner, trader, usdc, aUSDC, ledger, flatMM, marketId, positionId, ... }
    fx = await setupMarketFixture();

    const signers = await ethers.getSigners();
    other = signers[3];

    const { ledger, owner, marketId } = fx;

    // ensure minimum 3 positions in the fixture market
    let positionIds = await ledger.getMarketPositions(marketId);
    if (positionIds.length < 3) {
      await ledger.connect(owner).createPosition(marketId, "ExtraA", "XA");
      await ledger.connect(owner).createPosition(marketId, "ExtraB", "XB");
      positionIds = await ledger.getMarketPositions(marketId);
    }
    expect(positionIds.length).to.be.gte(3);

    // fund trader on the ledger so they can buy Lay
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: fx.trader,
      amount: usdc("1000"),
    });
  });

  it("prints Lay balance evolution for debugging", async function () {
    const { ledger, trader, owner, marketId, flatMM } = fx;
    const mmAddr = await flatMM.getAddress();
    const accounts = { owner, trader, other };

    const positionIds = await ledger.getMarketPositions(marketId);

    console.log("\n📌 Market positions:", positionIds.join(","));

    const printBalances = async (stage) => {
      console.log(`\n=== ${stage} ===`);
      for (const pid of positionIds) {
        const layAddr = await ledger.getLayPositionERC20(marketId, pid);
        const token = await ethers.getContractAt("PositionERC20", layAddr);

        const bal = {
          owner:  await token.balanceOf(accounts.owner.address),
          trader: await token.balanceOf(accounts.trader.address),
          other:  await token.balanceOf(accounts.other.address),
        };
        const supply = await token.totalSupply();

        console.log(
          `LAY(pid:${pid}) [${layAddr}]\n` +
          `  owner:  ${bal.owner}\n` +
          `  trader: ${bal.trader}\n` +
          `  other:  ${bal.other}\n` +
          `  totalSupply: ${supply}\n`
        );
      }
    };

    // BEFORE BUY
    await printBalances("Before BUY (all zero expected)");

    // BUY LAY on first leg (we'll later detect the active leg by non-zero balance)
    await ledger.connect(trader).buyForppUSDC(
      mmAddr,
      marketId,
      positionIds[0],
      false,     // isBack = false → LAY
      usdc("10"),
      0n
    );

    await printBalances("After BUY lay");

    // detect which leg has lay minted
    let active;
    for (const pid of positionIds) {
      const layAddr = await ledger.getLayPositionERC20(marketId, pid);
      const token = await ethers.getContractAt("PositionERC20", layAddr);
      const bal = await token.balanceOf(trader.address);
      if (bal > 0n) active = { pid, layAddr, token, bal };
    }

    expect(active, "no lay minted on any leg").to.exist;
    console.log(
      `👉 Active Lay position = ${active.pid}   Token=${active.layAddr}`
    );

    // ─────────────────────────────────────────────
    // STEP 2: transfer some Lay to `other`
    // ─────────────────────────────────────────────
    const transferAmount = active.bal / 3n; // arbitrary fraction
    expect(transferAmount).to.be.gt(0n);

    console.log(
      `\n➡️  Transfer amount = ${transferAmount} (1/3 of ${active.bal})`
    );

    await active.token.connect(trader).transfer(other.address, transferAmount);

    // ── Balances after transfer ──
    const traderLayFinal = await active.token.balanceOf(trader.address);
    const otherLayFinal  = await active.token.balanceOf(other.address);

    await printBalances("After TRANSFER lay trader→other");

    console.log(
      `\n📊 Transfer check:
        trader before = ${active.bal}
        sent          = ${transferAmount}
        trader after  = ${traderLayFinal}
        other after   = ${otherLayFinal}
        sum check     = ${traderLayFinal + otherLayFinal} (should equal initial ${active.bal})\n`
    );

    // Mirror consistency
    expect(traderLayFinal + otherLayFinal).to.equal(active.bal);
    expect(otherLayFinal).to.equal(transferAmount);

    console.log("✔ Lay transfer balances verified\n");
  });
});

//
// SINGLE-POSITION EXPANDING MARKET
//
describe("Lay PositionERC20 mirrors – single-position expanding market", function () {
  let fx;
  let other;

  beforeEach(async () => {
    // Reuse the main fixture to get ledger + flatMM wired up.
    // The fixture's own market is expanding; we'll create an additional
    // *separate* expanding market with a single position.
    fx = await setupMarketFixture();

    const signers = await ethers.getSigners();
    other = signers[3];

    const { ledger, trader } = fx;

    // fund trader so they can buy Lay in the new market
    await mintAndDeposit({
      usdc: fx.usdc,
      ledger: fx.ledger,
      trader: trader,
      amount: usdc("1000"),
    });
  });

  it("buys Lay and mirrors + transfers correctly for a 1-position expanding market", async function () {
    const { ledger, owner, trader, flatMM } = fx;
    const mmAddr = await flatMM.getAddress();

    // ─────────────────────────────────────────────
    // STEP 1: create a fresh expanding market with a single position
    // (createMarket sets isExpanding[marketId] = true by design)
    // DMM MUST have ISC so it can write Lay without real deposits.
    // ─────────────────────────────────────────────
    await ledger.connect(owner).allowDMM(mmAddr, true);

    const ISC = usdc("100"); // small synthetic line for the DMM

    await ledger.connect(owner).createMarket(
      "Single Outcome Market",
      "SOM",
      mmAddr,   // DMM
      ISC,      // synthetic collateral (ISC)
      false,    // non-resolving; expanding by default
      ethers.ZeroAddress,
    "0x",
  0,                             // feeBps
  fx.owner.address,              // marketCreator
  [],                            // feeWhitelistAccounts
  false                          // hasWhitelist
);

    const markets = await ledger.getMarkets();
    const singleMarketId = markets[markets.length - 1];

    const [positionId, , layAddr] =
      await ledger.createPosition.staticCall(
        singleMarketId,
        "Only Outcome",
        "ONE"
      );
    await ledger
      .connect(owner)
      .createPosition(singleMarketId, "Only Outcome", "ONE");

    const layToken = await ethers.getContractAt("PositionERC20", layAddr);

    // Helpful logging: initial token state
    const totalSupplyInitial = await layToken.totalSupply();
    const traderInitial      = await layToken.balanceOf(trader.address);
    const otherInitial       = await layToken.balanceOf(other.address);

    console.log(
      `\n📌 Single-position expanding market created:\n` +
      `  marketId  = ${singleMarketId}\n` +
      `  positionId= ${positionId}\n` +
      `  LayToken  = ${layAddr}\n` +
      `  totalSupply(initial) = ${totalSupplyInitial}\n` +
      `  trader(initial)      = ${traderInitial}\n` +
      `  other(initial)       = ${otherInitial}\n`
    );

    // ─────────────────────────────────────────────
    // STEP 2: buy Lay via ledger
    // ─────────────────────────────────────────────
    await ledger.connect(trader).buyForppUSDC(
      mmAddr,
      singleMarketId,
      positionId,
      false,         // isBack = false → LAY
      usdc("10"),
      0n
    );

    const traderLayAfterBuy = await layToken.balanceOf(trader.address);
    const otherLayAfterBuy  = await layToken.balanceOf(other.address);
    const totalSupplyAfterBuy = await layToken.totalSupply();

    console.log(
      `\n💰 After BUY (1-position market):\n` +
      `  totalSupply(after buy) = ${totalSupplyAfterBuy}\n` +
      `  traderLayAfterBuy      = ${traderLayAfterBuy}\n` +
      `  otherLayAfterBuy       = ${otherLayAfterBuy}\n`
    );

    expect(traderLayAfterBuy).to.be.gt(0n);
    expect(otherLayAfterBuy).to.equal(0n);

    // Ledger mirror must match ERC20 (post-buy)
    const traderLayLedger = await ledger.erc20BalanceOf(
      layAddr,
      trader.address
    );
    const otherLayLedger = await ledger.erc20BalanceOf(
      layAddr,
      other.address
    );

    console.log(
      `  ledger.erc20BalanceOf (after buy):\n` +
      `    trader = ${traderLayLedger}\n` +
      `    other  = ${otherLayLedger}\n`
    );

    expect(traderLayLedger).to.equal(traderLayAfterBuy);
    expect(otherLayLedger).to.equal(0n);

    // ─────────────────────────────────────────────
    // STEP 3: transfer some Lay to `other`
    // ─────────────────────────────────────────────
    const transferAmount = traderLayAfterBuy / 2n; // half, arbitrary
    expect(transferAmount).to.be.gt(0n);

    console.log(
      `\n➡️  TRANSFER in 1-position market:\n` +
      `  transferAmount = ${transferAmount} (1/2 of ${traderLayAfterBuy})\n`
    );

    await layToken
      .connect(trader)
      .transfer(other.address, transferAmount);

    const traderLayFinal = await layToken.balanceOf(trader.address);
    const otherLayFinal  = await layToken.balanceOf(other.address);
    const totalSupplyAfterTransfer = await layToken.totalSupply();

    // Ledger mirrors
    const traderLayLedgerFinal = await ledger.erc20BalanceOf(
      layAddr,
      trader.address
    );
    const otherLayLedgerFinal = await ledger.erc20BalanceOf(
      layAddr,
      other.address
    );

    console.log(
      `\n📊 After TRANSFER (1-position market):\n` +
      `  totalSupply(after transfer) = ${totalSupplyAfterTransfer}\n` +
      `  traderLayFinal              = ${traderLayFinal}\n` +
      `  otherLayFinal               = ${otherLayFinal}\n` +
      `  ledger.erc20BalanceOf final:\n` +
      `    trader = ${traderLayLedgerFinal}\n` +
      `    other  = ${otherLayLedgerFinal}\n` +
      `  conservation (trader+other) = ${traderLayFinal + otherLayFinal} (should equal ${traderLayAfterBuy})\n`
    );

    // ERC20 vs ledger mirrors
    expect(traderLayFinal).to.equal(traderLayLedgerFinal);
    expect(otherLayFinal).to.equal(otherLayLedgerFinal);

    // Conservation between trader and other
    expect(traderLayFinal + otherLayFinal).to.equal(traderLayAfterBuy);
    expect(otherLayFinal).to.equal(transferAmount);

    // totalSupply should stay constant across a pure ERC20 transfer
    expect(totalSupplyAfterTransfer).to.equal(totalSupplyAfterBuy);

    console.log(
      `\n✔ Single-position expanding Lay mirror OK:\n` +
      `   trader=${traderLayFinal}, other=${otherLayFinal},\n` +
      `   supply(before transfer)=${totalSupplyAfterBuy},` +
      ` supply(after transfer)=${totalSupplyAfterTransfer}\n`
    );
  });
});
