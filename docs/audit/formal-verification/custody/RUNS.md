# Custody area: run log

One entry per run of the custody checks (`FV-CUS-*`). Each new run appends an entry; earlier entries are never edited. Findings are tracked in the [findings register](../../findings-register.md); the full results of the reported run are in [report.md](report.md).

## FV-CUS-R1 — 2026-11-09 — reported run

| Item | Value |
|---|---|
| Date | 2026-11-09 |
| What ran | Every Z3 model (`fv_backing`, `fv_list`, `fv_exposure`, `fv_pending`, `fv_hub`, `fv_token`, `fv_lpvault`, `fv_arith`, `fv_lpvalue`, `fv_solvency`) and two Quint simulations of `custody.qnt` |
| Command | `docs/audit/formal-verification/custody/run.sh` (from the repository root; the script changes into its own folder) |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4 (`quint run`, randomized simulator; Apalache not used) |
| Seeds and bounds | Quint `--seed=0x1`, 10,000 samples × 20 steps for `FV-CUS-QNT-01` (`--invariant=inv`) and `FV-CUS-QNT-02` (`--step=stepOrphan --invariant=backing`). `FV-CUS-25-fuzz`: 17,053 seeded samples with exact Uniswap v3 amounts. Structure: `fv_backing.py` 1 market, 2 proxies, 3 record slots; `fv_list.py` 5 list slots; `fv_exposure.py` 3 records over 2 markets, 2 depositors; Quint 3 NFTs, 2 proxies. Value bounds: `L < 2^120`, `usdCharge < 2^128`, `price8 < 2^64`, decimals 6–18. |
| Results | Z3: 305 Verified, 6 Violated (`FV-CUS-01-orphanBurn`, `FV-CUS-19-orphan`, `FV-CUS-11-depositor-hostile`, `FV-CUS-14-perbucket`, `FV-CUS-14-perbucket-trace`, `FV-CUS-25-exact`). Quint: `FV-CUS-QNT-01` no violation in 10,000 runs; `FV-CUS-QNT-02` Violated. Randomized: `FV-CUS-25-fuzz` holds over 17,053 samples. Every `-FIX` check passes. |
| Exit code | 1. `run.sh` exits 1 while any check is Violated; each Violated check belongs to an open finding, so exit 1 is expected until the findings are resolved and the models updated. |
| Findings produced | `FV-CUS-F-01` (from `01-orphanBurn`, `19-orphan`, `QNT-02`), `FV-CUS-F-02` (`11-depositor-hostile`), `FV-CUS-F-03` (`14-perbucket`, `14-perbucket-trace`), `FV-CUS-F-04` (`25-exact`), `FV-CUS-F-05` and `FV-CUS-F-06` (text findings from reading the spec, no failing check) |
| Spec state | Decisions `Q-001`…`Q-240`; pages 2.2–2.4, 2.6, 2.16, 3.1 and 3.7 read as final; Aave V4 at `a3ef63ea6415d25237a9775bf66e76e9993561c2` |
| Output | Console only; the counts above are those stated in [report.md](report.md) section 7 |

## FV-CUS-R2 — 2026-11-09 — confirmation re-run

| Item | Value |
|---|---|
| Date | 2026-11-09, 22:00 EST |
| What ran | The same checks as `FV-CUS-R1`, to confirm the reported counts |
| Command | `docs/audit/formal-verification/custody/run.sh` |
| Tools | Python 3.9.6; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | Unchanged from `FV-CUS-R1` (Quint `--seed=0x1`, 10,000 × 20; fuzz 17,053 samples) |
| Results | Z3: 305 Verified, 6 Violated (the same six rules). Quint: `FV-CUS-QNT-01` no violation in 10,000 runs; `FV-CUS-QNT-02` Violated. `FV-CUS-25-fuzz` holds over 17,053 samples. Identical to `FV-CUS-R1`. |
| Exit code | 1 (expected while the findings are open) |
| Wall time | 28 s, run alongside the control, liquidation and simulation re-runs |
| Findings produced | None new; the same Violated checks as `FV-CUS-R1` |
| Spec state | Decisions `Q-001`…`Q-240`. Decisions `Q-241`…`Q-278` were recorded in 4.4 by then but are not modelled. |

