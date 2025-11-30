// scripts/deployCore.js
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

  // Deploy mocks
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const mockUSDC = await MockUSDC.deploy();
  await mockUSDC.waitForDeployment();
  console.log("MockUSDC deployed to:", mockUSDC.target);

  const MockAUSDC = await ethers.getContractFactory("MockAUSDC");
  const mockAUSDC = await MockAUSDC.deploy();
  await mockAUSDC.waitForDeployment();
  console.log("MockAUSDC deployed to:", mockAUSDC.target);

  const MockAavePool = await ethers.getContractFactory("MockAavePool");
  const mockAavePool = await MockAavePool.deploy(mockUSDC.target, mockAUSDC.target);
  await mockAavePool.waitForDeployment();
  console.log("MockAavePool deployed to:", mockAavePool.target);

  const PpUSDC = await ethers.getContractFactory("PpUSDC");
  const ppUSDC = await PpUSDC.deploy();
  await ppUSDC.waitForDeployment();
  console.log("PpUSDC deployed to:", ppUSDC.target);

  const PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

  // Deploy Ledger with mocks
  const Ledger = await ethers.getContractFactory("Ledger");
  const ledger = await Ledger.deploy(
    mockUSDC.target,
    mockAUSDC.target,
    mockAavePool.target,
    PERMIT2_ADDRESS, // permit2
    ppUSDC.target
  );
  await ledger.waitForDeployment();
  console.log("Ledger deployed to:", ledger.target);

  await ppUSDC.setLedger(ledger.target);
  console.log("Set PpUSDC ledger");

  // Deploy PositionERC20
  const PositionERC20 = await ethers.getContractFactory("PositionERC20");
  const positionImpl = await PositionERC20.deploy(ledger.target);
  await positionImpl.waitForDeployment();
  console.log("PositionERC20 deployed to:", positionImpl.target);

  await ledger.setPositionERC20Implementation(positionImpl.target);
  console.log("Set PositionERC20 implementation");

  // Save addresses to file
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
  let existingData = {};
  if (fs.existsSync(filePath)) {
    existingData = JSON.parse(fs.readFileSync(filePath, "utf8"));
  }
  existingData.core = deployments;
  fs.writeFileSync(filePath, JSON.stringify(existingData, null, 2));
  console.log(`Core deployments saved to ${filePath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});