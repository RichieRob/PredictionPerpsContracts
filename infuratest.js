// infura-write-hang-test.js
//
// Minimal repro for Infura Sepolia issue:
// - Reads (getBlockNumber) succeed
// - Writes (sendTransaction) hang and never resolve
//
// Usage:
//   1. Set INFURA_PROJECT_ID and PRIVATE_KEY in your .env
//   2. Run: node infura-write-hang-test.js

require("dotenv").config();
const { ethers } = require("ethers");

async function main() {
  const projectId = process.env.INFURA_PROJECT_ID;
  const pk = process.env.PRIVATE_KEY;

  if (!projectId) {
    console.error("Missing INFURA_PROJECT_ID in .env");
    process.exit(1);
  }
  if (!pk) {
    console.error("Missing PRIVATE_KEY in .env");
    process.exit(1);
  }

  const url = `https://sepolia.infura.io/v3/${projectId}`;
  console.log("Using Infura URL:", url);

  // Use the same Node version you’re currently on to show them
  console.log("Node version:", process.version);

  const provider = new ethers.JsonRpcProvider(url);
  const wallet = new ethers.Wallet(pk, provider);

  console.log("Test wallet address:", wallet.address);

  // ─────────────────────────────────────────
  // 1) READ TEST – show that RPC works for reads
  // ─────────────────────────────────────────
  console.log("\n[1] Testing read: provider.getBlockNumber() ...");
  const blockBefore = await provider.getBlockNumber();
  console.log("✅ getBlockNumber succeeded. Current block:", blockBefore.toString());

  // ─────────────────────────────────────────
  // 2) WRITE TEST – send 0 ETH to self and detect hang
  // ─────────────────────────────────────────
  console.log("\n[2] Testing write: wallet.sendTransaction() ...");

  // Hard-coded sane gas parameters for Sepolia (should *definitely* be accepted)
  const txRequest = {
    to: wallet.address,
    value: 0n,                          // 0 ETH transfer, just to test sending
    gasPrice: 5n * 10n ** 9n,           // 5 gwei
    gasLimit: 21000n,
  };

  console.log("Transaction request:", txRequest);

  const SEND_TIMEOUT_MS = 60_000;

  // Helper: race a promise with a timeout to prove hanging behaviour
  async function withTimeout(label, promise, timeoutMs) {
    return Promise.race([
      promise.then((value) => ({ type: "ok", value })),
      new Promise((resolve) =>
        setTimeout(
          () => resolve({ type: "timeout", value: null }),
          timeoutMs
        )
      ),
    ]).then((result) => {
      if (result.type === "timeout") {
        console.error(`❌ ${label} timed out after ${timeoutMs / 1000}s (no response from node).`);
      } else {
        console.log(`✅ ${label} completed.`);
      }
      return result;
    });
  }

  console.log(`\nSending transaction (timeout: ${SEND_TIMEOUT_MS / 1000}s)...`);

  // 2a) sendTransaction (this is where it appears to hang)
  const sendResult = await withTimeout(
    "wallet.sendTransaction",
    wallet.sendTransaction(txRequest),
    SEND_TIMEOUT_MS
  );

  if (sendResult.type === "timeout") {
    console.error(
      "\nRESULT: Reads succeed but sendTransaction never returns. " +
        "This suggests an issue with eth_sendRawTransaction handling on this Infura endpoint."
    );
    process.exit(1);
  }

  const tx = sendResult.value;
  console.log("Transaction hash:", tx.hash);

  // 2b) wait for the transaction to be mined (just in case it gets that far)
  const receiptTimeoutMs = 60_000;
  console.log(`\nWaiting for receipt (timeout: ${receiptTimeoutMs / 1000}s)...`);

  const receiptResult = await withTimeout(
    "provider.waitForTransaction",
    provider.waitForTransaction(tx.hash),
    receiptTimeoutMs
  );

  if (receiptResult.type === "timeout") {
    console.error(
      "\nRESULT: sendTransaction returned a hash, but waitForTransaction " +
        "never completed within the timeout."
    );
    process.exit(1);
  }

  console.log("Receipt:", receiptResult.value);

  console.log("\nFINAL RESULT: Both read and write operations completed successfully on this run.");
}

main().catch((err) => {
  console.error("\n❌ Script threw an error:", err);
  process.exit(1);
});
