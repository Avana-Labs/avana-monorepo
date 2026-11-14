# AaveV3FlashSource review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/flash/AaveV3FlashSource.sol` |
| Spec | [2.11 LPVaultSwap](../../../spec/02-contracts/11-lpvaultswap.md) (flash source rules `REQ-FLASH-*`) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 1 High, 1 Medium; both fixed in code |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | High | A 1-wei donation to the source made every loan forward `amount + 1`, which LPVaultSwap must refuse (`REQ-SWAP-013`), blocking flash-funded liquidation and deleverage of that asset for good | The source forwards only what the Pool delivered, measured against a balance snapshot taken before the Pool call; a donation is never forwarded. `REQ-FLASH-001`/`003` drop "transfers its whole balance" and "ends every call with no balance" | fixed |
| 2 | Medium | `maxFlashLoan` overstated capacity under Aave V3.1+ virtual accounting | Returns `min(balanceOf(aToken), getVirtualUnderlyingBalance)` | fixed |
| 3 | Spec | Aave V3.4 rounds the premium half-up; the source's ceiling quote stays the binding gate | Stated in `SPEC-LIQ-007`/`015` and the Z3 `st11` text; `REQ-SWAP-106` step 7 repays by balance delta; the Pool mock gets virtual accounting, half-up rounding and real zero-amount behaviour | decided (spec text) |

## Related decision

Caller-funded liquidation (`Q-404`, 2026-11-10): `LPVaultSwap.liquidate` takes no flash loan; a public periphery helper flash-borrows for callers that need it. The core flash source serves `deleverage` only, with the balance-snapshot fix.

## Evidence after the fixes

Halmos 8 / 8 (`PROP-036`, `PROP-080`, including `donationNeverForwarded`); unit and fuzz suites pass. `TEST-118` on a mainnet fork waits for an archive RPC.

## PoC tests

- `FlashReview.t.sol`: `test_REVIEW_donationBricksFlashPathUnderReqSwap013`, `test_REVIEW_maxFlashLoanOverstatesUnderVirtualAccounting`, `test_REVIEW_ceilQuoteRefusesLoanThatHalfUpChargeAdmits`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; for each fixed finding, a regression test in `contracts/test/` asserts the fixed behavior.
