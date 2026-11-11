# PositionProxy and ProxyManager review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/proxy/position-proxy/PositionProxy.sol`, `src/proxy/proxy-manager/ProxyManager.sol` |
| Spec | [2.5 PositionProxy and ProxyManager](../../../spec/02-contracts/05-position-proxy-and-proxy-manager.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 Low, 3 Informational; fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Low | A proxy inherits external state already at its predicted address (allowances, an Aave position-manager approval, collateral or debt), reachable through a ~2⁸⁰ address collision when the attacker picks the wallet | For contract 20, the Adapter's first pledge asserts the proxy's Spoke account has no collateral and no debt; `REQ-PROXY-055` states the collision assumption | fix queued |
| 2 | Info | `execute` accepts the Adapter or the ProxyManager as target | `execute` refuses `target == ADAPTER` and the ProxyManager | fix queued |
| 3 | Info | `FailedDeployment` missing from the error list | Added to `REQ-PROXY-097` | fix queued |
| 4 | Info | `predictProxy` returns an address for an undeployable triple | Reverts, or documented | fix queued |

## Also queued

Spec: `INV-064` binding names and "fixed creation code"; `INV-016`, `TEST-187`, `PROP-010` old selectors; "holds no tokens or allowances" against `REQ-PROXY-013`; `PROP-076` clauses. Certora: `hashing_length_bound` 224 is below the 1,633-byte init code, so it rises to at least 1,700 or optimistic hashing is disabled; `PositionProxy.spec` adds `value == 0` and a call-happened assertion. Tests: third-party `onBehalfOf = proxy` on a real Spoke, signature and permit attempts, the collision cases.

## PoC tests

- `ProxyReview.t.sol`: `test_PoC_collisionPreStateSurvivesDeploy`, `test_PoC_executeAllowsAdapterAsTarget`, `test_PoC_predictForUndeployableTriple`, `test_PoC_nonceAtPredictedGivesUnlistedError`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
