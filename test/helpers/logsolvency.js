async function logSolvency(label, fx) {
    const { ledger, marketId, alice, bob } = fx;
  
    console.log(`\n=== ${label} – solvency state ===`);
    for (const who of [
      { name: "Alice", addr: alice.address },
      { name: "Bob",   addr: bob.address },
    ]) {
      const effMin = await ledger.invariant_effectiveMin(who.addr, marketId);
      const [netAlloc, redeemable, margin] =
        await ledger.invariant_redeemabilityState(who.addr, marketId);
  
      console.log(
        who.name,
        "effMin", effMin.toString(),
        "netAlloc", netAlloc.toString(),
        "redeemable", redeemable.toString(),
        "margin", margin.toString()
      );
    }
  }
  