// test/helpers/markets.multiuser.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc, deployCore, mintAndDeposit } = require("./core");

// ---------------------------------------------------------
//  Fixture: 2 users (alice/bob), 1 DMM, 1 market, 2 positions (A/B)
// ---------------------------------------------------------

async function setupMultiUserTwoPositionFixture() {
  // fx: { owner, trader, feeRecipient, other, usdc, aUSDC, aavePool, ppUSDC, ledger }
  const fx = await deployCore();
  const { ledger, trader, other } = fx;

  fx.alice = trader;
  fx.bob   = other;

  // Flat DMM
  const FlatMockMarketMaker = await ethers.getContractFactory(
    "FlatMockMarketMaker"
  );
  fx.flatMM = await FlatMockMarketMaker.deploy();
  await fx.flatMM.waitForDeployment();

  await ledger.allowDMM(await fx.flatMM.getAddress(), true);

  // Market with ISC
  const ISC = usdc("100000");
  await ledger.createMarket(
    "Multi-User Test Market",
    "MUTI",
    await fx.flatMM.getAddress(),
    ISC,
    false,
    ethers.ZeroAddress,
    "0x"  );
  const markets = await ledger.getMarkets();
  fx.marketId = markets[0];

  // 2 positions (A/B), using staticCall so ERC20s are registered & we know tokens
  const [posA_, tokenA_] = await ledger.createPosition.staticCall(
    fx.marketId,
    "Team A",
    "A"
  );
  await ledger.createPosition(fx.marketId, "Team A", "A");

  const [posB_, tokenB_] = await ledger.createPosition.staticCall(
    fx.marketId,
    "Team B",
    "B"
  );
  await ledger.createPosition(fx.marketId, "Team B", "B");

  fx.posA   = posA_;
  fx.tokenA = tokenA_;
  fx.posB   = posB_;
  fx.tokenB = tokenB_;

  return fx;
}

// ---------------------------------------------------------
//  Deposits for alice & bob
// ---------------------------------------------------------

async function multiUserDeposits(fx, { aliceDeposit, bobDeposit }) {
  const { usdc, ledger, alice, bob } = fx;

  await mintAndDeposit({
    usdc,
    ledger,
    trader: alice,
    amount: aliceDeposit,
  });

  await mintAndDeposit({
    usdc,
    ledger,
    trader: bob,
    amount: bobDeposit,
  });
}

// ---------------------------------------------------------
//  ppUSDC + ERC20 mirrors for multi-user scenario
// ---------------------------------------------------------

async function expectMultiUserPpUsdcAndErc20Mirrors(fx) {
  const {
    ppUSDC,
    ledger,
    flatMM,
    owner,
    alice,
    bob,
    tokenA,
    tokenB,
  } = fx;

  const dmmAddr    = await flatMM.getAddress();
  const ledgerAddr = await ledger.getAddress();

  // ----- ppUSDC mirrors freeCollateral -----

  const tsPp = await ppUSDC.totalSupply();

  const freeAlice  = await ledger.realFreeCollateral(alice.address);
  const freeBob    = await ledger.realFreeCollateral(bob.address);
  const freeDmm    = await ledger.realFreeCollateral(dmmAddr);
  const freeOwner  = await ledger.realFreeCollateral(owner.address);
  const freeLedger = await ledger.realFreeCollateral(ledgerAddr);

  // owner/ledger shouldn't be phantom holders
  expect(freeOwner).to.equal(0n);
  expect(freeLedger).to.equal(0n);

  const totalFree =
    freeAlice + freeBob + freeDmm + freeOwner + freeLedger;

  expect(totalFree).to.equal(await ledger.realTotalFreeCollateral());
  expect(tsPp).to.equal(totalFree);

  // per-account ppUSDC mirrors freeCollateral
  expect(await ppUSDC.balanceOf(alice.address)).to.equal(freeAlice);
  expect(await ppUSDC.balanceOf(bob.address)).to.equal(freeBob);
  expect(await ppUSDC.balanceOf(dmmAddr)).to.equal(freeDmm);

  // ----- ERC20 position A -----

  const tsA        = await ledger.erc20TotalSupply(tokenA);
  const balA_A     = await ledger.erc20BalanceOf(tokenA, alice.address);
  const balA_B     = await ledger.erc20BalanceOf(tokenA, bob.address);
  const balA_DMM   = await ledger.erc20BalanceOf(tokenA, dmmAddr);
  const balA_Owner = await ledger.erc20BalanceOf(tokenA, owner.address);
  const balA_Ledger= await ledger.erc20BalanceOf(tokenA, ledgerAddr);

  expect(balA_Owner).to.equal(0n);
  expect(balA_Ledger).to.equal(0n);

  const sumA = balA_A + balA_B + balA_DMM;
  expect(tsA).to.equal(sumA);

  // ----- ERC20 position B -----

  const tsB        = await ledger.erc20TotalSupply(tokenB);
  const balB_A     = await ledger.erc20BalanceOf(tokenB, alice.address);
  const balB_B     = await ledger.erc20BalanceOf(tokenB, bob.address);
  const balB_DMM   = await ledger.erc20BalanceOf(tokenB, dmmAddr);
  const balB_Owner = await ledger.erc20BalanceOf(tokenB, owner.address);
  const balB_Ledger= await ledger.erc20BalanceOf(tokenB, ledgerAddr);

  expect(balB_Owner).to.equal(0n);
  expect(balB_Ledger).to.equal(0n);

  const sumB = balB_A + balB_B + balB_DMM;
  expect(tsB).to.equal(sumB);
}

module.exports = {
  setupMultiUserTwoPositionFixture,
  multiUserDeposits,
  expectMultiUserPpUsdcAndErc20Mirrors,
};
