const { expect } = require("chai");
const { ethers } = require("hardhat");

const { deployCore, usdc, mintAndDeposit } = require("./helpers/core");
const {
  recordGasWithFirstIgnoreRevert,
  printGasStats,
} = require("./helpers/markets.gas");

const U = (n) => usdc(String(n)); // 6dp helper

describe("MarketMakerLedger – resolving vs non-resolving trade gas (25 positions)", function () {
  it("compares gas for buys in resolving vs non-resolving 25-position markets", async function () {
    // ──────────────────────────────────────
    // Core + signers
    // ──────────────────────────────────────
    const fx = await deployCore();
    const { owner, trader, ledger, usdc: usdcToken, ppUSDC } = fx;

    const signers = await ethers.getSigners();
    const trader1 = trader;          // from deployCore
    const trader2 = signers[2];
    const trader3 = signers[3];
    const traders = [trader1, trader2, trader3];

    // ──────────────────────────────────────
    // LMSR DMM wired to ledger
    // ──────────────────────────────────────
    const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
    const lmsr = await LMSR.deploy(
      owner.address,              // governor
      await ledger.getAddress()   // ILedgerPositions / ledger
    );
    await lmsr.waitForDeployment();
    const lmsrAddr = await lmsr.getAddress();

    // Allow LMSR as DMM for non-resolving markets
    await ledger.connect(owner).allowDMM(lmsrAddr, true);

    const N_POS = 25;
    const equalR = 1 / N_POS;
    const liabilityUSDC = usdc("1000");

    // ──────────────────────────────────────
    // 1) Non-resolving LMSR market (ISC-backed) with 25 positions
    // ──────────────────────────────────────

    const iscAmountNonRes = usdc("100000"); // 100k synthetic line

    {
      const tx = await ledger.createMarket(
        "NonResolving LMSR 25",
        "NR25",
        lmsrAddr,             // DMM = LMSR
        iscAmountNonRes,      // ISC line
        false,                // doesResolve = false
        ethers.ZeroAddress,   // oracle
        "0x"                  // oracleParams
      );
      await tx.wait();
    }

    let markets = await ledger.getMarkets();
    expect(markets.length).to.equal(1);
    const nonResMarketId = markets[0];

    const nonResPositionsMeta = [];
    for (let i = 0; i < N_POS; i++) {
      nonResPositionsMeta.push({
        name:   `NonRes Pos ${i}`,
        ticker: `NR${i}`,
      });
    }

    {
      const tx = await ledger.createPositions(nonResMarketId, nonResPositionsMeta);
      await tx.wait();
    }

    const nonResPosIds = await ledger.getMarketPositions(nonResMarketId);
    expect(nonResPosIds.length).to.equal(N_POS);

    const nonResPriors = nonResPosIds.map((pid) => ({
      positionId: pid,
      r: ethers.parseEther(equalR.toString()),
    }));

    {
      const tx = await lmsr
        .connect(owner)
        .initMarket(
          nonResMarketId,
          nonResPriors,
          liabilityUSDC,
          0,      // reserve0
          false   // isExpanding
        );
      await tx.wait();
    }

    // ──────────────────────────────────────
    // 2) Resolving LMSR market (no DMM, no ISC, uses LMSR) with 25 positions
    // ──────────────────────────────────────

    const MockOracle = await ethers.getContractFactory("MockOracle");
    const oracle = await MockOracle.deploy();
    await oracle.waitForDeployment();
    const oracleAddr = await oracle.getAddress();

    // NOTE: must satisfy your MarketManagementLib invariants:
    //   - dmm == 0
    //   - iscAmount == 0
    //   - doesResolve == true
    //   - oracle != 0
    {
      const tx = await ledger.createMarket(
        "Resolving LMSR 25",
        "R25",
        ethers.ZeroAddress,   // dmm = 0
        0n,                   // no ISC
        true,                 // doesResolve = true
        oracleAddr,           // oracle required
        "0x"
      );
      await tx.wait();
    }

    markets = await ledger.getMarkets();
    expect(markets.length).to.equal(2);
    const resolvingMarketId = markets[1];

    const resolvingPositionsMeta = [];
    for (let i = 0; i < N_POS; i++) {
      resolvingPositionsMeta.push({
        name:   `Resolving Pos ${i}`,
        ticker: `R${i}`,
      });
    }

    {
      const tx = await ledger.createPositions(resolvingMarketId, resolvingPositionsMeta);
      await tx.wait();
    }

    const resolvingPosIds = await ledger.getMarketPositions(resolvingMarketId);
    expect(resolvingPosIds.length).to.equal(N_POS);

    // 🔴 IMPORTANT: resolving market ALSO uses LMSR
    const resolvingPriors = resolvingPosIds.map((pid) => ({
      positionId: pid,
      r: ethers.parseEther(equalR.toString()),
    }));

    {
      const tx = await lmsr
        .connect(owner)
        .initMarket(
          resolvingMarketId,
          resolvingPriors,
          liabilityUSDC,
          0,
          false
        );
      await tx.wait();
    }

    // ──────────────────────────────────────
    // 3) FUND LMSR with 100,000 ppUSDC (real liquidity)
    // ──────────────────────────────────────

    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: owner,
      amount: U(100_000),
    });

    await ppUSDC.connect(owner).transfer(lmsrAddr, U(100_000));

    const lmsrFree = await ledger.realFreeCollateral(lmsrAddr);
    expect(lmsrFree).to.be.greaterThan(0n);

    // ──────────────────────────────────────
    // 4) Trader deposits (so they have ppUSDC to trade with)
    // ──────────────────────────────────────

    for (const t of traders) {
      await mintAndDeposit({
        usdc: usdcToken,
        ledger,
        trader: t,
        amount: U(50_000),
      });
    }

    // ──────────────────────────────────────
    // 5) Trade gas hammer – resolving vs non-resolving
    // ──────────────────────────────────────

    const stats = {};
    const firstSeen = {};
    const N_BUYS = 5;
    const SAMPLE_POS = 10; // sample subset to keep runtime sane

    const nonResSamplePos = nonResPosIds.slice(0, SAMPLE_POS);
    const resSamplePos    = resolvingPosIds.slice(0, SAMPLE_POS);

    const marketsUnderTest = [
      {
        labelPrefix: "nonResolving",
        marketId:    nonResMarketId,
        mm:          lmsrAddr,   // LMSR + ISC
      },
      {
        labelPrefix: "resolving",
        marketId:    resolvingMarketId,
        mm:          lmsrAddr,   // LMSR + redeeming path
      },
    ];

    for (const user of traders) {
      for (const m of marketsUnderTest) {
        const { labelPrefix, marketId, mm } = m;

        const posIds =
          marketId === nonResMarketId ? nonResSamplePos : resSamplePos;

        for (const positionId of posIds) {
          for (const isBack of [true, false]) {
            const sideLabel = isBack ? "BACK" : "LAY";
            const baseLabel = `${labelPrefix}_${sideLabel}`;

            const comboKey = [
              user.address,
              marketId.toString(),
              positionId.toString(),
              baseLabel,
            ].join(":");

            // buyExactTokens – ignore reverts for hammering
            for (let i = 0; i < N_BUYS; i++) {
              await recordGasWithFirstIgnoreRevert(
                stats,
                firstSeen,
                `buyExactTokens_${baseLabel}`,
                comboKey,
                ledger
                  .connect(user)
                  .buyExactTokens(
                    mm,
                    marketId,
                    positionId,
                    isBack,
                    U(50),
                    U(1_000)
                  )
              );
            }

            // buyForppUSDC – ignore reverts for hammering
            for (let i = 0; i < N_BUYS; i++) {
              await recordGasWithFirstIgnoreRevert(
                stats,
                firstSeen,
                `buyForppUSDC_${baseLabel}`,
                comboKey,
                ledger
                  .connect(user)
                  .buyForppUSDC(
                    mm,
                    marketId,
                    positionId,
                    isBack,
                    U(100),
                    0n
                  )
              );
            }
          }
        }
      }
    }

    printGasStats(
      stats,
      "resolving vs non-resolving (25 positions; LMSR+ISC vs LMSR+redeeming)"
    );

    // Sanity: trader free collateral must not go negative
    const finalFree = await ledger.realFreeCollateral(trader1.address);
    if (finalFree < 0n) {
      throw new Error("finalFree collateral went negative");
    }

    await ppUSDC.balanceOf(trader1.address); // keep lints happy
  });
  it("debug: single non-resolving BACK buy", async function () {
    const fx = await deployCore();
    const { owner, trader, ledger, usdc: usdcToken, ppUSDC } = fx;
  
    // --- Deploy LMSR and wire to ledger ---
    const LMSR = await ethers.getContractFactory("LMSRMarketMaker");
    const lmsr = await LMSR.deploy(
      owner.address,              // governor
      await ledger.getAddress()   // ledger
    );
    await lmsr.waitForDeployment();
    const lmsrAddr = await lmsr.getAddress();
  
    await ledger.connect(owner).allowDMM(lmsrAddr, true);
  
    const N_POS = 25;
    const equalR = 1 / N_POS;
    const liabilityUSDC = usdc("1000");
    const iscAmountNonRes = usdc("100000");
  
    // --- Create non-resolving market with ISC-backed LMSR DMM ---
    {
      const tx = await ledger.createMarket(
        "NonResolving LMSR 25",
        "NR25",
        lmsrAddr,           // dmm
        iscAmountNonRes,    // synthetic line
        false,              // doesResolve = false
        ethers.ZeroAddress, // oracle
        "0x"
      );
      await tx.wait();
    }
  
    const markets = await ledger.getMarkets();
    const nonResMarketId = markets[0];
  
    // --- Positions ---
    const meta = [];
    for (let i = 0; i < N_POS; i++) {
      meta.push({ name: `NR Pos ${i}`, ticker: `NR${i}` });
    }
    {
      const tx = await ledger.createPositions(nonResMarketId, meta);
      await tx.wait();
    }
  
    const posIds = await ledger.getMarketPositions(nonResMarketId);
  
    // --- Init LMSR for this market ---
    const priors = posIds.map((pid) => ({
      positionId: pid,
      r: ethers.parseEther(equalR.toString()),
    }));
  
    {
      const tx = await lmsr
        .connect(owner)
        .initMarket(
          nonResMarketId,
          priors,
          liabilityUSDC,
          0,      // reserve0
          false   // isExpanding
        );
      await tx.wait();
    }
  
    // --- Fund LMSR and trader with ppUSDC ---
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader: owner,
      amount: U(100_000),
    });
  
    await ppUSDC.connect(owner).transfer(lmsrAddr, U(100_000));
  
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: U(50_000),
    });
  
    // --- Now do ONE BACK buy on the non-resolving market ---
    const samplePos = posIds[10];
  
    await ledger
      .connect(trader)
      .buyExactTokens(
        lmsrAddr,
        nonResMarketId,
        samplePos,
        true,       // isBack
        U(50),
        U(1_000)
      );
  });
  
  
});
