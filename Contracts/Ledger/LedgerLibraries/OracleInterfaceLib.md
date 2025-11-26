Oracle Implementation in Prediction Market Ledger
Overview
This document describes the oracle implementation for the prediction market ledger. The system is designed to be fully oracle-agnostic, allowing market creators to specify any oracle (e.g., Chainlink, UMA, Pyths, custom feeds, or off-chain resolvers) at market creation. The ledger remains neutral—it calls a standard interface to fetch resolution data without assuming any specific oracle logic.
The implementation ties into the doesResolve flag: for resolving markets (doesResolve = true), an oracle is required, and DMM/ISC are blocked. For non-resolving markets (e.g., perpetuals), oracles are optional. This ensures flexibility while enforcing safety rules.
Key goals:

Agnosticism: Ledger doesn't hardcode oracle types; it uses a simple interface.
Modularity: Oracles are external wrappers implementing the interface.
Permissionless Resolution: Anyone can trigger resolution if oracle data is ready.
Immutable Setup: Oracle details are set at creation and cannot change.
Gas Efficiency: Resolution is pull-based (caller pays), view-only where possible.

Principles for Oracle-Agnostic Design

Standard Interface: All oracles must implement a minimal IOracle interface for compatibility.
Creation-Time Config: Oracle address and custom parameters (e.g., query ID, feed key) are passed to createMarket and stored immutably.
Enforcement for Resolving Markets: If doesResolve = true, require oracle + params; revert if missing. Block DMM/ISC as per rules.
Non-Resolving Markets: Oracle optional (can be address(0)); resolution functions revert if called.
Permissionless Trigger: resolveFromOracle can be called by anyone—reverts if data not ready (allows retries).
Oracle Pull Model: Ledger queries the oracle in a view call; no pushes or callbacks.
Failure Handling: If oracle data isn't ready (e.g., pending dispute), revert resolution attempt.
Extensibility: Users/community can deploy wrappers for specific oracles (e.g., Chainlink adapter) without changing the ledger.

Oracle Interface Definition
Define this interface in Interfaces/IOracle.sol. It's minimal to support any oracle type.
solidity// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    /**
     * @notice Returns the resolution outcome for a market.
     * @param marketId The market ID to resolve.
     * @param params Custom parameters stored at market creation (e.g., query ID, feed key).
     * @return isResolved True if data is ready.
     * @return winningPositionId The winning position ID (or 0 if invalid/not ready).
     */
    function getResolutionData(uint256 marketId, bytes calldata params) external view returns (bool isResolved, uint256 winningPositionId);
}

Why this interface?
isResolved: Allows oracles to signal "not ready" (e.g., liveness not expired, dispute pending).
winningPositionId: Maps oracle outcome to your positionId (e.g., true/false → position 1/2).
params: Bytes for flexibility (e.g., abi-encoded query details).
View-only: Keeps gas low, no state change.


Any oracle wrapper can implement this—ledger calls it blindly.
Storage for Oracle Details
Add these to StorageLib.Storage (scoped by marketId, immutable after creation):
solidity// For oracle-agnostic resolution
mapping(uint256 => address) public marketOracle;  // oracle contract address (address(0) if none)
mapping(uint256 => bytes) public marketOracleParams;  // custom params (e.g., query ID, feed key) for the oracle

Stored at creation, never changed.
For non-resolving markets: Can be empty (address(0) and "").

