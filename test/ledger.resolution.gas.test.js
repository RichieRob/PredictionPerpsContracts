// test/ledger.resolution.gas.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc } = require("./helpers/core");
const { gasOf } = require("./helpers/markets.gas");
const {
  setupResolvingMarketsGasFixture,
  resolveMarketsViaOracle,
} = require("./helpers/resolution.gas");

const U = (n) => usdc(String(n));

describe("MarketMakerLedger – resolution / claim gas profile", function () {
  this.timeout(120_000);

  // ───────────────────────────────────────────────
  // Small helper: create a *warm* non-resolving
  // probe market for gas measurement.
  // Returns { dmmAddr, probeMarketId, probePosId }.
  // ───────────────────────────────────────────────
  async function setupWarmProbeMarket({ ledger, trader, owner, label }) {
    const Flat = await ethers.getContractFactory("FlatMockMarketMaker");
    const dmm = await Flat.deploy();
    await dmm.waitForDeployment();
    const dmmAddr = await dmm.getAddress();

    await ledger.connect(owner).allowDMM(dmmAddr, true);

    await ledger
      .connect(owner)
      .createMarket(
        `Probe Market – ${label}`,
        `PRB${label}`,
        dmmAddr,
        U(100_000),           // ISC
        false,                // doesResolve = false
        ethers.ZeroAddress,   // oracle
        "0x",                 // oracleParams
        0,                    // feeBps
        owner.address,        // marketCreator
        [],                   // feeWhitelistAccounts
        false                 // hasWhitelist
      );

    const allMarkets = await ledger.getMarkets();
    const probeMarketId = allMarkets[allMarkets.length - 1];

    await ledger.connect(owner).createPosition(probeMarketId, "YES", "Y");
    const [probePosId] = await ledger.getMarketPositions(probeMarketId);

    // 🔥 Warm-up trade (not measured)
    await ledger.connect(trader).buyExactTokens(
      dmmAddr,
      probeMarketId,
      probePosId,
      true,         // isBack
      U(1),
      U(1_000)
    );

    return { dmmAddr, probeMarketId, probePosId };
  }

  // ───────────────────────────────────────────────
  // Helper: background resolved market that the
  // user is *not* in, to force a scan even when
  // none of the user's markets are resolved.
  // ───────────────────────────────────────────────
  async function createBackgroundResolvedMarket({ ledger, oracle, owner, label }) {
    const oracleAddr = await oracle.getAddress();

    await ledger
      .connect(owner)
      .createMarket(
        `BG Market – ${label}`,
        `BG${label}`,
        ethers.ZeroAddress,  // no DMM
        0n,
        true,                // doesResolve = true
        oracleAddr,
        "0x",
        0,                   // feeBps
        owner.address,       // marketCreator
        [],                  // feeWhitelistAccounts
        false                // hasWhitelist
      );

    const all = await ledger.getMarkets();
    const bgMarketId = all[all.length - 1];

    await ledger.connect(owner).createPosition(bgMarketId, "YES", "Y");
    const [bgPosId] = await ledger.getMarketPositions(bgMarketId);

    await oracle.pushResolution(bgMarketId, bgPosId);
    await ledger.resolveMarket(bgMarketId);

    return bgMarketId;
  }

  // ───────────────────────────────────────────────
  // 1) Overhead with many UNRESOLVED markets
  // ───────────────────────────────────────────────

  it("has small overhead when scanning unresolved markets (applyPendingWinnings short-circuits)", async () => {
    const N_MARKETS = 50;

    const { fx, oracle } = await setupResolvingMarketsGasFixture({
      nMarkets: N_MARKETS,
      buySizeUSDC: "5",
    });

    const { ledger, trader, owner } = fx;

    // Force totalResolvedMarkets > 0 via a background market
    await createBackgroundResolvedMarket({
      ledger,
      oracle,
      owner,
      label: `UNRES_BG_${N_MARKETS}`,
    });

    const { dmmAddr, probeMarketId, probePosId } =
      await setupWarmProbeMarket({
        ledger,
        trader,
        owner,
        label: `UNRES_${N_MARKETS}`,
      });

    // Measured trade on a WARM market
    const gas = await gasOf(
      ledger.connect(trader).buyExactTokens(
        dmmAddr,
        probeMarketId,
        probePosId,
        true,         // isBack
        U(10),
        U(1_000)
      )
    );

    console.log(
      `\n[UNRESOLVED] gas for buyExactTokens with ${N_MARKETS} unresolved resolving markets on user (warm PROBE): ${gas}`
    );

    expect(gas).to.be.lessThan(500_000);
  });

  // ───────────────────────────────────────────────
  // 2) 100 resolved markets, 20 winners
  // ───────────────────────────────────────────────

  it("profiles gas when ~20/100 resolved markets are claimed inline with a trade (warm market)", async () => {
    const N_MARKETS = 100;
    const N_WINNERS = 20;

    const ctx = await setupResolvingMarketsGasFixture({
      nMarkets: N_MARKETS,
      buySizeUSDC: "10",
    });

    const { fx } = ctx;
    const { ledger, trader, owner } = fx;

    // Prepare warm PROBE2 before resolution
    const { dmmAddr, probeMarketId, probePosId } =
      await setupWarmProbeMarket({
        ledger,
        trader,
        owner,
        label: "BASE_100",
      });

    // Resolve all 100:
    await resolveMarketsViaOracle(ctx, {
      winnersPredicate: (i, m) => (i < N_WINNERS ? m.posYes : m.posNo),
    });

    const effBefore = await ledger.effectiveFreeCollateral(trader.address);

    const gas = await gasOf(
      ledger.connect(trader).buyExactTokens(
        dmmAddr,
        probeMarketId,
        probePosId,
        true,         // isBack
        U(1),
        U(1_000)
      )
    );

    const effAfter = await ledger.effectiveFreeCollateral(trader.address);
    const deltaEff = effBefore - effAfter;

    console.log(
      `\n[RESOLVED] gas for buyExactTokens in PROBE2 (warm) that also claims across ${N_MARKETS} resolved markets (${N_WINNERS} winners): ${gas}`
    );
    console.log(
      `[RESOLVED] effectiveFreeCollateral delta (effBefore - effAfter): ${deltaEff.toString()}`
    );

    // Loose upper bound
    expect(gas).to.be.lessThan(3_500_000);
  });

  // ───────────────────────────────────────────────
  // 3) Generic scenario helper
  // ───────────────────────────────────────────────

  async function runResolutionGasScenario({
    label,
    totalMarkets,
    resolvedMarkets,
    winningMarkets,
    buySizeUSDC = "10",
  }) {
    if (resolvedMarkets > totalMarkets) {
      throw new Error("resolvedMarkets > totalMarkets");
    }
    if (winningMarkets > resolvedMarkets) {
      throw new Error("winningMarkets > resolvedMarkets");
    }

    const ctx = await setupResolvingMarketsGasFixture({
      nMarkets: totalMarkets,
      buySizeUSDC,
    });

    const { fx, markets, oracle } = ctx;
    const { ledger, trader, owner } = fx;

    // Warm probe market for this scenario
    const { dmmAddr, probeMarketId, probePosId } =
      await setupWarmProbeMarket({
        ledger,
        trader,
        owner,
        label,
      });

    // Partially resolve: first `resolvedMarkets` only
    for (let i = 0; i < resolvedMarkets; i++) {
      const m = markets[i];

      const winningPos =
        i < winningMarkets ? m.posYes : m.posNo;

      await oracle.pushResolution(m.marketId, winningPos);
      await ledger.resolveMarket(m.marketId);
    }

    // Ensure at least one resolved market exists globally
    if (resolvedMarkets === 0) {
      await createBackgroundResolvedMarket({
        ledger,
        oracle,
        owner,
        label: `BG_${label}`,
      });
    }

    const gas = await gasOf(
      ledger.connect(trader).buyExactTokens(
        dmmAddr,
        probeMarketId,
        probePosId,
        true,         // isBack
        U(1),
        U(1_000)
      )
    );

    console.log(
      `[SCENARIO ${label}] total=${totalMarkets}, resolved=${resolvedMarkets}, winners=${winningMarkets}, gas=${gas}`
    );

    return gas;
  }

  // ───────────────────────────────────────────────
  // 4) Multi-scenario sweep
  // ───────────────────────────────────────────────

  it("profiles multiple (#markets, #resolved, #winners) scenarios on warm markets", async () => {
    const SCENARIOS = [
      { label: "M0_R0_W0",   total: 0,   resolved: 0,   winners: 0 },
      { label: "M10_R0_W0",  total: 10,  resolved: 0,   winners: 0 },
      { label: "M10_R10_W2", total: 10,  resolved: 10,  winners: 2 },
      { label: "M10_R2_W2",  total: 10,  resolved: 2,   winners: 2 },
      { label: "M20_R10_W3", total: 20,  resolved: 10,  winners: 3 },
      { label: "M50_R25_W10", total: 50, resolved: 25,  winners: 10 },
      { label: "M50_R1_W1",  total: 50,  resolved: 1,   winners: 1 },
      { label: "M50_R0_W0",  total: 50,  resolved: 0,   winners: 0 },
      { label: "M100_R100_W20", total: 100, resolved: 100, winners: 20 },
    ]

    for (const s of SCENARIOS) {
      const gas = await runResolutionGasScenario({
        label: s.label,
        totalMarkets: s.total,
        resolvedMarkets: s.resolved,
        winningMarkets: s.winners,
      });

      expect(gas).to.be.lessThan(4_000_000);
    }
  });
});
