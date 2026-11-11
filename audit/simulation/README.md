# Economic stress simulation

## What it proves

Seeded, reproducible stress simulations of the economics: stablecoin depegs, oracle outages, correlated drops, keeper outages, gas and dust, route stress, interest accrual, and the recommended launch values. They show where bad debt can appear and what the parameters must be for it not to; they are inputs to parameter calibration, not proofs. The 1,000-agent user-journey simulation is in [`user-simulation/`](../user-simulation/).

## How to run

```bash
cd spec/05-verification && for f in $(find simulation -name '*.py' | sort); do .venv/bin/python "$f"; done
```

## Scope

8 scripts plus the shared core (`_simcore.py`); 200 accounts per book (600 in the dust-heavy book), pool risk factors 0.20–0.40, outages 1–72 h.

## How often it runs

`run_all.sh`, the `spec` CI workflow, and each layer gate.

## Latest result

2026-11-10, Python 3.9.6, seeds 11/22/33: 35 hold, 6 counterexamples (each a recorded finding or accepted risk), every script exits 0. Bad debt is zero in every brief scenario at every pool risk factor 0.20–0.40; it appears only when a pool token goes to zero while liquidation of its markets stops (48 h provider-wide outage on the tail path, no keeper for 48 h, or routes reverting).

## Results folder

- [`recorded-results-2026-11-10.md`](results/recorded-results-2026-11-10.md): Results and Run log of `spec/05-verification/simulation/README.md`.
