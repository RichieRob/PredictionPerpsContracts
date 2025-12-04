// test/helpers/intents.js
const { ethers } = require("hardhat");

const INTENT_TYPES = {
  Intent: [
    { name: "trader",        type: "address" },
    { name: "marketId",      type: "uint256" },
    { name: "positionId",    type: "uint256" },
    { name: "isBack",        type: "bool"    },
    { name: "kind",          type: "uint8"   },
    { name: "primaryAmount", type: "uint256" },
    { name: "bound",         type: "uint256" },
    { name: "nonce",         type: "uint256" },
    { name: "deadline",      type: "uint256" },
  ],
};

async function intentDomain(intentContract) {
  const net = await ethers.provider.getNetwork();
  return {
    name: "PredictionPerps-Intents",
    version: "1",
    chainId: net.chainId,
    verifyingContract: await intentContract.getAddress(), // 🔸 now IntentContract
  };
}

async function signIntent(intentContract, signer, intent) {
  const domain = await intentDomain(intentContract);
  const signature = await signer.signTypedData(domain, INTENT_TYPES, intent);
  return signature;
}

module.exports = {
  INTENT_TYPES,
  intentDomain,
  signIntent,
};
