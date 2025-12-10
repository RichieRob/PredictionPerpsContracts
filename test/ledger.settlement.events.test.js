// test/ledger.settlement.events.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  usdc,
  deployCore,
  mintAndDeposit,
} = require("./helpers/core");
const { setupMarketFixture } = require("./helpers/markets");

// -----------------------------------------------------------------------------
// Shared helper: compute delta for one account from Transfer logs
// -----------------------------------------------------------------------------

async function computeDeltaFromTransferEvents(contract, receipt, account) {
  const iface = contract.interface;
  const transferEvent = iface.getEvent("Transfer");
  const transferTopic = transferEvent.topicHash;

  let delta = 0n;

  for (const log of receipt.logs) {
    if (log.address !== (await contract.getAddress())) continue;
    if (log.topics[0] !== transferTopic) continue;

    const parsed = iface.parseLog(log);
    const from = parsed.args.from;
    const to = parsed.args.to;
    const value = parsed.args.value;

    if (from === ethers.ZeroAddress && to === account) {
      // Mint to account
      delta += value;
    } else if (from === account && to === ethers.ZeroAddress) {
      // Burn from account
      delta -= value;
    }
  }

  return delta;
}

// -----------------------------------------------------------------------------
// 1) Single-position sanity tests (what you already ran)
// -----------------------------------------------------------------------------

