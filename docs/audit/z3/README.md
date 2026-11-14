# Z3

## What it proves

Every formula of the specification is modelled in exact integers, or at Solidity bit widths where overflow or truncation is the question, and checked with Z3 4.13. A property is proved by showing its negation is `unsat` for every input inside the stated bounds. Counterexamples are searched for on purpose: a wrong reading the spec rules out, a stated boundary, or a state outside the bounds. Every worked example on the spec pages is recomputed exactly. A script exits 1 only when a result differs from the one its README records.

| Folder | Covers | Spec IDs |
|---|---|---|
| `units-oracle/` | Vault-token units and decimals, LPOracle and DebtOracle math, price states, backing ledger, cap counters, LPPriceMath input bounds | `SPEC-UNIT-*`, `SPEC-ORC-*`, `SPEC-BACK-*` |
| `aave-risk/` | Collateral and health factor on Aave V4 `a3ef63e`, opening gate, liquidation sizing and bonus, repay, risk premium, caps, breakers, wind-down, gas model | `SPEC-HUB-*`, `SPEC-CF-*`, `SPEC-CAP-*`, `SPEC-BRK-*`, `SPEC-PROXY-*` |
| `settlement/` | Net bonus, effective slippage, recovery floor, per-leg minimums, caller shortfall, waterfall and fee, debit equalities, deleverage, coverage and reserve sizing, debt-asset settlement, payout split | `SPEC-LIQ-*`, `SPEC-SET-*`, `SPEC-FLR-*` |
| `docs/governance/` | Timelock delays, execution window, expiry, delay floor, short-delay allowlist, cancel rights, pause state | `SPEC-GOV-*` |
| `amm-pricing/` | Fair-composition pricing per AMM protocol (concentrated liquidity with the range clamp, constant product, StableSwap, weighted) | `MATH-AMM-<P>-PRICE-*` |

## How to run

From `docs/spec/05-verification/` (z3-solver 4.13.0 in `.venv`):

```bash
./run_all.sh                                            # every spec-stage check
.venv/bin/python z3/settlement/st03_waterfall.py        # one model
```

## Scope

The design, independent of the Solidity: every `SPEC-*` formula on the spec pages. The math libraries carry the same formulas into code through the differential tests and the golden vectors in `contracts/test/`.

## How often it runs

`run_all.sh` before each spec change is accepted in `trace.py`, the `spec` CI workflow, and at each layer gate (`run_all.sh` must still pass).

## Latest result

2026-11-10, Python 3.9.6, z3-solver 4.13.0, 120 s per query: 37 scripts in the summary table, 509 proved, 83 deliberate counterexamples, 66 computed, 0 mismatches, 0 timeouts, every script exits 0. Later runs the same day: `settlement/` 315 checks after the settlement-budget and in-kind removal (every script exits 0); `units-oracle/` adds `uo12` and `uo13` (33 proved, 9 deliberate counterexamples, 13 computed). Findings `MATH-AR-37`, `-24d`, `-47c`, `-44b`, `-50c`, `MATH-ST-58`, `-75`, `-77`, `-84` are resolved in spec.

Re-run on 2026-11-10 at 22:4x: `gv01_timelock_timing.py` 17 checks and `gv02_delay_floor_allowlist.py` 13 checks, 0 differ from the documented results, exit 0.

Re-run of every script on 2026-11-11, one at a time: 52 scripts in five folders (`units-oracle/` 16, `aave-risk/` 13 with `ar12`, `settlement/` 17, `docs/governance/` 3, `amm-pricing/` 3), 641 proved, 123 deliberate counterexamples, 131 computed, 0 mismatches, 0 timeouts, every script exits 0; per-folder counts in [`docs/spec/05-verification/z3/README.md`](../../spec/05-verification/z3/README.md#results).

## Results folder

- [`recorded-results-2026-11-10.md`](results/recorded-results-2026-11-10.md): the Results sections of every Z3 folder README.
- [`gv01_timelock_timing-2026-11-10.txt`](results/gv01_timelock_timing-2026-11-10.txt), [`gv02_delay_floor_allowlist-2026-11-10.txt`](results/gv02_delay_floor_allowlist-2026-11-10.txt): full output of the two governance models.
