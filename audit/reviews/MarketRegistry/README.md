# MarketRegistry review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/policy/market-registry/` (router plus six immutable delegatecall logic contracts) |
| Spec | [2.8 MarketRegistry](../../../spec/02-contracts/08-market-registry.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 Medium, 1 Medium/Low, 6 Low, 4 Informational; fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium | `deployCdpSpoke` compares the Spoke implementation's code hash with one standard implementation, but Aave V4 Spokes keep `ORACLE` and `MAX_USER_RESERVES_LIMIT` as immutables, so a second CDP Spoke always fails | A set of approved Spoke-implementation code hashes, each added through the timelock at the normal delay | fix queued |
| 2 | Medium/Low | `syncDrawCap` can hide a raise while coverage is short | Always record the live draw cap; enforce coverage as a separate gate (`REQ-CONFIG-081` reordered) | fix queued |
| 3 | Low | `closeMarket` can run in the same block as offboarding | Requires the notice period after `offboardedAt` | fix queued |
| 4 | Low | The protected set misses each integration's position manager and factory | Added | fix queued |
| 5 | Low | The own-pool route check misses Id-keyed markets | Covers the singleton plus pool id | fix queued |
| 6 | Low | A fixed-price debt asset can be enabled unlisted | Must be listed with its issuer probe | fix queued |
| 7 | Low | After the DAO's `cancelStandbySwitch` the guardian can switch again at once | Blocked until a timelocked `restoreRoute` or a cooldown | fix queued |
| 8 | Low | No view of the wind-down state | View added | fix queued |
| 9 | Info | No event for `setFlashSource` or the new credit line | Events added | fix queued |
| 10 | Info | "Rolling 24 hours" freeze limit is implemented as hour buckets | Reworded to hour buckets | fix queued |
| 11 | Info | The drift view does not check underlying and asset id | Checked | fix queued |
| 12 | Info | Relisting keeps the cancelled registration's routes, approvals and latches | Cleared on relisting | fix queued |

## Also queued

Spec: 1.4 keeper-floor sentence against `REQ-MREG-021`; 2.8 Inputs `isApprovedKeeper`; `DebtReserveEnabled` → `DebtReserveApproved`; coverage on `line` against `Σ drawCap` and units; `REQ-CONFIG-040` against the `dependencies` NatSpec; `REQ-MREG-033` `settlementReserve` (used by `settlePending` in contract 23); stale storage and breaker rows. Tests: two real Spokes, each case above, symbolic uniqueness and status machine, a storage-layout assertion.

## PoC tests

- `MarketRegistry.Review.unit.t.sol`: `test_PoC_secondCdpSpokeRefusedByCodehash`, `test_PoC_syncDrawCapRaiseHiddenWhenCoverageShort`, `test_PoC_closeMarketSameBlockAsOffboarding`, `test_PoC_freeze40In23Hours`, `test_PoC_guardianReswitchesAfterDaoCancel`, `test_PoC_fixedPriceDebtAssetEnabledUnlisted`, `test_PoC_setFlashSourceEmitsNoEvent`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
