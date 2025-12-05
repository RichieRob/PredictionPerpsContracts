// test/ledger.market.erc20.discovery.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployCore } = require("./helpers/core");

describe("Market ERC20 discovery + metadata print", function () {
  let fx;

  beforeEach(async () => {
    fx = await deployCore();
  });

  it("creates a market, positions, and prints names/tickers of all ERC20 mirrors", async function () {
    const { ledger, owner } = fx;

    // allow owner as DMM
    await ledger.connect(owner).allowDMM(owner.address, true);

    // CREATE A MARKET
    const marketName   = "Best Team 2025";
    const marketTicker = "TEAM25";

    const tx = await ledger.createMarket(
      marketName,
      marketTicker,
      owner.address,  // DMM
      0,              // iscAmount
      false,          // doesResolve
      ethers.ZeroAddress,
      "0x"
    );
    await tx.wait();

    const markets = await ledger.getMarkets();
    expect(markets.length).to.equal(1);
    const marketId = markets[0];

    const teams = [
      { name: "Arsenal",    ticker: "ARS" },
      { name: "Liverpool",  ticker: "LIV" },
      { name: "Chelsea",    ticker: "CHE" },
    ];

    // CREATE POSITIONS (Back & Lay ERC20 mirrors wired inside)
    await ledger.createPositions(marketId, teams);

    const positionIds = await ledger.getMarketPositions(marketId);
    expect(positionIds.length).to.equal(teams.length);

    console.log(`\n📌 ERC20 TOKENS FOR MARKET: ${marketName} (${marketTicker})\n`);

    for (let i = 0; i < positionIds.length; i++) {
      const pid = positionIds[i];
      const t = teams[i];

      const backToken = await ledger.getBackPositionERC20(marketId, pid);
      const layToken  = await ledger.getLayPositionERC20(marketId, pid);

      // Basic sanity
      expect(backToken).to.properAddress;
      expect(layToken).to.properAddress;

      const backName   = await ledger.erc20NameForSide(marketId, pid, true);
      const backSymbol = await ledger.erc20SymbolForSide(marketId, pid, true);
      const layName    = await ledger.erc20NameForSide(marketId, pid, false);
      const laySymbol  = await ledger.erc20SymbolForSide(marketId, pid, false);

      console.log(`Position #${pid} – ${t.name}`);
      console.log(`   🟢 Back: ${backName}  (${backSymbol})   ${backToken}`);
      console.log(`   🔴 Lay : ${layName}   (${laySymbol})    ${layToken}\n`);

      // ---- Assertions for naming convention ----
      expect(backSymbol).to.equal(`B-${t.ticker}-${marketTicker}`);
      expect(laySymbol).to.equal(`L-${t.ticker}-${marketTicker}`);

      expect(backName).to.equal(`Back ${t.name} in ${marketName}`);
      expect(layName).to.equal(`Lay ${t.name} in ${marketName}`);
    }
  });
});
