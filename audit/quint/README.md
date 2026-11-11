# Quint

## What it proves

A cross-contract state machine of Avana with honest and hostile components (`avana.qnt`) and a multi-Hub, multi-Spoke topology model (`topology.qnt`). Typecheck, deterministic scenario tests, and simulator runs that check each invariant over bounded random traces and require each witness state to be reached. Result: holds within bounds.

## How to run

From `spec/05-verification/` (Quint 0.22.4 from `package.json`):

```bash
npx quint typecheck quint/avana.qnt && npx quint test quint/avana_tests.qnt
quint/run.sh --quick          # 500 traces × 20 steps per check
QUINT_FULL=1 quint/run.sh     # 10,000 × 20
quint/topology_run.sh         # topology simulator, nightly
```

## Scope

58 properties `QNT-01`…`QNT-58`, 8 combined runs, 30 witnesses and 50 scenarios in `avana.qnt`; 15 invariants and 20 scenarios in `topology.qnt`.

## How often it runs

`run_all.sh` (quick mode), `--nightly` for topology, the `spec` CI workflow, and each layer gate.

## Latest result

2026-11-10, quick mode, 500 × 20 per check, 96 checks: 50 / 50 scenarios pass; 58 / 58 properties hold; 8 / 8 combined runs hold (honest, stressed, route outage, crash, hostile swap, hostile adapter); 26 of 30 witnesses reached in their own samples, 4 reached only by other traces and by passing scenarios (`W-SEIZE`, `W-PERM`, `W-RECREDIT`, `W-DAOCANCEL`). A later quick run the same day (single worker) ends with "all checks as expected", exit 0. Recorded finding `QNT-F1` (hostile LPVaultSwap seizing an Expired market for one unit of debt) is an accepted risk (`Q-368`, `FINDING-285`).

## Results folder

- [`recorded-results-2026-11-10.md`](results/recorded-results-2026-11-10.md): Results and Findings of `spec/05-verification/quint/README.md`.
- [`quint-run-quick-2026-11-10.txt`](results/quint-run-quick-2026-11-10.txt): console output of `quint/run.sh` in quick mode (log paths shortened).
