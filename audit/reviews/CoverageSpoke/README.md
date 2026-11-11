# CoverageSpoke (Avana Umbrella) review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/coverage/coverage-spoke/CoverageSpoke.sol` |
| Spec | [2.14 First-Loss Reserve](../../../spec/02-contracts/14-first-loss-reserve.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 Medium, 1 Low, plus trust and text points; decided, fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium (M-1) | Dust funding reverts on zero shares, and Hub yield can fill the `addCap` so `fund` reverts | Every Coverage Spoke is listed with `addCap = MAX` (it receives only Avana's funding); for contract 23, `settlePending` skips `fund` when R is below one share's value and carries it to the next settlement | fix queued |
| 2 | Low (L-1) | `executeWithdrawal` can drain the reserve while a deficit is uncovered | `executeWithdrawal` reverts while the Hub records a deficit on that asset for any allowlisted Spoke; the request stays Pending | fix queued |
| 3 | Trust | The DAO's AccessManager can make coverage public or change authority | Stated as a trust assumption; `COVERAGE_ROLE` held by the Emergency Guardian and the Aave Protocol Guardian, granted in the DAO's listing payload; no Avana contract or deployer holds a role | fix queued |
| 4 | Spec | `totalCovered` can exceed `totalFunded` through yield | `SPEC-FLR-002` identity stated as signed | fix queued |

## Also queued

`fundingAssetId` → `hubAssetId`; `REQ-FLR-037`/`038` name the `settlePending` reverts; `REQ-FLR-017` says the on-chain check is `isSpokeListed`; the default wording removed from `REQ-FLR-021` and 1.5; tests for dust funding, the cap, a withdrawal with an open deficit, real-Hub yield in the Echidna property, AccessManager delays. The two `PROP-039` Halmos checks time out on the RAY division and rely on fuzz twins.

## PoC tests

- `CoverageSpoke.Review.t.sol`: `test_PoC_dustFundRevertsInvalidShares`, `test_PoC_yieldFillsAddCapBlocksFund`, `test_PoC_withdrawalDrainsReserveWithUncoveredDeficit`, `test_PoC_withdrawalBlockedByUtilization`, `test_PoC_dustSharesStrandedAfterFullCoverage`, `test_PoC_daoCanMakeCoveragePublicAndSwapAuthority`, `testFuzz_PoC_netFundingVsBalance`, `test_PoC_totalCoveredExceedsTotalFunded`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