describe("MarketMakerLedger – SettlementLib event correctness (single position)", function () {
  let fx;
  let backToken;
  let layToken;

  beforeEach(async () => {
    fx = await setupMarketFixture();

    // backToken is captured as fx.positionToken in the fixture
    backToken = await ethers.getContractAt("PositionERC20", fx.positionToken);

    // Lay token via view
    const layAddr = await fx.ledger.getLayPositionERC20(
      fx.marketId,
      fx.positionId
    );
    layToken = await ethers.getContractAt("PositionERC20", layAddr);
  });

  it("BACK buy: events match ledger balance deltas for trader", async () => {
    const {
      ledger,
      trader,
      flatMM,
      ppUSDC,
      marketId,
      positionId,
      usdc: usdcToken,
    } = fx;

    const TRADER_DEPOSIT = usdc("1000");
    const TOKENS_TO_BUY  = usdc("10");
    const MAX_USDC_IN    = usdc("1000");

    // 1) Deposit for trader
    await usdcToken.mint(trader.address, TRADER_DEPOSIT);
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), TRADER_DEPOSIT);

    const EMPTY_PERMIT = {
      value: 0n,
      deadline: 0n,
      v: 0,
      r: "0x" + "0".repeat(64),
      s: "0x" + "0".repeat(64),
    };

    await ledger.connect(trader).deposit(
      trader.address,
      TRADER_DEPOSIT,
      0n, // minUSDCDeposited
      0,  // mode = allowance
      EMPTY_PERMIT
    );

    // 2) Snapshot balances BEFORE trade
    const traderAddr = trader.address;
    const backAddr   = await backToken.getAddress();
    const layAddr    = await layToken.getAddress();
    const ppAddr     = await ppUSDC.getAddress();

    const backBefore = await ledger.erc20BalanceOf(backAddr, traderAddr);
    const layBefore  = await ledger.erc20BalanceOf(layAddr, traderAddr);
    const ppBefore   = await ppUSDC.balanceOf(traderAddr);

    // 3) Execute BACK buy vs flat MM
    const tx = await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,           // isBack
      TOKENS_TO_BUY,
      MAX_USDC_IN
    );
    const receipt = await tx.wait();

    // 4) Snapshot balances AFTER trade
    const backAfter = await ledger.erc20BalanceOf(backAddr, traderAddr);
    const layAfter  = await ledger.erc20BalanceOf(layAddr, traderAddr);
    const ppAfter   = await ppUSDC.balanceOf(traderAddr);

    const expectedBackDelta = backAfter - backBefore;
    const expectedLayDelta  = layAfter  - layBefore;
    const expectedPpDelta   = ppAfter   - ppBefore;

    // 5) Compute actual deltas from events
    const backDeltaFromEvents = await computeDeltaFromTransferEvents(
      backToken,
      receipt,
      traderAddr
    );
    const layDeltaFromEvents = await computeDeltaFromTransferEvents(
      layToken,
      receipt,
      traderAddr
    );
    const ppToken = await ethers.getContractAt("PpUSDC", ppAddr);
    const ppDeltaFromEvents = await computeDeltaFromTransferEvents(
      ppToken,
      receipt,
      traderAddr
    );

    console.log("=== BACK BUY – trader deltas ===");
    console.log(
      "Back expected vs events:",
      expectedBackDelta.toString(),
      backDeltaFromEvents.toString()
    );
    console.log(
      "Lay expected vs events:",
      expectedLayDelta.toString(),
      layDeltaFromEvents.toString()
    );
    console.log(
      "ppUSDC expected vs events:",
      expectedPpDelta.toString(),
      ppDeltaFromEvents.toString()
    );

    expect(backDeltaFromEvents).to.equal(expectedBackDelta);
    expect(layDeltaFromEvents).to.equal(expectedLayDelta);
    expect(ppDeltaFromEvents).to.equal(expectedPpDelta);
  });

  it("PositionERC20 transfer: events match ledger balance deltas for recipient", async () => {
    const {
      ledger,
      trader,
      other,
      flatMM,
      ppUSDC,
      marketId,
      positionId,
      usdc: usdcToken,
    } = fx;

    const TRADER_DEPOSIT  = usdc("1000");
    const TOKENS_TO_BUY   = usdc("10");
    const MAX_USDC_IN     = usdc("1000");
    const TRANSFER_AMOUNT = usdc("3");

    const traderAddr = trader.address;
    const otherAddr  = other.address;
    const backAddr   = await backToken.getAddress();
    const layAddr    = await layToken.getAddress();
    const ppAddr     = await ppUSDC.getAddress();

    const EMPTY_PERMIT = {
      value: 0n,
      deadline: 0n,
      v: 0,
      r: "0x" + "0".repeat(64),
      s: "0x" + "0".repeat(64),
    };

    // 1) Deposit + buy so trader owns some BACK tokens
    await usdcToken.mint(traderAddr, TRADER_DEPOSIT);
    await usdcToken
      .connect(trader)
      .approve(await ledger.getAddress(), TRADER_DEPOSIT);

    await ledger.connect(trader).deposit(
      traderAddr,
      TRADER_DEPOSIT,
      0n,
      0,
      EMPTY_PERMIT
    );

    await ledger.connect(trader).buyExactTokens(
      await flatMM.getAddress(),
      marketId,
      positionId,
      true,           // isBack
      TOKENS_TO_BUY,
      MAX_USDC_IN
    );

    // 2) Snapshot balances for RECIPIENT (other) BEFORE transfer
    const backBeforeOther = await ledger.erc20BalanceOf(backAddr, otherAddr);
    const layBeforeOther  = await ledger.erc20BalanceOf(layAddr, otherAddr);
    const ppBeforeOther   = await ppUSDC.balanceOf(otherAddr);

    // 3) Do PositionERC20 (BACK) transfer from trader -> other
    const tx = await backToken.connect(trader).transfer(
      otherAddr,
      TRANSFER_AMOUNT
    );
    const receipt = await tx.wait();

    // 4) Snapshot balances AFTER transfer
    const backAfterOther = await ledger.erc20BalanceOf(backAddr, otherAddr);
    const layAfterOther  = await ledger.erc20BalanceOf(layAddr, otherAddr);
    const ppAfterOther   = await ppUSDC.balanceOf(otherAddr);

    const expectedBackDelta = backAfterOther - backBeforeOther;
    const expectedLayDelta  = layAfterOther  - layBeforeOther;
    const expectedPpDelta   = ppAfterOther   - ppBeforeOther;

    // 5) Actual deltas from events (for recipient)
    const backDeltaFromEvents = await computeDeltaFromTransferEvents(
      backToken,
      receipt,
      otherAddr
    );
    const layDeltaFromEvents = await computeDeltaFromTransferEvents(
      layToken,
      receipt,
      otherAddr
    );
    const ppToken = await ethers.getContractAt("PpUSDC", ppAddr);
    const ppDeltaFromEvents = await computeDeltaFromTransferEvents(
      ppToken,
      receipt,
      otherAddr
    );

    console.log("=== ERC20 TRANSFER – recipient deltas ===");
    console.log(
      "Back expected vs events:",
      expectedBackDelta.toString(),
      backDeltaFromEvents.toString()
    );
    console.log(
      "Lay expected vs events:",
      expectedLayDelta.toString(),
      layDeltaFromEvents.toString()
    );
    console.log(
      "ppUSDC expected vs events:",
      expectedPpDelta.toString(),
      ppDeltaFromEvents.toString()
    );

    expect(backDeltaFromEvents).to.equal(expectedBackDelta);
    expect(layDeltaFromEvents).to.equal(expectedLayDelta);
    expect(ppDeltaFromEvents).to.equal(expectedPpDelta);

    // For a pure position transfer, ppUSDC should not move for recipient
    expect(expectedPpDelta).to.equal(0n);
  });
});

// -----------------------------------------------------------------------------
// 2) Multi-position hammer: 3 positions, 30 mixed BACK/LAY trades
// -----------------------------------------------------------------------------

