// test/interest.withdraw.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  usdc,
  deployCore,
  mintAndDeposit,
} = require("./helpers/core");

describe("MarketMakerLedger – interest skim via withdrawInterest", function () {
  it("skims only yield aUSDC and keeps TVL accounting consistent", async () => {
    const fx = await deployCore();
    const { owner, trader, ledger, usdc: usdcToken, aUSDC, aavePool } = fx;

    const DEPOSIT = usdc("100");
    const INTEREST = usdc("10");

    // 1) Trader deposits 100 → TVL = 100, aUSDC = 100
    await mintAndDeposit({
      usdc: usdcToken,
      ledger,
      trader,
      amount: DEPOSIT,
    });

    const ledgerAddr = await ledger.getAddress();
    const poolAddr   = await aavePool.getAddress();

    // 2) Fake yield:
    //    - extra aUSDC to the ledger
    //    - extra USDC to the pool so withdraw() can pay it out
    await aUSDC.mint(ledgerAddr, INTEREST);
    await usdcToken.mint(poolAddr, INTEREST);

    // Sanity before skim
    let [tvlBefore, aBalBefore] = await ledger.invariant_tvl();
    expect(tvlBefore).to.equal(DEPOSIT);
    expect(aBalBefore).to.equal(DEPOSIT + INTEREST);

    const ownerUsdcBefore = await usdcToken.balanceOf(owner.address);

    // 3) Owner skims interest
    await ledger.connect(owner).withdrawInterest();

    const ownerUsdcAfter = await usdcToken.balanceOf(owner.address);
    expect(ownerUsdcAfter - ownerUsdcBefore).to.equal(INTEREST);

    // 4) After skim: TVL unchanged, aUSDC back to TVL
    const [tvlAfter, aBalAfter] = await ledger.invariant_tvl();
    expect(tvlAfter).to.equal(DEPOSIT);
    expect(aBalAfter).to.equal(DEPOSIT);

    // Optional: system invariants still okay
    const [lhsSys, rhsSys] = await ledger.invariant_systemBalance();
    expect(lhsSys).to.equal(rhsSys);
  });
});
