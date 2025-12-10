const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore } = require("./helpers/core");

describe("Gas – ERC20 transfers (PositionERC20 + ppUSDC)", function () {
  let fx;              // { owner, trader, feeRecipient, usdc, aUSDC, aavePool, ppUSDC, ledger }
  let extraAccounts;   // extra signers as receivers
  let positionTokens;  // array of { marketId, positionId, token, tokenAddr }

  beforeEach(async () => {
    fx = await deployCore();

    const signers = await ethers.getSigners();
    // 0 = owner, 1 = trader; use the rest as possible receivers
    extraAccounts = signers.slice(2, 8); // tweak if wanted

    positionTokens = await setupMultipleMarketsAndPositions(fx, {
      markets: 3,
      positionsPerMarket: 3,
    });
  });

  /// Create multiple markets with ISC seeding and multiple positions each.
  /// Returns an array of { marketId, positionId, token, tokenAddr }.
  async function setupMultipleMarketsAndPositions(fx, { markets, positionsPerMarket }) {
    const { ledger, owner } = fx;
    const tokens = [];

    // ensure owner is allowed as DMM
    await ledger.allowDMM(owner.address, true);

    for (let m = 0; m < markets; m++) {
      const iscAmount = usdc("100"); // 100 full sets synthetic line

      await ledger.createMarket(
        `ISC Seeded Market #${m}`,
        `ISM${m}`,
        owner.address,  // DMM account
        iscAmount,
        false,          // non-resolving
        ethers.ZeroAddress,
  "0x",
  0,                             // feeBps
  fx.owner.address,              // marketCreator
  [],                            // feeWhitelistAccounts
  false                          // hasWhitelist
);

      const allMarketIds = await ledger.getMarkets();
      const marketId = allMarketIds[allMarketIds.length - 1];

      for (let p = 0; p < positionsPerMarket; p++) {
        const posName   = `Outcome ${m}-${p}`;
        const posTicker = `O${m}${p}`;

        const [positionId, tokenAddr] = await ledger.createPosition.staticCall(
          marketId,
          posName,
          posTicker
        );
        await ledger.createPosition(marketId, posName, posTicker);

        const token = await ethers.getContractAt("PositionERC20", tokenAddr);

        tokens.push({
          marketId,
          positionId,
          token,
          tokenAddr: tokenAddr.toLowerCase(),
        });
      }
    }

    return tokens;
  }

  // --------------------------------------------------
  // 1) Baseline single transfers
  // --------------------------------------------------

  it("baseline – MockUSDC.transfer and PositionERC20.transfer (single)", async function () {
    const { owner, trader, usdc: usdcToken } = fx;

    // --- MockUSDC baseline ---
    const amount = usdc("1");
    await usdcToken.mint(owner.address, amount);

    const tx1 = await usdcToken.connect(owner).transfer(trader.address, amount);
    const rcpt1 = await tx1.wait();

    console.log("⚙️  Gas used – MockUSDC.transfer (single):", rcpt1.gasUsed.toString());

    // --- One PositionERC20 transfer (single) ---
    const { token } = positionTokens[0];
    const transferAmount = 1n; // 0.000001 units (decimals = 6)

    const tx2 = await token.connect(owner).transfer(trader.address, transferAmount);
    const rcpt2 = await tx2.wait();

    console.log("⚙️  Gas used – PositionERC20.transfer (single):", rcpt2.gasUsed.toString());

    expect(rcpt1.gasUsed).to.be.gt(0n);
    expect(rcpt2.gasUsed).to.be.gt(0n);
  });

  // --------------------------------------------------
  // 2) PositionERC20 – new user entering a warm market
  // --------------------------------------------------
  //
  // Definition for this test:
  //  - "Warm market" = markets already have had some transfers so storage slots are
  //    populated; we're not measuring absolute first-ever touches.
  //  - "New user first in market" = a given receiver's FIRST time receiving ANY
  //    position token from that market.
  //  - "Subsequent in market" = the same receiver getting MORE transfers from
  //    that same market after their first.
  //
  // For each market:
  //   - We pick ONE representative PositionERC20 (first token in that market).
  //   - We pre-warm the market by doing dummy transfers from owner to a "warmer".
  //   - Then for each "real user" we:
  //       * send one "first in market" transfer (measured)
  //       * send several "subsequent in market" transfers (measured)
  // --------------------------------------------------

  it("gas hammer – PositionERC20: new user in warm market (first vs subsequent)", async function () {
    const { owner } = fx;

    // pick one representative token per market
    const tokensPerMarket = pickFirstTokenPerMarket(positionTokens);

    // a dedicated account to warm each market
    const signerList = await ethers.getSigners();
    const warmer = signerList[signerList.length - 1];

    const FIRST_AMOUNT = 1n;
    const SUBSEQUENT_AMOUNT = 1n;
    const SUBSEQUENT_TRANSFERS_PER_USER_PER_MARKET = 3;

    const firstInMarketGas = [];
    const subsequentInMarketGas = [];

    // -------- Step 1: pre-warm markets --------
    for (const entry of tokensPerMarket) {
      const { token } = entry;

      // few transfers from owner -> warmer to make the ledger / storage "warm-ish"
      for (let i = 0; i < 3; i++) {
        await (await token.connect(owner).transfer(warmer.address, 1n)).wait();
      }
    }

    // -------- Step 2: measure "new user entering warm market" --------
    const seenMarketUser = new Set(); // key: `${marketId}-${user}`

    for (const entry of tokensPerMarket) {
      const { marketId, token } = entry;
      const mKey = marketId.toString();

      for (const user of extraAccounts) {
        const uKey = user.address.toLowerCase();
        const key = `${mKey}-${uKey}`;

        // ---- First transfer for this user in this market ----
        const txFirst = await token.connect(owner).transfer(user.address, FIRST_AMOUNT);
        const rcptFirst = await txFirst.wait();
        firstInMarketGas.push(rcptFirst.gasUsed);
        seenMarketUser.add(key);

        // ---- Subsequent transfers to the same user in the same market ----
        for (let j = 0; j < SUBSEQUENT_TRANSFERS_PER_USER_PER_MARKET; j++) {
          const txSub = await token.connect(owner).transfer(user.address, SUBSEQUENT_AMOUNT);
          const rcptSub = await txSub.wait();
          subsequentInMarketGas.push(rcptSub.gasUsed);
        }
      }
    }

    // -------- Print nice "box" summary --------
    console.log("══════════════════════════════════════════════");
    console.log("📦 PositionERC20.transfer – New user in WARM market");
    console.log("  Definition:");
    console.log("    • First in market  = user's first time receiving ANY position token in that market");
    console.log("    • Subsequent       = same user receiving more from that market afterwards");
    console.log("--------------------------------------------------");
    printBucketStats("First-in-market transfers", firstInMarketGas);
    printBucketStats("Subsequent-in-market transfers", subsequentInMarketGas);
    console.log("══════════════════════════════════════════════");

    expect(firstInMarketGas.length).to.be.gt(0);
    expect(subsequentInMarketGas.length).to.be.gt(0);
  });

  // --------------------------------------------------
  // 3) ppUSDC – gas hammer (first vs subsequent per user)
  // --------------------------------------------------
  //
  // Here we just care about:
  //   - first time each user ever receives ppUSDC
  //   - subsequent ppUSDC transfers to the same user
  //
  // No market dimension here; ppUSDC is global.
  // --------------------------------------------------

  it("gas hammer – ppUSDC.transfer (first vs subsequent per user)", async function () {
    const { owner, ppUSDC, ledger, usdc: usdcToken } = fx;

    // Give owner some ppUSDC by depositing USDC
    const DEPOSIT_AMOUNT = usdc("1000");
    await usdcToken.mint(owner.address, DEPOSIT_AMOUNT);
    await usdcToken.connect(owner).approve(await ledger.getAddress(), DEPOSIT_AMOUNT);
    await ledger
      .connect(owner)
      .deposit(owner.address, DEPOSIT_AMOUNT, 0n, 0, {
        value: 0n,
        deadline: 0n,
        v: 0,
        r: "0x" + "0".repeat(64),
        s: "0x" + "0".repeat(64),
      });

    const FIRST_AMOUNT = usdc("1");
    const SUBSEQUENT_AMOUNT = usdc("1");
    const SUBSEQUENT_TRANSFERS_PER_USER = 5;

    const firstPerUser = [];
    const subsequentPerUser = [];

    for (const user of extraAccounts) {
      // --- first transfer to this user ---
      const txFirst = await ppUSDC.connect(owner).transfer(user.address, FIRST_AMOUNT);
      const rcptFirst = await txFirst.wait();
      firstPerUser.push(rcptFirst.gasUsed);

      // --- subsequent transfers to this same user ---
      for (let i = 0; i < SUBSEQUENT_TRANSFERS_PER_USER; i++) {
        const txSub = await ppUSDC.connect(owner).transfer(user.address, SUBSEQUENT_AMOUNT);
        const rcptSub = await txSub.wait();
        subsequentPerUser.push(rcptSub.gasUsed);
      }
    }

    console.log("══════════════════════════════════════════════");
    console.log("📦 ppUSDC.transfer – per-user first vs subsequent");
    console.log("  Definition:");
    console.log("    • First per user  = first time the user receives any ppUSDC");
    console.log("    • Subsequent      = later ppUSDC transfers to same user");
    console.log("--------------------------------------------------");
    printBucketStats("First-per-user transfers", firstPerUser);
    printBucketStats("Subsequent-per-user transfers", subsequentPerUser);
    console.log("══════════════════════════════════════════════");

    expect(firstPerUser.length).to.be.gt(0);
    expect(subsequentPerUser.length).to.be.gt(0);
  });

  // --------------------------------------------------
  // helpers
  // --------------------------------------------------

  function pickFirstTokenPerMarket(positionTokens) {
    const seen = new Set();
    const result = [];

    for (const entry of positionTokens) {
      const key = entry.marketId.toString();
      if (!seen.has(key)) {
        seen.add(key);
        result.push(entry);
      }
    }
    return result;
  }

  function printBucketStats(label, arr) {
    if (!arr.length) {
      console.log(`  ${label}: count=0`);
      return;
    }
    const stats = summarizeGas(arr);
    console.log(
      `  ${label}: count=${stats.count}, min=${stats.min}, avg=${stats.avg}, max=${stats.max}`
    );
  }


  function summarizeGas(arr) {
    if (!arr.length) {
      return { count: 0, min: 0n, max: 0n, avg: 0n };
    }

    let min = arr[0];
    let max = arr[0];
    let sum = 0n;

    for (const g of arr) {
      if (g < min) min = g;
      if (g > max) max = g;
      sum += g;
    }

    const avg = sum / BigInt(arr.length);

    return {
      count: arr.length,
      min,
      max,
      avg,
    };
  }
});