async function setupMultiPositionFixture() {
  const fx = await deployCore();
  const { ledger } = fx;

  // Flat MM
  const FlatMockMarketMaker = await ethers.getContractFactory(
    "FlatMockMarketMaker"
  );
  const flatMM = await FlatMockMarketMaker.deploy();
  await flatMM.waitForDeployment();
  fx.flatMM = flatMM;

  await ledger.allowDMM(await flatMM.getAddress(), true);

  // Create a non-resolving market with ISC
  const iscAmount = usdc("100000");
  await ledger.createMarket(
    "MultiPos Market",
    "MP",
    await flatMM.getAddress(),
    iscAmount,
    false,
    ethers.ZeroAddress,
  "0x",
  0,                             // feeBps
  fx.owner.address,              // marketCreator
  [],                            // feeWhitelistAccounts
  false                          // hasWhitelist
);
  const markets = await ledger.getMarkets();
  const marketId = markets[0];
  fx.marketId = marketId;

  // Create 3 positions (YES1/2/3)
  const positionsMeta = [
    { name: "YES-0", ticker: "Y0" },
    { name: "YES-1", ticker: "Y1" },
    { name: "YES-2", ticker: "Y2" },
  ];

  const [positionIds, backTokens, layTokens] =
    await ledger.createPositions.staticCall(marketId, positionsMeta);
  await ledger.createPositions(marketId, positionsMeta);

  fx.positionIds = positionIds;

  fx.backTokens = await Promise.all(
    backTokens.map((addr) =>
      ethers.getContractAt("PositionERC20", addr)
    )
  );
  fx.layTokens = await Promise.all(
    layTokens.map((addr) =>
      ethers.getContractAt("PositionERC20", addr)
    )
  );

  return fx;
}

describe("MarketMakerLedger – SettlementLib event correctness (multi-position hammer)", function () {
  it("30 mixed BACK/LAY trades across 3 positions keep events == ledger deltas", async () => {
    const fx = await setupMultiPositionFixture();
    const {
      ledger,
      trader,
      flatMM,
      ppUSDC,
      usdc: usdcToken,
      marketId,
      positionIds,
      backTokens,
      layTokens,
    } = fx;

    const traderAddr = trader.address;

    // Big deposit so we never hit collateral limits in this test
    const DEPOSIT = usdc("50000");

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: DEPOSIT,
    });

    const MAX_USDC_IN = usdc("1000000");

    // Build 30 deterministic trades, mixing:
    // - positions 0,1,2
    // - BACK and LAY
    // - varying sizes, with some over / under so exposure grows, shrinks, reverses
    const TRADES = [];
    for (let i = 0; i < 30; i++) {
      const posIdx = i % 3;              // 0,1,2
      const isBack = (i % 4) < 2;        // BB LL BB LL pattern (so reversals happen)
      const sizeBase = 2 + (i % 5);      // 2..6
      const size = usdc(sizeBase);       // 2,3,4,5,6 in a cycle

      TRADES.push({ posIdx, isBack, size });
    }

    for (let i = 0; i < TRADES.length; i++) {
      const { posIdx, isBack, size } = TRADES[i];

      const posId     = positionIds[posIdx];
      const backToken = backTokens[posIdx];
      const layToken  = layTokens[posIdx];

      const backAddr = await backToken.getAddress();
      const layAddr  = await layToken.getAddress();
      const ppAddr   = await ppUSDC.getAddress();

      // Snapshot BEFORE
      const backBefore = await ledger.erc20BalanceOf(backAddr, traderAddr);
      const layBefore  = await ledger.erc20BalanceOf(layAddr, traderAddr);
      const ppBefore   = await ppUSDC.balanceOf(traderAddr);

      // Trade
      const tx = await ledger.connect(trader).buyExactTokens(
        await flatMM.getAddress(),
        marketId,
        posId,
        isBack,
        size,
        MAX_USDC_IN
      );
      const receipt = await tx.wait();

      // Snapshot AFTER
      const backAfter = await ledger.erc20BalanceOf(backAddr, traderAddr);
      const layAfter  = await ledger.erc20BalanceOf(layAddr, traderAddr);
      const ppAfter   = await ppUSDC.balanceOf(traderAddr);

      const expectedBackDelta = backAfter - backBefore;
      const expectedLayDelta  = layAfter  - layBefore;
      const expectedPpDelta   = ppAfter   - ppBefore;

      // Deltas from events
      const backDeltaFromEvents = await computeDeltaFromTransferEvents(
        backToken,
        receipt,
        traderAddr
      );
      const layDeltaFromEvents = await computeDeltaFromTransferEvents(
        layToken,
        receipt,
        traderAddr
      );
      const ppToken = await ethers.getContractAt("PpUSDC", ppAddr);
      const ppDeltaFromEvents = await computeDeltaFromTransferEvents(
        ppToken,
        receipt,
        traderAddr
      );

      console.log(
        `=== TRADE #${i} – pos=${posIdx}, isBack=${isBack}, size=${size.toString()} ===`
      );
      console.log(
        "Back expected vs events:",
        expectedBackDelta.toString(),
        backDeltaFromEvents.toString()
      );
      console.log(
        "Lay expected vs events:",
        expectedLayDelta.toString(),
        layDeltaFromEvents.toString()
      );
      console.log(
        "ppUSDC expected vs events:",
        expectedPpDelta.toString(),
        ppDeltaFromEvents.toString()
      );

      expect(backDeltaFromEvents).to.equal(expectedBackDelta);
      expect(layDeltaFromEvents).to.equal(expectedLayDelta);
      expect(ppDeltaFromEvents).to.equal(expectedPpDelta);
    }
  });
});
