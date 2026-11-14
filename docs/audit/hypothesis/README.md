# Hypothesis

## What it proves

Generated action sequences and numeric edge cases run against an executable integer model of Avana, Aave V4 and Uniswap v3 (`spec/05-verification/hypothesis/model/`). The state machine drives borrowers, an outside LP, keepers, a third-party payer, a hostile RiskModule and the guardians, and checks every global invariant after every step, solvency per debt asset included; numeric tests cover rounding, dust and bounds; `test_hyp_amm_pricing.py` checks LP pricing under swaps, donations, mints and burns for each pool type; `test_hyp_timelock.py` checks the timelock. Result: holds within bounds (evidence, not proof).

## How to run

From `spec/05-verification/` (hypothesis 6.112.5, pytest 8.3.3):

```bash
.venv/bin/python -m pytest -q hypothesis
AVANA_HYP_SCALE=5 .venv/bin/python -m pytest -q hypothesis/test_hyp_state_machine.py    # deeper search
```

## Scope

80 test functions and the state machine `TestAvanaStateMachine` in 5 files (`test_hyp_numeric.py` 23, `test_hyp_scenarios.py` 38, `test_hyp_amm_pricing.py` 11, `test_hyp_timelock.py` 8, `test_hyp_state_machine.py`); budgets per file in the results. The recorded run of 2026-11-10 below predates the AMM-pricing and later scenario tests.

## How often it runs

`run_all.sh`, the `spec` CI workflow, and each layer gate.

## Latest result

2026-11-10: recorded run 71 tests, 70 passed and 1 failed (`HYP-85`, the per-leg minimum sum bound); the spec fix (`INV-083`, `SPEC-LIQ-018` with the LP-price term) followed and both `HYP-85` tests pass against it. Deep runs: state machine 2,000 × 60 pass; timelock 1,500 × 40 pass. After the restore-amount change (`SPEC-CAP-003`) the affected tests and the state machine pass.

## Results folder

- [`recorded-results-2026-11-10.md`](results/recorded-results-2026-11-10.md): Settings and run log, Results and Finding of `spec/05-verification/hypothesis/README.md`.
