Implementation pending: links point to interfaces; update to implementation functions once the hand-written contracts exist.

# AMM integration lifecycle

`IAmmIntegration` and `IAmmIntegrationHooks` are the AMM-neutral surface every LPVault implements, so Collateralization, the LPOracle, the RiskModule and the Lens handle a Uniswap v3 NFT, a Slipstream NFT or a fungible LP share the same way: a position is `(integrationId, positionKey)` and every amount is an array in the market's token order.

## Walkthrough

Setup (Ethereum market 1, Uniswap v3 USDC/USDT 0.01%, exact range `[−887,272, 887,272]`, `tokens = [USDC, USDT]`, from 3.1).

1. **VaultTokenFactory `registerIntegration`** reads [`INTEGRATION_ID`](IAmmIntegration.sol#L31), [`AMM_PROTOCOL`](IAmmIntegration.sol#L36) (`keccak256("UNISWAP_V3")`) and [`capabilities`](IAmmIntegration.sol#L41).
2. **MarketRegistry → [`bindMarket`](IAmmIntegration.sol#L58)** at listing; [`marketOf`](IAmmIntegration.sol#L69) returns the pool, shape and tokens afterwards; [`riskMetadata`](IAmmIntegration.sol#L216) feeds the listing checks.
3. **Lens → [`validatePosition`](IAmmIntegration.sol#L134)`(1, W, key)`**: 25,000,000,000 units for the NFT on the exact range; a `[−10, 10]` NFT is refused because it would be credited about 2,000 times its value. [`positionOwner`](IAmmIntegration.sol#L125) reads the AMM's owner.
4. **Collateralization → [`checkReadSafe`](IAmmIntegrationHooks.sol#L17), [`receivePosition`](IAmmIntegration.sol#L88)**; afterwards [`depositorOf`](IAmmIntegration.sol#L235), [`marketOfPosition`](IAmmIntegration.sol#L241) and [`unitsOf`](IAmmIntegration.sol#L249) answer for the key.
5. **LPOracle → [`composition`](IAmmIntegration.sol#L159)`(1, 10^6, [1e8, 1e8])`** = about 1 USDC + 1 USDT per whole vault token (each floored, less 1 raw unit), so $2.00; [`consistencyDeviation`](IAmmIntegrationHooks.sol#L29) compares the pool's time-weighted price with the oracle within `consistencyToleranceBps` (0.5%); [`effectiveSupply`](IAmmIntegrationHooks.sol#L63) and [`rateProviders`](IAmmIntegrationHooks.sol#L39) return neutral values for concentrated liquidity.
6. **RiskModule → [`riskStatus`](IAmmIntegration.sol#L227)** over `twapWindow` (30 min): in-range liquidity 40,000,000,000,000, so Avana's 1,525,000,000,000 units are 3.81% of the pool, under an illustrative per-pool cap of 10% (`poolShareMaxBpsOf`; default 10,000 bps, off).
7. **Collateralization → [`collectFees`](IAmmIntegration.sol#L207), [`releaseToDepositor`](IAmmIntegration.sol#L191), [`unwind`](IAmmIntegration.sol#L179), [`topUpPosition`](IAmmIntegration.sol#L114), [`returnPosition`](IAmmIntegration.sol#L100)** for fees (41.25 USDC + 39.87 USDT after 30 days), partial removal, liquidation unwind (Alice's 4,998 vault tokens give about 4,998 USDC + 4,998 USDT), fungible-share top-ups and exit.
8. **Native ETH legs** are wrapped before payment ([`wrappedNative`](IAmmIntegrationHooks.sol#L47)); a Uniswap v4 hook is accepted only if allowlisted ([`isAllowedPoolHook`](IAmmIntegrationHooks.sol#L54)).

Protocol-specific steps: [Uniswap v3](uniswap-v3/LIFECYCLE.md), [Aerodrome Slipstream](slipstream/LIFECYCLE.md); the custody side is in [LPVault](../custody/lp-vault/LIFECYCLE.md).

## What the UI reads and calls

- Lens: [`getRecords`](../lens/lens/ILensAccount.sol#L45), [`checkRecordBacking`](../lens/lens/ILensMarket.sol#L31), [`getCapHeadroom`](../lens/lens/ILensMarket.sol#L51); direct [`validatePosition`](IAmmIntegration.sol#L134) before a pledge.
- Events to index: the LPVault's events ([ILPVaultEvents.sol](../custody/lp-vault/ILPVaultEvents.sol)).
- User calls: none.

## Spec

- [2.19 AMM Integration Interface](../../../spec/02-contracts/19-amm-integration-interface.md): `REQ-AMM-CORE-001`–`REQ-AMM-CORE-012`, `SPEC-ORC-007` (composition).
- [2.22 AMM Integration Readiness](../../../spec/02-contracts/22-amm-integration-readiness.md) for Uniswap v2, Curve, Balancer and Uniswap v4.
