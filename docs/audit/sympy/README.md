# SymPy

## What it proves

Algebraic consistency: each formula equals the rule it implements, exactly and before rounding; closed forms the spec states are derived; worked examples are recomputed in exact rationals. Result `CONSISTENT` means the residual reduced to 0.

## How to run

From `docs/spec/05-verification/` (SymPy 1.13.3 in `.venv`):

```bash
./run_all.sh
.venv/bin/python sympy/sym05_settlement.py
```

## Scope

10 scripts: collateral factor, liquidation sizing, Uniswap full-range amounts, units, decimals and oracle, settlement, risk premium, the borrow-to-liquidation walkthrough, units/oracle/backing examples, governance timing examples, risk examples.

## How often it runs

`run_all.sh` before each spec change is accepted, the `spec` CI workflow, and each layer gate.

## Latest result

2026-11-10: 230 checks, 229 hold, 1 counterexample (`SYM-42a`, a deliberate wrong reading: a subtractive slippage bound instead of the multiplicative one of `SPEC-LIQ-003`); 16 derived closed forms; every script exits 0. Finding `SYM-138d` (a figure in the 3.4 withdraw example) is resolved in spec. Later the same day: `sym08` 82 / 82 after the LPPriceMath input bounds.

Re-run on 2026-11-10 at 22:4x: `sym09_governance_timing_examples.py` 9 / 9 and `sym01_collateral_factor.py` 14 / 14 consistent, 0 differ from the README.

## Results folder

- [`recorded-results-2026-11-10.md`](results/recorded-results-2026-11-10.md): Results, Findings and Run log of `docs/spec/05-verification/sympy/README.md`.
- [`sym09_governance_timing_examples-2026-11-10.txt`](results/sym09_governance_timing_examples-2026-11-10.txt), [`sym01_collateral_factor-2026-11-10.txt`](results/sym01_collateral_factor-2026-11-10.txt).
