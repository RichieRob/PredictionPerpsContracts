// scripts/deploy.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function deployWithLogs(name, factory, signer, args = []) {
  console.log(`\n──────── Deploying ${name} ────────`);

  const deployTxReq = await factory.getDeployTransaction(...args);
  console.log(`${name} deploy tx request:`, {
    to: deployTxReq.to,
    from: deployTxReq.from,
    dataLength: deployTxReq.data ? deployTxReq.data.length : 0,
    value: deployTxReq.value ? deployTxReq.value.toString() : "0",
  });

  const txResponse = await signer.sendTransaction(deployTxReq);
  console.log(`${name} tx hash:`, txResponse.hash);

  const receipt = await txResponse.wait();
  console.log(`✅ ${name} deployed at:`, receipt.contractAddress);
  console.log(`${name} gasUsed:`, receipt.gasUsed.toString());

  return factory.attach(receipt.contractAddress);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying core contracts with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Deployer ETH balance:", ethers.formatEther(balance), "ETH");

  // Check network
  const network = await ethers.provider.getNetwork();
  const chainId = network.chainId;
  console.log(`Deploying on network: ${network.name} (chainId: ${chainId})`);

  const block = await ethers.provider.getBlockNumber();
  console.log("Provider OK, current block:", block.toString());

  // ─────────────── Deploy mocks ───────────────
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await deployWithLogs("MockUSDC", MockUSDC, deployer);

  const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
  const mockAUSDC = await deployWithLogs("MockAUSDC", MockAUSDC, deployer);

  const MockAavePool = await ethers.getContractFactory("MockAavePool");
  const mockAavePool = await deployWithLogs(
    "MockAavePool",
    MockAavePool,
    deployer,
    [mockUSDC.target, mockAUSDC.target]
  );

  const PpUSDC = await ethers.getContractFactory("PpUSDC");
  const ppUSDC = await deployWithLogs("PpUSDC", PpUSDC, deployer);

  const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

  // ─────────────── Deploy libraries ───────────────
  const DepositWithdrawLibFactory = await ethers.getContractFactory("DepositWithdrawLib");
  const depositWithdrawLib = await deployWithLogs(
    "DepositWithdrawLib",
    DepositWithdrawLibFactory,
    deployer
  );

  const SettlementLibFactory = await ethers.getContractFactory("SettlementLib");
  const settlementLib = await deployWithLogs(
    "SettlementLib",
    SettlementLibFactory,
    deployer
  );

  // ─────────────── Deploy Ledger (linked) ───────────────
  console.log("\nGetting Ledger factory (with linked libraries)...");
  const LedgerFactory = await ethers.getContractFactory("Ledger", {
    libraries: {
      DepositWithdrawLib: depositWithdrawLib.target,
      SettlementLib:      settlementLib.target,
    },
  });

  const ledger = await deployWithLogs(
    "Ledger",
    LedgerFactory,
    deployer,
    [
      mockUSDC.target,
      mockAUSDC.target,
      mockAavePool.target,
      PERMIT2_ADDRESS,
      ppUSDC.target,
    ]
  );

  console.log("Setting PpUSDC ledger...");
  const setLedgerTx = await ppUSDC.setLedger(ledger.target);
  console.log("setLedger tx hash:", setLedgerTx.hash);
  await setLedgerTx.wait();
  console.log("✅ Set PpUSDC ledger");

  // ─────────────── Deploy PositionERC20 ───────────────
  const PositionERC20Factory = await ethers.getContractFactory("PositionERC20");
  const positionImpl = await deployWithLogs(
    "PositionERC20",
    PositionERC20Factory,
    deployer,
    [ledger.target]
  );

  console.log("Setting PositionERC20 implementation...");
  const setImplTx = await ledger.setPositionERC20Implementation(positionImpl.target);
  console.log("setPositionERC20Implementation tx hash:", setImplTx.hash);
  await setImplTx.wait();
  console.log("✅ Set PositionERC20 implementation");

  // ─────────────── Deploy IntentContract ───────────────
  const IntentContractFactory = await ethers.getContractFactory("IntentContract");
  const intentContract = await deployWithLogs(
    "IntentContract",
    IntentContractFactory,
    deployer,
    [ledger.target]
  );

  console.log("Allowing IntentContract on Ledger...");
  const intentTx = await ledger.setIntentContract(intentContract.target, true);
  console.log("setIntentContract tx hash:", intentTx.hash);
  await intentTx.wait();
  console.log("✅ IntentContract allowlisted on Ledger");

  // ─────────────── Deploy LedgerViews ───────────────
  const LedgerViewsFactory = await ethers.getContractFactory("LedgerViews");
  const ledgerViews = await deployWithLogs(
    "LedgerViews",
    LedgerViewsFactory,
    deployer,
    [ledger.target]
  );

  // ─────────────── Save deployments.json ───────────────
  const deployments = {
    chainId: chainId.toString(),
    deployer: deployer.address,
    MockUSDC: mockUSDC.target,
    MockAUSDC: mockAUSDC.target,
    MockAavePool: mockAavePool.target,
    PpUSDC: ppUSDC.target,
    Ledger: ledger.target,
    PositionERC20: positionImpl.target,
    IntentContract: intentContract.target,
    LedgerViews: ledgerViews.target,
    DepositWithdrawLib: depositWithdrawLib.target,
    SettlementLib: settlementLib.target,
    Permit2: PERMIT2_ADDRESS,
  };

  const filePath = path.join(__dirname, "../deployments.json");
  console.log("\nWriting deployments file to:", filePath);

  let existingData = {};
  if (fs.existsSync(filePath)) {
    existingData = JSON.parse(fs.readFileSync(filePath, "utf8"));
  }
  existingData.core = deployments;
  fs.writeFileSync(filePath, JSON.stringify(existingData, null, 2));
  console.log(`✅ Core deployments saved to ${filePath}`);
}

main()
  .then(() => {
    console.log("🎉 deployCore completed.");
    process.exit(0);
  })
  .catch((error) => {
    console.error("❌ deployCore failed:", error);
    process.exit(1);
  });