Functions
createMarket (Updated)
Handles oracle setup with safety checks. Enforce rules based on doesResolve.
solidityfunction createMarket(
    string memory name,
    string memory ticker,
    address dmm,
    uint256 iscAmount,
    bool doesResolve,
    address oracle,
    bytes calldata oracleParams
) internal returns (uint256 marketId) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    
    if (doesResolve) {
        require(dmm == address(0), "Resolving markets cannot have DMM");
        require(iscAmount == 0, "Resolving markets cannot have ISC");
        require(oracle != address(0), "Resolving markets require oracle");
        // Optional: require(oracleParams.length > 0) if needed
    } else {
        require(s.allowedDMMs[dmm], "DMM not allowed");
        require(oracle == address(0), "no Oracle allowed");
        require(oracledParms.length == 0, "Oracle Params should be blank")
    }

    marketId = s.nextMarketId++;
    s.allMarkets.push(marketId);

    // ✅ use our own metadata
    s.marketNames[marketId] = name;
    s.marketTickers[marketId] = ticker;

    s.marketToDMM[marketId] = dmm;
    s.syntheticCollateral[marketId] = iscAmount;

    // Store immutable resolve flag and oracle details
    s.doesResolve[marketId] = doesResolve;
    s.marketOracle[marketId] = oracle;
    s.marketOracleParams[marketId] = oracleParams;

    emit MarketCreated(marketId, name, ticker);
    emit SyntheticLiquidityCreated(marketId, iscAmount, dmm);

    s.isExpanding[marketId] = true;
}

Integration: Call with oracle args when creating resolving markets.
Events: Add emit OracleConfigured(marketId, oracle, oracleParams); if desired.

resolveFromOracle (Permissionless Trigger)
Triggers resolution by querying the market's oracle. Reverts if not ready.
solidityfunction resolveFromOracle(uint256 marketId) external {
    StorageLib.Storage storage s = StorageLib.getStorage();
    require(s.doesResolve[marketId], "Market does not resolve");
    require(!s.marketResolved[marketId], "Already resolved");
    require(s.marketOracle[marketId] != address(0), "No oracle set");

    IOracle oracle = IOracle(s.marketOracle[marketId]);
    (bool isResolved, uint256 winningPositionId) = oracle.getResolutionData(marketId, s.marketOracleParams[marketId]);

    require(isResolved, "Oracle data not ready");
    require(2_MarketManagementLib.positionExists(marketId, winningPositionId), "Invalid winner from oracle");

    s.marketResolved[marketId] = true;
    s.winningPositionId[marketId] = winningPositionId;

    emit MarketResolved(marketId, winningPositionId);
}

Permissionless: Anyone can call (gas payer = caller).
Retrying: If not ready, revert—call again later.
Manual Fallback: Keep your owner-only resolveMarket for emergencies (e.g., oracle fails).
Gas: ~50k + oracle view call (cheap).

Integration & Edge Cases

Market Creation:
Resolving: createMarket(..., true, oracleAddress, abi.encode(params));
Non-resolving: createMarket(..., false, address(0), "");

Resolution Flow:
Anyone calls resolveFromOracle(marketId) when oracle data is ready.
If oracle says "not ready," revert—retry later.
Once resolved, market is settled (triggers auto-claim on user interactions).

Oracle-Specific Wrappers: Deploy separate contracts implementing IOracle for each oracle type (e.g., UMAWrapper.sol). Ledger calls the wrapper.
Edges:
Non-Resolving Markets: resolveFromOracle reverts (no oracle).
Oracle Failure: Revert; use owner fallback or timeout to manual resolve.
Disputes: Oracle wrapper handles (e.g., return isResolved = false if disputed).
Multi-Outcome: Oracle returns appropriate positionId.
Params Flexibility: bytes calldata supports any encoding (e.g., for UMA: abi.encode(question, bond)).
Gas Bomb Prevention: Oracles should be view-only; wrappers limit complexity.

Testing: Mock oracles for tests (e.g., a simple contract that returns hardcoded data).

Why This Is Oracle-Agnostic

No Hardcoding: Ledger only knows IOracle—any compliant wrapper works.
Extensibility: New oracles? Deploy new wrapper, pass its address in createMarket.
Decentralized/Trustless: Supports trust-minimized oracles like UMA (disputable) or Chainlink (decentralized feeds).
Future-Proof: Upgrade to new oracles by creating new markets—old ones stay intact.
Cost: Caller pays for resolution trigger; oracles can be incentivized (e.g., bounties for calling).

This design ensures the ledger remains neutral while supporting any oracle ecosystem. For specific oracle wrappers, implement IOracle in separate contracts.2.9s