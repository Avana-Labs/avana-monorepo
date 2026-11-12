# SettlementMath review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/liquidation/lp-vault-swap/SettlementMath.sol` (library) |
| Spec | [2.11 LPVaultSwap, settlement math](../../../spec/02-contracts/11-lpvaultswap.md#settlement-math) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | No code defect above Informational; five specification points (S1–S5) and four hardening points (A1–A4); fixes merged after the gate |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Spec (S1) | The fee share can be routed to about zero when the effective slippage sits at the bonus cap | Accepted and documented as best-effort in `SPEC-LIQ-009`, `INV-086` and `PROP-069` | accepted |
| 2 | Spec (S2) | The rounding gap was taken against the recovery, not the real obligation | Gap `g = max(0, D + φ + τ + A + B − Kr − R)` with the waterfall on `R_f = max(R, minRec)` (`MATH-ST-121`, `MATH-ST-122`); under caller-funded liquidation (`Q-404`) φ = τ = 0 and the gap is `max(0, D + A + B − Kf − R)` (`SPEC-SET-001`) | fixed |
| 3 | Spec (S3) | A flash-fee cap equal to the pool rate makes every loan fail | `maxFlashFeeBps` stated as strictly above the pool rate (`SPEC-LIQ-015`, `MATH-ST-115`) | fixed |
| 4 | Spec (S4) | Deleverage legs at their minimum could fall short because `Vnet` ignored the rounding allowance | `Vnet` subtracts ε (`MATH-ST-123`) | fixed |
| 5 | Spec (S5) | The borrower-surplus choice in deficit liquidations was unstated | Stated in 2.11 | fixed |
| 6 | Info (A1–A4) | A zero debt price panicked; decimals above 36 were accepted; `avanaFeeShareBps` had no guard | Named errors for zero prices and decimals above 36; guard `avanaFeeShareBps ≤ 10⁴` | fixed |

## Evidence after the fixes

Unit, fuzz (10,000 runs) and differential tests pass; Z3 `settlement/` 315 checks exit 0. Halmos ran under machine load (2 / 14 pass, the rest timed out). The remaining text points (`INV-034`…`INV-038`, 3.5 notation, `REQ-LENS-029`, `fv_liq_01`/`03`/`04`/`06`, the Hypothesis gap model) are part of the 2.11 rewrite.

## PoC tests

- `PoC.t.sol`: `test_feeEvasionAtCappedSlippage` (S1), `test_premiumAtCapFails` (S3), `test_deleverageLegsAtMinimumShort` (S4), `testFuzz_legSlippageSpec`, `test_zeroDebtPricePanics`, `test_decimalsAbove36Accepted` (A1–A4)

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; for each fixed finding, a regression test in `contracts/test/` asserts the fixed behavior.
