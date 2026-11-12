Function links point to the interface that declares each function.

# AMM integration lifecycle

`IAmmIntegration` and `IAmmIntegrationHooks` are the AMM-neutral surface every LPVault implements, so Collateralization, the LPOracle, the RiskModule and the Lens handle a Uniswap v3 NFT, a Slipstream NFT or a fungible LP share the same way: a position is `(integrationId, positionKey)` and every amount is an array in the market's token order.

## Walkthrough

Setup (Ethereum market 1, Uniswap v3 USDC/USDT 0.01%, exact range `[−887,272, 887,272]`, `tokens = [USDC, USDT]`, from 3.1).

1. **VaultTokenFactory `registerIntegration`** reads [`INTEGRATION_ID`](IAmmIntegration.sol#L33), [`AMM_PROTOCOL`](IAmmIntegration.sol#L38) (`keccak256("UNISWAP_V3")`) and [`capabilities`](IAmmIntegration.sol#L43).
2. **MarketRegistry → [`bindMarket`](IAmmIntegration.sol#L60)** at listing; [`marketOf`](IAmmIntegration.sol#L71) returns the pool, shape and tokens afterwards. [`riskMetadata`](IAmmIntegration.sol#L218) is a view for off-chain listing review; no Avana contract calls it.
3. **RiskModule `previewPledge` → [`positionOwner`](IAmmIntegration.sol#L127), then [`validatePosition`](IAmmIntegration.sol#L136)`(1, W, key)`**: the owner must be `W`; 25,000,000,000 units for the NFT on the exact range; a `[−10, 10]` NFT is refused because it would be credited about 2,000 times its value. The app may also call `validatePosition` directly.
4. **Collateralization → [`checkReadSafe`](IAmmIntegrationHooks.sol#L19), [`receivePosition`](IAmmIntegration.sol#L90)**; afterwards [`depositorOf`](IAmmIntegration.sol#L237), [`marketOfPosition`](IAmmIntegration.sol#L243) and [`unitsOf`](IAmmIntegration.sol#L251) answer for the key.
5. **The LPOracle prices the market with its own pricing module**, not through the integration: its `_composition` gives about 1 USDC + 1 USDT per whole vault token at `[1e8, 1e8]` (each floored, less 1 raw unit), so $2.00, and its `_consistency` compares the pool's time-weighted price with the oracle within `consistencyToleranceBps` (0.5%). The integration's [`composition`](IAmmIntegration.sol#L161), [`consistencyDeviation`](IAmmIntegrationHooks.sol#L31), [`effectiveSupply`](IAmmIntegrationHooks.sol#L65) and [`rateProviders`](IAmmIntegrationHooks.sol#L41) are views of the integration; no Avana contract calls them.
6. **RiskModule → [`riskStatus`](IAmmIntegration.sol#L229)** over `twapWindow` (30 min): in-range liquidity 40,000,000,000,000, so Avana's 1,525,000,000,000 units are 3.81% of the pool, under an illustrative per-pool cap of 10% (`poolShareMaxBpsOf`; default 10,000 bps, off).
7. **Collateralization → [`collectFees`](IAmmIntegration.sol#L209), [`releaseToDepositor`](IAmmIntegration.sol#L193), [`unwind`](IAmmIntegration.sol#L181), [`topUpPosition`](IAmmIntegration.sol#L116), [`returnPosition`](IAmmIntegration.sol#L102)** for fees (41.25 USDC + 39.87 USDT after 30 days), partial removal, liquidation unwind (Alice's 4,998 vault tokens give about 4,998 USDC + 4,998 USDT), fungible-share top-ups and exit.
8. **Native ETH legs and pool hooks**: [`wrappedNative`](IAmmIntegrationHooks.sol#L49) names the wrapped token an integration uses for a native ETH leg, and [`isAllowedPoolHook`](IAmmIntegrationHooks.sol#L56) reports whether a pool hook is allowlisted; both are views no Avana contract calls today (Uniswap v3 and Slipstream have neither native legs nor hooks).

Protocol-specific steps: [Uniswap v3](uniswap-v3/LIFECYCLE.md), [Aerodrome Slipstream](slipstream/LIFECYCLE.md); the custody side is in [LPVault](../custody/lp-vault/LIFECYCLE.md).

## What the UI reads and calls

- Lens: [`getRecords`](../lens/lens/ILensAccount.sol#L47), [`checkRecordBacking`](../lens/lens/ILensMarket.sol#L33), [`getCapHeadroom`](../lens/lens/ILensMarket.sol#L53); direct [`validatePosition`](IAmmIntegration.sol#L136) before a pledge.
- Events to index: the LPVault's events ([ILPVaultEvents.sol](../custody/lp-vault/ILPVaultEvents.sol)).
- User calls: none.

## Spec

- [2.19 AMM Integration Interface](../../../spec/02-contracts/19-amm-integration-interface.md): `REQ-AMM-CORE-001`–`REQ-AMM-CORE-012`, `SPEC-ORC-007` (composition).
- [2.22 AMM Integration Readiness](../../../spec/02-contracts/22-amm-integration-readiness.md) for Uniswap v2, Curve, Balancer and Uniswap v4.