## FV-CUS-R3 — 2026-11-10 — re-verification against the final spec

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | Every Z3 model (`fv_backing`, `fv_list`, `fv_exposure`, `fv_pending`, `fv_hub`, `fv_token`, `fv_lpvault`, `fv_arith`, `fv_lpvalue`, `fv_solvency`) and two Quint simulations of `custody.qnt`, after the models were updated to the final pages 2.2, 2.3, 2.4, 2.6, 2.16, 3.1, 3.4 and 3.7 |
| Command | `docs/audit/formal-verification/custody/run.sh` (from the repository root; the script changes into its own folder) |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4 (`quint run`, randomized simulator; Apalache not used); Node.js 22.18.0 |
| Seeds and bounds | Quint `--seed=0x1`, 10,000 samples × 20 steps for `FV-CUS-QNT-01` (`--invariant=inv`) and `FV-CUS-QNT-02` (`--step=stepOrphan --invariant=invOneSided`). `FV-CUS-25-fuzz`: seed 20261109, 20,000 draws, 17,053 valid samples with exact Uniswap v3 amounts compared as exact rationals. Structure: `fv_backing.py` 1 market, 2 proxies, 3 record slots; `fv_list.py` 5 list slots; `fv_exposure.py` 3 records over 2 markets, 2 depositors; Quint 3 NFTs, 2 proxies. Value bounds: `L < 2^120`, `usdCharge < 2^128`, `price8 < 2^64`, decimals 6–18. |
| Results | Z3: 506 Verified (including 8 satisfiable witnesses), 1 Violated (`FV-CUS-01-gapmono`). Per file: `fv_backing` 330 Verified and 1 Violated, `fv_list` 14, `fv_exposure` 54, `fv_pending` 7, `fv_hub` 10, `fv_token` 24, `fv_lpvault` 47, `fv_arith` 9, `fv_lpvalue` 7, `fv_solvency` 4. Quint: `FV-CUS-QNT-01` and `FV-CUS-QNT-02` no violation in 10,000 runs each. `FV-CUS-25-fuzz` holds over 17,053 samples (largest shortfall 376.70 in 8-decimal USD, within one raw unit per leg). No check is Vacuous or Unknown. |
| Exit code | 1, from `FV-CUS-01-gapmono` (finding `FV-CUS-F-07`). Every other check passes. |
| Wall time | 49 s |
| Findings resolved | `FV-CUS-F-01`…`F-06`: every check that failed in `FV-CUS-R1` now passes against the final text (`FV-CUS-01-orphanBurn`, `FV-CUS-19-orphan`, `FV-CUS-QNT-02`, `FV-CUS-11-depositor`, the `FV-CUS-14-*` sum form, `FV-CUS-25-residual` and `FV-CUS-25-fuzz`). The `-FIX` and `-FIXEQ` checks of `FV-CUS-R1` are now the main checks and were removed. |
| Findings produced | `FV-CUS-F-07` (from `FV-CUS-01-gapmono`), `FV-CUS-F-08` and `FV-CUS-F-09` (text findings from reading the final pages, no failing check) |
| Spec state | Decisions `Q-001`…`Q-278`; traceability 0 errors over 2,927 requirements; Aave V4 at `a3ef63ea6415d25237a9775bf66e76e9993561c2` |
| Output | Console only; the counts above are those stated in [report.md](report.md) section 9 |

## FV-CUS-R4 — 2026-11-10 — re-run after the custody text fixes

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | Every Z3 model and both Quint simulations of `FV-CUS-R3`, after `PROP-065`, `PROP-045`, `INV-008`, `INV-058`, `REQ-VAULT-089`, `REQ-VAULT-129`, `REQ-VAULT-130`, `REQ-COLL-006`, `REQ-COLL-018` and methodology T-01, T-08, T-09, T-14 and T-20 were changed for `FV-CUS-F-07`…`F-09`. `FV-CUS-01-gapmono` now encodes the restated `PROP-065` over every call: each call keeps or raises the backing gap, except a `settlePending(x)` called without a matching burn, which lowers it by exactly `x` and leaves it ≥ 0. |
| Command | `docs/audit/formal-verification/custody/run.sh` (from the repository root) |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | Unchanged from `FV-CUS-R3` |
| Results | Z3: 507 Verified, 0 Violated, 0 Vacuous, 0 Unknown (`FV-CUS-01-gapmono` now passes). Quint: `FV-CUS-QNT-01` and `FV-CUS-QNT-02` no violation in 10,000 runs each. |
| Exit code | 0 |
| Wall time | 3 min 39 s, run alongside other suites |
| Findings resolved | `FV-CUS-F-07` (`FV-CUS-01-gapmono`, `FV-CUS-01-gap-settlePending-without-burn`), `FV-CUS-F-08` and `FV-CUS-F-09` (text; `FV-CUS-01-*`, `FV-CUS-20-*`, `FV-CUS-24-views`, `FV-CUS-24-rescue`, `FV-CUS-28-reentry`, `FV-CUS-30-*`, `FV-CUS-31-*`, `FV-CUS-32-*` pass) |
| Findings produced | None |
| Spec state | Decisions `Q-001`…`Q-278`, with the rules above as changed |


