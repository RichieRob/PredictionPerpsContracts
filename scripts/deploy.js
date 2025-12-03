// scripts/deploy.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying core contracts with account:", deployer.address);

  // Check network
  const network = await ethers.provider.getNetwork();
  const chainId = network.chainId;
  console.log(`Deploying on network: ${network.name} (chainId: ${chainId})`);

  // Sanity check provider again
  const block = await ethers.provider.getBlockNumber();
  console.log("Provider OK, current block:", block.toString());

  // ─────────────── Deploy mocks ───────────────
  console.log("Getting MockUSDC factory...");
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  console.log("Deploying MockUSDC...");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  console.log("✅ MockUSDC deployed to:", mockUSDC.target);

  console.log("Getting MockAUSDC factory...");
  const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
  console.log("Deploying MockAUSDC...");
  const mockAUSDC = await MockAUSDC.deploy();
  await mockAUSDC.waitForDeployment();
  console.log("✅ MockAUSDC deployed to:", mockAUSDC.target);

  console.log("Getting MockAavePool factory...");
  const MockAavePool = await ethers.getContractFactory("MockAavePool");
  console.log("Deploying MockAavePool...");
  const mockAavePool = await MockAavePool.deploy(mockUSDC.target, mockAUSDC.target);
  await mockAavePool.waitForDeployment();
  console.log("✅ MockAavePool deployed to:", mockAavePool.target);

  console.log("Getting PpUSDC factory...");
  const PpUSDC = await ethers.getContractFactory("PpUSDC");
  console.log("Deploying PpUSDC...");
  const ppUSDC = await PpUSDC.deploy();
  await ppUSDC.waitForDeployment();
  console.log("✅ PpUSDC deployed to:", ppUSDC.target);

  const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

  // ─────────────── Deploy Ledger ───────────────
  console.log("Getting Ledger factory...");
  const Ledger = await ethers.getContractFactory("Ledger");

  console.log("Deploying Ledger...");
  const ledger = await Ledger.deploy(
    mockUSDC.target,
    mockAUSDC.target,
    mockAavePool.target,
    PERMIT2_ADDRESS,
    ppUSDC.target
  );
  console.log("Ledger deployment tx hash:", ledger.deploymentTransaction().hash);
  await ledger.waitForDeployment();
  console.log("✅ Ledger deployed to:", ledger.target);

  console.log("Setting PpUSDC ledger...");
  await ppUSDC.setLedger(ledger.target);
  console.log("✅ Set PpUSDC ledger");

  // ─────────────── Deploy PositionERC20 ───────────────
  console.log("Getting PositionERC20 factory...");
  const PositionERC20 = await ethers.getContractFactory("PositionERC20");
  console.log("Deploying PositionERC20...");
  const positionImpl = await PositionERC20.deploy(ledger.target);
  await positionImpl.waitForDeployment();
  console.log("✅ PositionERC20 deployed to:", positionImpl.target);

  console.log("Setting PositionERC20 implementation...");
  await ledger.setPositionERC20Implementation(positionImpl.target);
  console.log("✅ Set PositionERC20 implementation");

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
    Permit2: PERMIT2_ADDRESS,
  };

  const filePath = path.join(__dirname, "../deployments.json");
  console.log("Writing deployments file to:", filePath);

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
