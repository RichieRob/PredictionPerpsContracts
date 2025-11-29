// test/helpers/markets.gas.js
const { expect } = require("chai");
const { ethers } = require("hardhat");

// Gas: market + N positions
async function expectGasForMarketWithPositions(fx, {
  marketName,
  marketTicker,
  dmmAddress,
  iscAmount = 0n,
  positions,
}) {
  const { ledger, owner } = fx;

  // Make sure the DMM is allowed before creating the market
  await ledger.connect(owner).allowDMM(dmmAddress, true);

  // Create market
  const createMarketTx = await ledger.createMarket(
    marketName,
    marketTicker,
    dmmAddress,
    iscAmount,
    false,             // doesResolve
    ethers.ZeroAddress,
    "0x"
  );
  const createMarketReceipt = await createMarketTx.wait();
  console.log(
    "createMarket gas used:",
    createMarketReceipt.gasUsed.toString()
  );

  const markets = await ledger.getMarkets();
  expect(markets.length).to.equal(1);
  const marketId = markets[0];

  // Verify market details
  const [marketNameOnChain, marketTickerOnChain] =
    await ledger.getMarketDetails(marketId);
  expect(marketNameOnChain).to.equal(marketName);
  expect(marketTickerOnChain).to.equal(marketTicker);

  // Create positions in batch
  const createPositionsTx = await ledger.createPositions(marketId, positions);
  const createPositionsReceipt = await createPositionsTx.wait();
  console.log(
    `createPositions (${positions.length} positions) gas used:`,
    createPositionsReceipt.gasUsed.toString()
  );

  // Verify positions created
  const positionIds = await ledger.getMarketPositions(marketId);
  expect(positionIds.length).to.equal(positions.length);

  // Spot-check up to 3 positions & ERC20 wiring
  for (let i = 0; i < Math.min(3, positions.length); i++) {
    const pid = positionIds[i];

    const [posName, posTicker] =
      await ledger.getPositionDetails(marketId, pid);
    expect(posName).to.equal(positions[i].name);
    expect(posTicker).to.equal(positions[i].ticker);

    const erc20Name   = await ledger.erc20Name(marketId, pid);
    const erc20Symbol = await ledger.erc20Symbol(marketId, pid);

    expect(erc20Name).to.equal(
      `${positions[i].name} in ${marketName}`
    );
    expect(erc20Symbol).to.equal(
      `${positions[i].ticker}-${marketTicker}`
    );
  }

  const totalGas =
    createMarketReceipt.gasUsed + createPositionsReceipt.gasUsed;
  console.log(
    "Total gas for market + positions:",
    totalGas.toString()
  );
  console.log(
    "Average gas per position:",
    (createPositionsReceipt.gasUsed / BigInt(positions.length)).toString()
  );

  return {
    marketId,
    positionIds,
    gasCreateMarket: createMarketReceipt.gasUsed,
    gasCreatePositions: createPositionsReceipt.gasUsed,
  };
}

module.exports = {
  expectGasForMarketWithPositions,
};
