# PayoutEscrow review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/liquidation/payout-escrow/PayoutEscrow.sol` |
| Spec | [2.18 Payout Escrow](../../../spec/02-contracts/18-payout-escrow.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 3 Low, 1 Informational; fixes queued |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Low | A mis-wired escrow (Lock deployed with another LPVaultSwap) would brick every failed-payout liquidation or let the Adapter deposit | Constructor requires `ILock(lock).LP_VAULT_SWAP() == lpVaultSwap`; new error, `REQ-ESCROW-001`, NatSpec, unit test and a `07_VerifyDeployment` assertion | fix queued |
| 2 | Low | A token with a sender-side fee lets `claim` drain other credits | `claim` measures the escrow's balance around the transfer and reverts if it fell by more than `amount` | fix queued |
| 3 | Low | A deposit whose balance rises by more than `amount` reverted the liquidation | Credit `amount`; the surplus stays as an unattributed donation | fix queued |
| 4 | Info | Under an issuer burn or a negative rebase, claims are first come, first served; overflow comment | Documented; comment fixed | fix queued |

## Also queued

`INV-061`/`INV-079` against the measured `received`; `TEST-173` against residue and dust-leg deposits; `REQ-SWAP-076` names the reported amount; for contract 23 a transfer that returns `true` but under-delivers is measured and the shortfall escrowed; `INV-039`, `INV-061`, `ATTACK-118` list residues; 2.18 Inputs adds `isLocked()`. Tests: sender-fee, burn and rebasing handlers and the constructor mismatch.

## PoC tests

- `PayoutEscrowReview.t.sol`: `test_PoC_constructorMismatchBricksDeposits`, `test_PoC_constructorAdapterAsDepositor`, `test_PoC_senderFeeClaimDrainsOtherCredits`, `test_PoC_balanceFallFirstComeFirstServed`, `test_PoC_roundUpTokenRevertsLiquidation`, `test_PoC_blockedClaimantClaimsElsewhere`, `test_PoC_claimHookCannotDepositThroughLock`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
