# Liquidation area: internal formal verification (FV-LIQ)

Avana's internal formal verification of the liquidation area: LPVaultSwap and its SettlementMath, the swap routes into the debt asset, the IFlashSource funding, the caller's top-up that closes the floor and the rounding gap (there is no settlement budget, `Q-397`), the per-asset Coverage Spokes with Aave's deficit path, and the PayoutEscrow, whose only job is to hold payouts LPVaultSwap could not deliver (`Q-401`). The models are written from the final spec pages 2.11–2.14, 2.17, 2.18, 3.5 and 3.9 (decisions `Q-001`…`Q-401`), the decision log and the Aave V4 source at `a3ef63ea6415d25237a9775bf66e76e9993561c2`. Results, findings and assumptions are in [report.md](report.md); the prover rules (CVL) that carry each property to the implementation are in [audit-mapping.md](audit-mapping.md).

## Run

```bash
audit/formal-verification/liquidation/run.sh
```

It runs every check and exits non-zero on any violation that is not an expected finding counterexample, on any solver timeout, on any vacuous premise and on any Quint result that differs from its expectation. A full run takes several minutes. `QNT_SAMPLES` and `QNT_STEPS` set the Quint simulation size (defaults 10,000 traces of 25 steps).

Requirements: the Python environment in `spec/05-verification/.venv` (z3-solver 4.13, Hypothesis) and Quint in `spec/05-verification/node_modules`.

## Files

| File | Checks | What it proves |
|---|---|---|
| `_lib.py` | — | Exact integer semantics of `mulDiv`, ray and percentage math; the Z3 harness. `prove` first finds a witness for the premise (a vacuous premise fails the check), then asks Z3 for a counterexample. `expect_violation` passes only when the counterexample exists (findings and mutants). `replay` re-runs a finding's counterexample with exact integers. |
| `aave_ref.py` | — | Line-by-line port of Aave V4 `LiquidationLogic` sizing (target health factor, bonus curve, dust rule, all-collateral branch, `MustNotLeaveDust`) and `SharesMath` at the pin. |
| `fv_liq_01_settlement_math.py` | FV-LIQ-01* | SettlementMath formulas `SPEC-LIQ-001`…`022` in the debt asset and the rounding gap `SPEC-SET-001`, `002`: one-leg liveness and the `s = 0` case, the flash pre-loan bound and lender gate, `φD` on `min(F, D)`, the payout split `A + kr + B = S`, the gap bound against twice the allowance, Avana's fee from the oracle value, no sell-back of the leftover, per-leg minimums, the top-up `shortfall = max(0, minRec − R, D + φD − K − R)`, the repay-with-collateral sizing, waterfall and conservation with `R' = R + shortfall`, routed payouts only, pending floor, arithmetic bounds. |
| `fv_liq_02_aave_sizing.py` | FV-LIQ-02* | No over-seizure in every Aave branch, seizure lower bound, `D ≤ min(X, Xr)`, deficit only with no collateral left, bonus range; Hypothesis cross-check on the exact port; the Lens seizure computed with Aave's formula and the whole-debt preview (`REQ-LENS-017`, `028`, `029`). |
| `fv_liq_03_flow.py` | FV-LIQ-03* | Symbolic execution of all 56 control paths of `liquidate` (two route modes) and `liquidatePermissionless` over LPVaultSwap's ledger, with per-leg minimums and the caller's top-up on every path: balance neutrality, allowances, recipients, escrow of every failed payout, no in-kind branch, no breaker report, top-up liveness, deadline and payout, gates, frame (pause, breakers, other markets, freeze), donations; `settlePending`; callbacks; the keeper list with `keeperFloor = 1` and `MAX_KEEPERS = 32`; all 6 paths of `deleverage`. |
| `fv_liq_04_budget.py` | FV-LIQ-04* | The caller's top-up that replaced the SettlementBudget (`Q-397`): it is pulled from the caller only, within `maxShortfall`, closes the floor and the rounding gap, is the least such pull, falls as caller funds rise, never reaches Avana or the borrower when the gap binds; LPVaultSwap's balance is unchanged over any sequence of calls; the dust-rule sizing of `debtToCover`; the earlier budget designs kept as mutants. |
| `fv_liq_05_escrow_coverage.py` | FV-LIQ-05* | PayoutEscrow (payout escrow) inductive invariant with measured deposits of failed payouts only; Coverage Spoke amount bounds, share-price safety, isolation per asset, withdrawal lifecycle, coverage and deficit breakers, tail-coverage ratio. |
| `fv_liq_06_examples.py` | FV-LIQ-06* | Every liquidation worked example in 2.11, 2.12, 2.13, 2.14, 2.17, 2.18, 3.5 and 3.9 recomputed exactly (including `LIQ-069` conservation); the earlier findings' cases under the final rules, with the earlier text as mutants. |
| `fv_liq_07_system.py` | FV-LIQ-07* | System properties in value terms: equity and HF effect of a liquidation, single-block insolvency, self-liquidation loops with a shortfall top-up, swap limits, oracle extremes, stress valuation and no shield, one-token shocks, splitting. |
| `liquidation.qnt` | FV-LIQ-08* | Multi-actor state machine (borrowers, committed operators and any other caller of the one entry point `liquidate`, governance, guardians with the address freeze and the application pause, coverage, escrow, price shocks) checked by randomized simulation. |

Each check carries a tag `# FV-LIQ-NN verifies: …` naming the spec IDs it covers, which `spec/05-verification/trace.py` collects.
