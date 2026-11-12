# Collateralization review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/custody/collateralization/` (one contract in facets, compiled with via-IR) |
| Spec | [2.3 Collateralization](../../../spec/02-contracts/03-collateralization.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | No Critical, High or Medium; 1 Low, 4 Informational; decided |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Low | `markDebtFree` silently keeps a stale mark when its staticcall fails, and an offboarding market's last debt-free account may never trigger another call, blocking `closeMarket` for good | `markDebtFree` reverts on `!ok && gasleft()` below a floor; a permissionless `refreshDebtMark(proxy)` entry through the Adapter | decided |
| 2 | Info | Seizure order is insertion order, not credited-descending after partial changes | `SPEC-BACK-006` and `INV-015` corrected; the per-record charge and rescue effect stated | decided |
| 3 | Info | Halmos and Echidna harnesses compile the facets on the legacy pipeline while the deployed contract is via-IR | Noted; unit, fuzz and Certora carry the deployed code | accepted |
| 4 | Info | `depositor == 0` accepted | Rejected | decided |
| 5 | Info | Worst-case gas of a 16-record seizure plus reconcile (about 4–5M with real v3 unwinds) | Measured on the fork | decided |

## Also decided

Spec: `REQ-LOCK-017` against `REQ-VAULT-053`/`131` ordering; `REQ-COLL-040` "only delays"; 9 stale LIFECYCLE anchors. Tests: a stateful invariant on the real contract with Aave for `INV-001`/`INV-008`, `markDebtFree` failure modes, re-credit after partial seizure, an 8-token market, the gas test.

## PoC tests

- `Collateralization.Review.unit.t.sol`: `test_POC_orderDivergesFromCreditedDescending`, `test_POC_markDebtFreeSilentUnderGasLimit`, `test_POC_settleSeizureGas16Records`, `testFuzz_POC_backingSequence`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; for each fixed finding, a regression test in `contracts/test/` asserts the fixed behavior.
