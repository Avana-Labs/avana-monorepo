# MarketRegistry review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/policy/market-registry/` (router plus six immutable delegatecall logic contracts) |
| Spec | [2.8 MarketRegistry](../../../spec/02-contracts/08-market-registry.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 Medium, 1 Medium/Low, 6 Low, 4 Informational; decided |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium | `deployCdpSpoke` compares the Spoke implementation's code hash with one standard implementation, but Aave V4 Spokes keep `ORACLE` and `MAX_USER_RESERVES_LIMIT` as immutables, so a second CDP Spoke always fails | A set of approved Spoke-implementation code hashes, each added through the timelock at the normal delay | decided |
| 2 | Medium/Low | `syncDrawCap` can hide a raise while coverage is short | Always record the live draw cap; enforce coverage as a separate gate (`REQ-CONFIG-081` reordered) | decided |
| 3 | Low | `closeMarket` can run in the same block as offboarding | Requires the notice period after `offboardedAt` | decided |
| 4 | Low | The protected set misses each integration's position manager and factory | Added | decided |
| 5 | Low | The own-pool route check misses Id-keyed markets | Covers the singleton plus pool id | decided |
| 6 | Low | A fixed-price debt asset can be enabled unlisted | Must be listed with its issuer probe | decided |
| 7 | Low | After the DAO's `cancelStandbySwitch` the guardian can switch again at once | Blocked until a timelocked `restoreRoute` or a cooldown | decided |
| 8 | Low | No view of the wind-down state | View added | decided |
| 9 | Info | No event for `setFlashSource` or the new credit line | Events added | decided |
| 10 | Info | "Rolling 24 hours" freeze limit is implemented as hour buckets | Reworded to hour buckets | decided |
| 11 | Info | The drift view does not check underlying and asset id | Checked | decided |
| 12 | Info | Relisting keeps the cancelled registration's routes, approvals and latches | Cleared on relisting | decided |

## Also decided

Spec: 1.4 keeper-floor sentence against `REQ-MREG-021`; 2.8 Inputs `isApprovedKeeper`; `DebtReserveEnabled` → `DebtReserveApproved`; coverage on `line` against `Σ drawCap` and units; `REQ-CONFIG-040` against the `dependencies` NatSpec; `REQ-MREG-033` `settlementReserve` (used by LPVaultSwap's `settlePending`); stale storage and breaker rows. Tests: two real Spokes, each case above, symbolic uniqueness and status machine, a storage-layout assertion.

## PoC tests

- `MarketRegistry.Review.unit.t.sol`: `test_PoC_secondCdpSpokeRefusedByCodehash`, `test_PoC_syncDrawCapRaiseHiddenWhenCoverageShort`, `test_PoC_closeMarketSameBlockAsOffboarding`, `test_PoC_freeze40In23Hours`, `test_PoC_guardianReswitchesAfterDaoCancel`, `test_PoC_fixedPriceDebtAssetEnabledUnlisted`, `test_PoC_setFlashSourceEmitsNoEvent`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; for each fixed finding, a regression test in `contracts/test/` asserts the fixed behavior.
