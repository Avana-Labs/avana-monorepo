# VaultTokenFactory review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/vault-token/vault-token-factory/VaultTokenFactory.sol` |
| Spec | [2.4 Vault Tokens](../../../spec/02-contracts/04-vault-tokens.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 2 Low, 1 Informational; fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Low | The factory accepts non-canonical shapes and pool keying (`ShapeKind.None`, `FullPool` with non-zero ticks, inverted or full-range `TickRange`, a pool passed as `poolId`), so one pool can get several tokens on one Spoke unless every `bindMarket` refuses them | Check `kind != None`, `FullPool` ⇒ ticks 0, `TickRange` ⇒ `lower < upper`; record the integration's `PoolKeying` at registration | fix queued |
| 2 | Low | `registerIntegration` accepts an LPVault wired to a foreign timelock or registry | Also check the LPVault's `TIMELOCK()` and `MARKET_REGISTRY()`, `AMM_PROTOCOL != 0`, and that Collateralization points back at the factory | fix queued |
| 3 | Info | `marketId` and name/symbol length unbounded; thin `VaultTokenDeployed` event | `marketId < 2³²`, length bounds, fuller event | fix queued |

## Also queued

For contract 7, `REQ-CONFIG-032` also requires `token.marketKey() == marketKeyOf(def)`, `integrationId()` and `tokenOf(spoke, key) == token`. Stale text in 2.8 and `INV-017`; `REQ-ARCH-207` against `Q-355` on relisting; `PROP-034`/`055` tags. Tests for CREATE3 failure rollback and hostile getters; Certora rules for write-once `lpVaultOf`, monotone `isVaultToken`, timelock-only registration and a `satisfy` reachability check.

## PoC tests

- `VaultTokenFactoryReview.t.sol`: `test_PoC_nonCanonicalShapeAndKeying_manyTokensOneMarket`, `test_PoC_lpVaultWithForeignTimelockAndRegistryAccepted`, `test_PoC_emptyNameAndHugeMarketIdAccepted`, `test_PoC_sameMarketTwoSpokesConcurrently`, `test_PoC_registrationWithCodelessCollateralizationReverts`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
