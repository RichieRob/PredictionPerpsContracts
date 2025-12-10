require("@nomicfoundation/hardhat-toolbox");
require("hardhat-contract-sizer");
require("dotenv").config(); // Loads .env

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200, // low runs, prioritise size
      },
      viaIR: false,
      debug: {
       // revertStrings: "strip", // strip revert strings to save size
      },
      metadata: {
        bytecodeHash: "none", // minor size saving
      },
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
      // 🔁 Alchemy Sepolia RPC
      // You can inline the URL or keep the key in .env if you prefer
      url: "https://eth-sepolia.g.alchemy.com/v2/3EcbpO5cuhEzDl9bcBUmi",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      chainId: 11155111,
    },

    // mainnet: {
    //   url: "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY",
    //   accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    // },
  },
};
