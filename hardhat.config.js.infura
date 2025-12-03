require("@nomicfoundation/hardhat-toolbox");
require('hardhat-contract-sizer');
require("dotenv").config();  // Loads .env

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1,  // Low value prioritizes size; try 0 if still over limit
      },
      viaIR: true,
      debug: {
        revertStrings: "strip"  // CRITICAL: Strips all revert strings to save size
      },
      metadata: {
        bytecodeHash: "none"  // Removes metadata hash (minor savings)
      }
    },
  },
  paths: {
    sources: "./Contracts",
    libraries: "./node_modules",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  networks: {
    hardhat: {
      allowUnlimitedContractSize: true, 
        },

        sepolia: {
          url: `https://sepolia.infura.io/v3/${process.env.INFURA_PROJECT_ID}`,
          accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
          chainId: 11155111,
        },
    // Add mainnet config if needed, e.g.:
    // mainnet: { url: "YOUR_RPC", accounts: ["YOUR_PRIVATE_KEY"] }
  },
};