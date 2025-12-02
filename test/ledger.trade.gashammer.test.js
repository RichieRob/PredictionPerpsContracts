// test/ledger.trade.gashammer.test.js
//
// DO NOT declare describe() or it() here.
// This is a simple runner that manually invokes Hardhat twice.
//

const { execSync } = require("child_process");
const path = require("path");

function run(cmd) {
  console.log(`\n▶ ${cmd}\n`);
  execSync(cmd, { stdio: "inherit" });
}

async function main() {
  const basic = path.join("test", "ledger.trade.gashammer.basic.test.js");
  const sized = path.join("test", "ledger.trade.gashammer.size.test.js");

  run(`npx hardhat test ${basic}`);
  run(`npx hardhat test ${sized}`);
}

main();
