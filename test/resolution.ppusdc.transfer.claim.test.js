// test/resolution.ppusdc.transfer.claim.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  deployCore,
  usdc,
  mintAndDeposit,
} = require("./helpers/core");
const {
  expectCoreSystemInvariants,
} = require("./helpers/markets");
const {
  resolveViaMockOracle,
  assertWinnerPayout,
} = require("./helpers/resolution");

describe(
  "MarketMakerLedger – resolution + ppUSDC transfer + withdraw + claim",
  () => {
    let fx;
    let mm;
    let oracle;
    let marketId;
    let posA;
    let posAToken;
    let trader;
    let receiver;
    let mmAddr;
    let receiverSigner;

    // --------------------------------------------------------------------
    //  Helpers
    // --------------------------------------------------------------------

    function fmt(bn) {
      return (Number(bn) / 1e6).toFixed(2); // micro → USDC
    }

    function printRow(name, real, eff, pp) {
        const pad = (s)=> s.toString().padEnd(10);
        console.log(
          `${pad(name)} | real:${fmt(real)}  eff:${fmt(eff)}  pp:${fmt(pp)}`
        );
      }
      
      async function logState(label, ctx) {
        const { fx, trader, receiver, mmAddr, marketId, posAToken, posBToken } = ctx;
      
        const [
          ppT, realT, effT,
          ppR, realR, effR,
          ppM, realM, effM,
          tokT_A, tokR_A, tokM_A,
          tokT_B, tokR_B, tokM_B,
          marketValue
        ] = await Promise.all([
          fx.ppUSDC.balanceOf(trader),
          fx.ledger.realFreeCollateral(trader),
          fx.ledger.effectiveFreeCollateral(trader),
      
          fx.ppUSDC.balanceOf(receiver),
          fx.ledger.realFreeCollateral(receiver),
          fx.ledger.effectiveFreeCollateral(receiver),
      
          fx.ppUSDC.balanceOf(mmAddr),
          fx.ledger.realFreeCollateral(mmAddr),
          fx.ledger.effectiveFreeCollateral(mmAddr),
      
          posAToken.balanceOf(trader),
          posAToken.balanceOf(receiver),
          posAToken.balanceOf(mmAddr),
      
          posBToken ? posBToken.balanceOf(trader) : 0n,
          posBToken ? posBToken.balanceOf(receiver) : 0n,
          posBToken ? posBToken.balanceOf(mmAddr) : 0n,
      
          fx.ledger.getMarketValue(marketId)
        ]);
      
        console.log(`\n================ ${label} ================`);
        console.log(`MarketValue = ${fmt(marketValue)} USDC\n`);
      
        console.log(`ACCOUNT STATE (real / effective / ppUSDC)\n`);
        printRow("Trader",   realT, effT, ppT);
        printRow("Receiver", realR, effR, ppR);
        printRow("MM",       realM, effM, ppM);
      
        console.log(
          `\nTotals → real:${fmt(realT+realR+realM)}  eff:${fmt(effT+effR+effM)}  pp:${fmt(ppT+ppR+ppM)}`
        );
      
        console.log(`\nPosition Tokens:`);
        console.log(`A → T:${tokT_A}  R:${tokR_A}  MM:${tokM_A}`);
        if (posBToken)
          console.log(`B → T:${tokT_B}  R:${tokR_B}  MM:${tokM_B}`);
      }
      

    // --------------------------------------------------------------------
    //  Shared setup
    // --------------------------------------------------------------------

    beforeEach(async () => {
      fx = await deployCore();
      trader = fx.trader.address;

      const Flat = await ethers.getContractFactory(
        "FlatMockMarketMaker"
      );
      mm = await Flat.deploy();
      await mm.waitForDeployment();
      mmAddr = await mm.getAddress();

      const MockOracle = await ethers.getContractFactory(
        "MockOracle"
      );
      oracle = await MockOracle.deploy();
      await oracle.waitForDeployment();

      // Resolving market: no DMM, no ISC
      await fx.ledger.createMarket(
        "Election 2028",
        "EL",
        ethers.ZeroAddress, // resolving market → no DMM
        0,
        true, // doesResolve = true
        await oracle.getAddress(),
        "0x"
      );

      marketId = (await fx.ledger.getMarkets())[0];

      // Two outcomes
      await fx.ledger.createPosition(marketId, "Alice", "A");
      await fx.ledger.createPosition(marketId, "Bob", "B");

      const positions =
        await fx.ledger.getMarketPositions(marketId);
      posA = positions[0];

      const posATokenAddr =
        await fx.ledger.getPositionERC20(marketId, posA);
      const PositionERC20 =
        await ethers.getContractFactory("PositionERC20");
      posAToken = PositionERC20.attach(posATokenAddr);

      // Extra EOA to receive ppUSDC
      const [, , rSigner] = await ethers.getSigners();
      receiverSigner = rSigner;
      receiver = receiverSigner.address;

      // Fund trader & "mm" address via helper
      await mintAndDeposit({
        usdc: fx.usdc,
        ledger: fx.ledger,
        trader: fx.trader,
        amount: usdc("1000"),
      });

      await mintAndDeposit({
        usdc: fx.usdc,
        ledger: fx.ledger,
        trader: fx.owner,
        to: mmAddr,
        amount: usdc("1500"),
      });

      // Trader buys some A (BACK) vs mm address
      await fx.ledger
        .connect(fx.trader)
        .buyExactTokens(
          mmAddr,
          marketId,
          posA,
          true,
          usdc("200"),
          usdc("1000")
        );

      await logState("after setup + buy", {
        fx,
        trader,
        receiver,
        mmAddr,
        marketId,
        posAToken,
        posBToken: null,
      });
    });

    // --------------------------------------------------------------------
    //  Test: no double-count on winnings
    // --------------------------------------------------------------------

    it(
      "does not double-count winnings across ppUSDC transfer + withdraw + claim",
      async () => {
        const preTokenBal = await posAToken.balanceOf(trader);
        expect(preTokenBal).to.be.gt(0n);

        const prePpTrader = await fx.ppUSDC.balanceOf(trader);
        const prePpReceiver =
          await fx.ppUSDC.balanceOf(receiver);

        // --- 1) Resolve via oracle (A wins) ---
        await resolveViaMockOracle({
          oracle,
          ledger: fx.ledger,
          marketId,
          winningPositionId: posA,
        });

        await logState(
          "after resolution (before any claims)",
          {
            fx,
            trader,
            receiver,
            mmAddr,
            marketId,
            posAToken,
            posBToken: null,
          }
        );

        // Winner payout via ppUSDC view
        const ppAfterResolve = await assertWinnerPayout({
          ppUSDC: fx.ppUSDC,
          account: trader,
          prePp: prePpTrader,
          preTokenBal,
        });

        // Sanity: effective - real = pending before any _applyPendingWinnings(trader)
        const realAfterResolve =
          await fx.ledger.realFreeCollateral(trader);
        const effAfterResolve =
          await fx.ledger.effectiveFreeCollateral(trader);
        const pendingDelta =
          effAfterResolve - realAfterResolve;

        console.log(
          `pendingDelta for trader right after resolution = ${fmt(
            pendingDelta
          )} USDC (should equal preTokenBal in tokens)`
        );

        expect(pendingDelta).to.equal(preTokenBal);

        await logState("after resolution + ppUSDC view check", {
          fx,
          trader,
          receiver,
          mmAddr,
          marketId,
          posAToken,
          posBToken: null,
        });

        // Receiver still unchanged so far
        expect(
          await fx.ppUSDC.balanceOf(receiver)
        ).to.equal(prePpReceiver);

        // --- 2) Trader transfers half of their ppUSDC winnings to receiver ---
        const winnings = ppAfterResolve - prePpTrader;
        const halfWinnings = winnings / 2n;
        expect(halfWinnings).to.be.gt(0n);

        const preTraderReal =
          await fx.ledger.realFreeCollateral(trader);
        const preReceiverReal =
          await fx.ledger.realFreeCollateral(receiver);

        // This call will internally call _applyPendingWinnings(trader) first,
        // then move halfWinnings from trader → receiver.
        await fx.ppUSDC
          .connect(fx.trader)
          .transfer(receiver, halfWinnings);

        const midPpTrader =
          await fx.ppUSDC.balanceOf(trader);
        const midPpReceiver =
          await fx.ppUSDC.balanceOf(receiver);
        const midTraderReal =
          await fx.ledger.realFreeCollateral(trader);
        const midReceiverReal =
          await fx.ledger.realFreeCollateral(receiver);

        await logState(
          "after ppUSDC transfer (which realises trader winnings)",
          {
            fx,
            trader,
            receiver,
            mmAddr,
            marketId,
            posAToken,
            posBToken: null,
          }
        );

        // Mirrors should stay consistent with realFreeCollateral
        expect(midPpTrader).to.equal(midTraderReal);
        expect(midPpReceiver).to.equal(midReceiverReal);

        // Now the sum of REAL freeCollateral for trader + receiver
        // should be previous sum + full winnings (because pending was just realised)
        expect(midTraderReal + midReceiverReal).to.equal(
          preTraderReal + preReceiverReal + pendingDelta
        );

        // --- 3) Trader withdraws some ppUSDC to wallet ---
        const withdrawAmount = usdc("50");
        await fx.ledger
          .connect(fx.trader)
          .withdraw(withdrawAmount, trader);

        const postWithdrawPpTrader =
          await fx.ppUSDC.balanceOf(trader);
        const postWithdrawPpReceiver =
          await fx.ppUSDC.balanceOf(receiver);
        const postWithdrawTraderReal =
          await fx.ledger.realFreeCollateral(trader);
        const postWithdrawReceiverReal =
          await fx.ledger.realFreeCollateral(receiver);

        await logState(
          "after trader withdraws 50 USDC from ppUSDC",
          {
            fx,
            trader,
            receiver,
            mmAddr,
            marketId,
            posAToken,
            posBToken: null,
          }
        );

        expect(postWithdrawPpTrader).to.equal(
          postWithdrawTraderReal
        );
        expect(postWithdrawPpReceiver).to.equal(
          postWithdrawReceiverReal
        );

        // --- 4) Claims after all of this should be no-op on visible ppUSDC ---
        const preClaimPpTrader = postWithdrawPpTrader;
        const preClaimPpReceiver = postWithdrawPpReceiver;

        await fx.ledger
          .connect(fx.trader)
          .claimAllPendingWinnings();
        await fx.ledger
          .connect(receiverSigner)
          .claimAllPendingWinnings();

        const postClaimPpTrader =
          await fx.ppUSDC.balanceOf(trader);
        const postClaimPpReceiver =
          await fx.ppUSDC.balanceOf(receiver);

        await logState(
          "after claimAllPendingWinnings for both trader and receiver",
          {
            fx,
            trader,
            receiver,
            mmAddr,
            marketId,
            posAToken,
            posBToken: null,
          }
        );

        // No double-counting on visible balances
        expect(postClaimPpTrader).to.equal(preClaimPpTrader);
        expect(postClaimPpReceiver).to.equal(preClaimPpReceiver);

        // --- 5) Global invariants still hold ---
        await expectCoreSystemInvariants(fx, {
          accounts: [trader, receiver, mmAddr],
          marketId,
          checkRedeemabilityFor: [trader, receiver, mmAddr],
        });
      }
    );
  }
);
