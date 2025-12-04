// test/helpers/resolution.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { usdc } = require("./core");

// ---------------------------------------------------------------------------
// 1) Resolve via MockOracle (A wins style)
// ---------------------------------------------------------------------------

async function resolveViaMockOracle({ oracle, ledger, marketId, winningPositionId }) {
  await oracle.pushResolution(marketId, winningPositionId);
  await ledger.resolveMarket(marketId);
}

// ---------------------------------------------------------------------------
// 2) Winner payout = 1 ppUSDC per winning BACK token
// ---------------------------------------------------------------------------

async function assertWinnerPayout({ ppUSDC, account, prePp, preTokenBal }) {
  const postPp = await ppUSDC.balanceOf(account);
  const expected = prePp + preTokenBal;
  expect(postPp).to.equal(expected);
  return postPp;
}

// ---------------------------------------------------------------------------
/**
 * 3) Market frozen after resolution
 *
 * For `account`:
 *   - PositionERC20.balanceOf == 0
 *   - ledger.erc20BalanceOf   == 0
 *
 * If checkTrading = true (EOA trader):
 *   - buy/sell revert with "Market resolved"
 *   - P2P ERC20 transfer (if preTokenBalForTransferCheck > 0) reverts
 */
// ---------------------------------------------------------------------------

async function assertMarketFrozenFor({
  ledger,
  posToken,                     // PositionERC20 contract instance
  account,                      // address string
  mmAddr,                       // address string (counterparty param)
  marketId,
  positionId,
  preTokenBalForTransferCheck = 0n,
  checkTrading = true,          // 👈 new flag
}) {
  const tokenAddr = await posToken.getAddress();

  // View balances must read zero
  const tokenBal = await posToken.balanceOf(account);
  expect(tokenBal).to.equal(0n);

  const viewBal = await ledger.erc20BalanceOf(tokenAddr, account);
  expect(viewBal).to.equal(0n);

  // Only EOAs / known signers should be used to test trading + transfer reverts
  if (!checkTrading) {
    return;
  }

  const signer = await ethers.getSigner(account);

  // Trading must be frozen
  await expect(
    ledger
      .connect(signer)
      .buyExactTokens(
        mmAddr,
        marketId,
        positionId,
        true,
        usdc("10"),
        usdc("100")
      )
  ).to.be.reverted;



  // P2P PositionERC20 transfers must also be frozen
  if (preTokenBalForTransferCheck > 0n) {
    const [owner] = await ethers.getSigners(); // arbitrary recipient

    await expect(
      posToken
        .connect(signer)
        .transfer(owner.address, preTokenBalForTransferCheck)
    ).to.be.reverted;
  }
}

module.exports = {
  resolveViaMockOracle,
  assertWinnerPayout,
  assertMarketFrozenFor,
};