## FV-CUS-R5 — 2026-11-10 — AMM-neutral design

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | Every model of `FV-CUS-R4`, with `fv_token.py` T-22 brought to the new `SPEC-UNIT-001` (decimals from the value of one credited unit) and `SPEC-BACK-001` (exact range, signed tick alignment); the new model `fv_amm.py` (`FV-CUS-35`…`FV-CUS-42`: records keyed by (`integrationId`, `positionKey`), exact range match, clamped composition, n-token pending settlement, one market per proxy and CREATE2 binding, Hub-keyed caps, the 16-record bound, the two-member Lock); and the new spec-ID check `check_ids.py`, now part of `run.sh`. `common.py` gained `open_finding`: a registered check that is VIOLATED prints as `OPEN` with its counterexample and does not fail the run |
| Command | `docs/audit/formal-verification/custody/run.sh` (from the repository root) |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | As in `FV-CUS-R3`; `fv_amm.py` enumerates spacings 1, 10, 60, 200 over ±8 spacings and n = 2…8 tokens |
| Results | Z3 and enumeration: 532 Verified, 0 Violated, 0 Vacuous, 0 Unknown, 1 open finding (`FV-CUS-42-surface`, F-10). Per model: backing 331, list 14, exposure 54, pending 7, hub 10, token 25, lpvault 47, arith 9, lpvalue 7, solvency 4, amm 24 + 1 open. Quint: `FV-CUS-QNT-01` and `FV-CUS-QNT-02` no violation in 10,000 runs each. `check_ids.py`: 193 cited spec IDs, 0 undefined |
| Exit code | 0 |
| Wall time | 35 s |
| Findings produced | `FV-CUS-F-10` (Informational, open): `REQ-LOCK-028` routes the stray-position return through the Adapter while `REQ-VAULT-165` makes `returnStray` timelock-only with the Lock free |
| Findings resolved | None; F-01…F-09 stay resolved (report §10.4) |
| Spec state | AMM-neutral design, decisions `Q-001`…`Q-380`, pages as on 2026-11-10 during the consolidation round |
| Before this run | The `FV-CUS-R4` models against the rewritten spec: 507 Verified, both Quint runs pass, exit 0, 168 cited IDs all defined. The pass was not evidence for the new design: T-22 still checked the superseded `2d = d0 + d1` decimals and full-range ticks, and no check covered the new key, shapes, proxy scope, Hub caps or Lock membership |

## FV-CUS-R6 (2026-11-10)

| Field | Value |
|---|---|
| Spec state | Final AMM-neutral pages after the alignment pass; decisions `Q-001`…`Q-380`; traceability 0 errors |
| Command | `bash docs/audit/formal-verification/custody/run.sh` |
| Result | Exit 0; every check Verified; 0 open findings |
| Change | `FV-CUS-42-surface` now checks the final `REQ-LOCK-028`: position-moving LPVault functions run only inside a Lock member's call tree, and the timelock-only `returnStray` runs only from the AvanaTimelock while the Lock is free |
| Findings resolved | `FV-CUS-F-10` (`FINDING-286`) |

## FV-CUS-R7 (2026-11-10)

| Field | Value |
|---|---|
| Spec state | Decisions `Q-001`…`Q-402` |
| Command | `bash docs/audit/formal-verification/custody/run.sh` |
| Result | Exit 0; every check Verified; 0 open findings |
| Change | `fv_solvency.py` (`FV-CUS-29`): the withdrawal guard is `max(1.00, the market's optional hard floor, minHealthFactor) >= 1.00`; `minOpeningHealthFactor` and `PROXY_HEALTH_FACTOR_FLOOR` are removed (`Q-398`). `report.md` no longer lists a settlement budget among the controls outside this area (`Q-397`) |

## FV-CUS-R8 (2026-11-11)

| Field | Value |
|---|---|
| Spec state | Decisions `Q-001`…`Q-406` |
| Command | `bash docs/audit/formal-verification/custody/run.sh` |
| Result | Exit 0; 538 Z3 and enumeration checks Verified; `FV-CUS-QNT-01` and `FV-CUS-QNT-02` with no violation in 10,000 randomized runs of 20 steps; `check_ids.py` 201 cited spec IDs, 0 undefined; 0 open findings |
| Change | None in this area's models; full re-run alongside the control-area model updates of `FV-CTL-R11` |
