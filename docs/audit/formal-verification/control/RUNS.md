# Control area: run log

One entry per run of the control checks (`FV-CTL-*`). Each new run appends an entry; earlier entries are never edited. Findings are tracked in the [findings register](../../findings-register.md); the full results of the reported run are in [report.md](report.md).

## FV-CTL-R1 — 2026-11-09 — reported run

| Item | Value |
|---|---|
| Date | 2026-11-09 (log written 20:49) |
| What ran | Nine Z3 and enumeration models (`fv_ctl_access`, `fv_ctl_timelock`, `fv_ctl_pause`, `fv_ctl_gates`, `fv_ctl_params`, `fv_ctl_registry`, `fv_ctl_oracle`, `fv_ctl_upgrade_lens`, `fv_ctl_breakers`), `quint typecheck` and eight `quint run` invariant checks of `governance.qnt`, and the spec-ID check `check_ids.py` |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4 (`quint run`, randomized) |
| Seeds and bounds | Quint `--seed 0x1`, 10,000 samples × 12 steps for each of `execWaitedNormalDelay`, `pauseTransitionsLegal`, `upgradesGuardianCancellable`, `adminOnlyTimelock` in modules `gov_spec` and `gov_fixed`. Accounts unrolled to 2 collateral markets and 3 debt reserves; batches of up to 4 calls; served price of up to 4 legs. Route answers ≤ 10¹²; `L < 2^120`; `price8 < 2^64`; decimals 6–18. `FV-CTL-83` and `FV-CTL-92-FIX` are bounded models (up to four freezes for `92-FIX`). |
| Results | 122 checks: 89 Verified, 2 Verified under bounded model, 6 Quint invariants with no violation in 10,000 samples, 25 Violated (23 Z3 or enumeration checks and `upgradesGuardianCancellable` and `adminOnlyTimelock` in `gov_spec`). Every `-FIX` check is Verified. `check_ids.py`: 257 cited spec IDs, 0 undefined. |
| Exit code | 1. `run.sh` exits 1 while any property is Violated; every Violated check belongs to an open finding, so exit 1 is expected until the findings are resolved and the models updated. |
| Findings produced | `FV-CTL-F-01`…`FV-CTL-F-04`, `FV-CTL-F-06`…`FV-CTL-F-17` (16 findings; there is no `F-05`) |
| Spec state | `spec/` as of 2026-11-09 20:30; decisions `Q-001`…`Q-240`, with `Q-227` as amended. The circuit-breaker and address-freeze rules were checked from their approved description (`FV-CTL-91`…`96`) before they were written into the spec. |
| Output | `results/run.log` (full console log), `results/<model>.json` (counterexamples), `results/quint.txt` |

Violated checks in this run: `FV-CTL-01`, `03`, `11`, `24`, `26`, `40`, `41`, `45`, `57`, `57-EX`, `58`, `60`, `62`, `69`, `70`, `77`, `81`, `87`, `90`, `91`, `92`, `93`, `95`, and Quint `FV-CTL-98` `gov_spec` `upgradesGuardianCancellable` and `adminOnlyTimelock`.

## FV-CTL-R2 — 2026-11-09 — confirmation re-run

| Item | Value |
|---|---|
| Date | 2026-11-09, 22:00 EST |
| What ran | The same checks as `FV-CTL-R1`, to confirm the reported counts |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | Unchanged from `FV-CTL-R1` |
| Results | 91 Z3 or enumeration checks pass (89 Verified, 2 Verified under bounded model), 23 Violated; Quint 6 no violation, 2 Violated; `check_ids.py` 257 IDs, 0 undefined. The console output is byte-for-byte identical to `results/run.log` from `FV-CTL-R1`. `run.sh` rewrote `results/quint.txt` and `results/<model>.json` with the same content. |
| Exit code | 1 (expected while the findings are open) |
| Wall time | 85 s, run alongside the custody, liquidation and simulation re-runs |
| Findings produced | None new |
| Spec state | Decisions `Q-001`…`Q-240`. Decisions `Q-241`…`Q-278` were recorded in 4.4 by then but are not modelled. |

## FV-CTL-R3 — 2026-11-10 — re-verification against the final spec

| Item | Value |
|---|---|
| Date | 2026-11-10 (run started 00:11 EST, 100 s wall time) |
| What ran | The nine Z3 and enumeration models brought up to the final text of 1.4, 2.5–2.10 (with the DebtOracle), 2.15, 3.2–3.4, 3.6 and 3.8, with the recommended rules of `FV-CTL-R1` now the main rules and the separate `-FIX` checks removed; `quint typecheck` and six `quint run` invariant checks of `governance.qnt` (one module, `gov`, with the final rules); the spec-ID check `check_ids.py` |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4 (`quint run`, randomized); Node.js 22.18.0 |
| Seeds and bounds | Quint `--main gov --seed 0x1`, 10,000 samples × 12 steps for each of `execWaitedNormalDelay`, `pauseTransitionsLegal`, `upgradesGuardianCancellable`, `adminOnlyTimelock`, `normalDelayInBounds`, `restoringNotGuardianCancellable`. Accounts unrolled to 2 collateral markets and 3 debt reserves; batches of up to 4 calls; served price of up to 4 legs; route answers ≤ 10¹² (`MAX_ROUTE_ANSWER`). Bounded models: `FV-CTL-23` (two `setShortDelaySelector` operations over 12 probe pairs), `FV-CTL-92` (up to 4 freezes over 10 addresses with 4 or 5 keepers), `FV-CTL-81`, `82`, `83`, `147` (registry sequences as stated in each check). |
| Results | 165 checks: 159 Z3 or enumeration checks (146 Verified, 6 Verified under bounded model, 7 Violated) and 6 Quint invariants with no violation in 10,000 samples. Per model: access 13/0, timelock 17/0, pause 7/1, gates 18/0, params 24/3, registry 13/0, oracle 38/2, upgrade and Lens 10/1, breakers 19/0 (checks/violated). `check_ids.py`: 377 cited spec IDs, 0 undefined. `trace.py`: no error comes from the control files. |
| Exit code | 1. Every Violated check is a new finding against the final text; each is kept failing until the spec is changed. |
| Findings produced | `FV-CTL-F-18` (Medium, `FV-CTL-115`), `FV-CTL-F-19` (Low, `FV-CTL-112`), `FV-CTL-F-20` (Informational, `FV-CTL-36`), `FV-CTL-F-21` (Informational, `FV-CTL-137`), `FV-CTL-F-22` (Informational, `FV-CTL-139`), `FV-CTL-F-23` (Informational, `FV-CTL-142`), `FV-CTL-F-24` (Informational, `FV-CTL-148`) |
| Findings resolved | `FV-CTL-F-01`…`F-04`, `F-06`…`F-17`: each proving check passes against the edited pages (report section 12) |
| Spec state | Final spec, decisions `Q-001`…`Q-278`; traceability 2,927 requirements |
| Output | `results/run.log` (full console log), `results/<model>.json` (counterexamples), `results/quint.txt` |

Violated checks in this run: `FV-CTL-36`, `FV-CTL-112`, `FV-CTL-115`, `FV-CTL-137`, `FV-CTL-139`, `FV-CTL-142`, `FV-CTL-148`.

## FV-CTL-R4 — 2026-11-10 — re-run after the spec changes for `FV-CTL-F-18`…`F-24` and `SIM-GAP-13`

| Item | Value |
|---|---|
| Date | 2026-11-10 (run started 01:45 EST, 336 s wall time, run alongside other verification suites) |
| What ran | The nine Z3 and enumeration models brought up to the changed text: `fv_ctl_oracle.py` (latch fallback from the newest leg in use, `recoveredAt = now` on a route-version change while latched, `disagreementExpired` from the same `s` as `pauseActive`; new example check `FV-CTL-115-EX`), `fv_ctl_pause.py` (1.4 cell), `fv_ctl_params.py` (`REQ-RISK-057` error order, the `REQ-PSTORE-006` example read from the page, `SPEC-SET-002` scoped to approved reserves with the removal operation closing the caps), `fv_ctl_upgrade_lens.py` (limit checks before the offset test), `fv_ctl_breakers.py` (`SPEC-BRK-002` peg condition; new check `FV-CTL-152`); Quint `governance.qnt` and `check_ids.py` as in `FV-CTL-R3` |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | As in `FV-CTL-R3` |
| Results | 167 checks: 161 Z3 or enumeration checks (155 Verified, 6 Verified under bounded model, 0 Violated) and 6 Quint invariants with no violation in 10,000 samples. Per model: access 13/0, timelock 17/0, pause 7/0, gates 18/0, params 24/0, registry 13/0, oracle 39/0, upgrade and Lens 10/0, breakers 20/0 (checks/violated). `check_ids.py`: 378 cited spec IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | None new |
| Findings resolved | `FV-CTL-F-18` (`FV-CTL-115`, `FV-CTL-115-EX`), `FV-CTL-F-19` (`FV-CTL-112`), `FV-CTL-F-20` (`FV-CTL-36`), `FV-CTL-F-21` (`FV-CTL-137`), `FV-CTL-F-22` (`FV-CTL-139`), `FV-CTL-F-23` (`FV-CTL-142`), `FV-CTL-F-24` (`FV-CTL-148`); the `SIM-GAP-13` rule is proved by `FV-CTL-152` and `FV-CTL-106-EX` |
| Spec state | Final spec, decisions `Q-001`…`Q-278`, with `REQ-ORACLE-032`, `REQ-ORACLE-065`, `REQ-ORACLE-095`, `SPEC-ORC-016`, the 1.4 pause table, `REQ-RISK-057`, `REQ-PSTORE-006`, `SPEC-SET-002`, `REQ-MREG-010`, `MKT-045`, `REQ-LENS-014`, `REQ-LENS-024`, `SPEC-BRK-002`, `EMG-068`, `EMG-089` and `Q-241` changed |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R5 — 2026-11-10 — AMM-neutral design

| Item | Value |
|---|---|
| Date | 2026-11-10 (75 s wall time, run alongside other verification suites) |
| What ran | Every model brought up to the AMM-neutral spec (report section 13): `fv_ctl_params.py` (2.10 "State or condition" table; single-leg liveness `FV-CTL-57`, `130`, `131`; flash-fee ceiling example `FV-CTL-139`; renamed parameters in `FV-CTL-58`; new MarketRegistry short selectors in `FV-CTL-62`; new `FV-CTL-153`), `fv_ctl_upgrade_lens.py` (immutable PositionProxy per (wallet, spoke, marketId), immutable ProxyManager, `FV-CTL-86`…`90`, `149`; Lens flash-premium flag `FV-CTL-78`), `fv_ctl_access.py` (`execute`-only proxy, positionKey custody names, two-member Lock, new `FV-CTL-154`), `fv_ctl_breakers.py` (protected set with the `IFlashSource` and listed debt assets), `fv_ctl_timelock.py` (wording), and the new `fv_ctl_amm.py` (`FV-CTL-155`…`162`: liquidation exclusivity on the standard Spoke, `CONFIG_DRIFT`, flash source, Hub-keyed caps, credit lines, SettlementBudget windows, transfer-rule wording). `common.py` gained `open_finding`. Quint `governance.qnt` and `check_ids.py` as in `FV-CTL-R4` |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | As in `FV-CTL-R3`; `fv_ctl_amm.py` uses 3 Spokes for the Hub-keyed counter, 4 draw caps for the credit line and 3 markets for the SettlementBudget windows, each an unbounded-value Z3 proof over that shape |
| Results | 180 checks: 174 Z3 or enumeration checks (163 Verified, 6 Verified under bounded model, 0 Violated, 5 Violated as open findings) and 6 Quint invariants with no violation in 10,000 samples. Per model (checks / open findings): access 14/1, timelock 17/0, pause 7/0, gates 18/0, params 25/2, registry 13/0, oracle 39/0, upgrade and Lens 10/1, breakers 20/0, AMM-neutral controls 11/1. `check_ids.py`: 421 cited spec IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | `FV-CTL-F-25` (Informational, `FV-CTL-58`), `FV-CTL-F-26` (Low, `FV-CTL-153`), `FV-CTL-F-27` (Low, `FV-CTL-78`), `FV-CTL-F-28` (Informational, `FV-CTL-04`), `FV-CTL-F-29` (Informational, `FV-CTL-162`), all open |
| Findings resolved | None; `FV-CTL-F-10` and `FV-CTL-F-15` are superseded by the design (no upgradeable proxy code, immutable ProxyManager) and their checks `FV-CTL-87` and `FV-CTL-90` pass in restated form |
| Spec state | AMM-neutral spec, decisions `Q-001`…`Q-380`, read during the consolidation round (pages were being edited while the run took place; the open findings list the text as read) |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R6 — 2026-11-10 — re-run after the spec changes for `FV-CTL-F-25` and `FV-CTL-F-27`

| Item | Value |
|---|---|
| Date | 2026-11-10 (09:50) |
| What ran | Every model, with three readings updated to the final text: `FV-CTL-78` reads the flash-premium form of `REQ-LENS-029`, `REQ-PSTORE-024`, `SPEC-LIQ-015`, `REQ-FLASH-002` and `REQ-RISK-062` from the pages and proves the Lens flag equal to LPVaultSwap's pre-loan and callback checks; `FV-CTL-139` checks the exact-form example of `REQ-PSTORE-024`; `FV-CTL-58` reads the ParameterStore list of `MKT-027` between its ParameterStore and SettlementBudget clauses and compares the ParameterStore and SettlementBudget short tighten selectors of 1.4, 1.5, 2.9, 2.13, 2.15 and 3.8 with the compiled `IParameterStore*` and `ISettlementBudget` functions; `FV-CTL-62` classifies `tightenAssetWindow` and `tightenMarketWindow` as tighteners |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | As in `FV-CTL-R5` |
| Results | 180 checks: 174 Z3 or enumeration checks (168 Verified, 6 Verified under bounded model, 0 Violated, 0 open findings) and 6 Quint invariants with no violation in 10,000 samples; `check_ids.py` 422 cited IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | None new |
| Findings resolved | `FV-CTL-F-25` (`FV-CTL-58`), `FV-CTL-F-27` (`FV-CTL-78`, with `FV-CTL-139`) |
| Spec state | AMM-neutral spec, decisions `Q-001`…`Q-380`; `SPEC-LIQ-015` bounds `[0, 100]` with the liveness inequality; 1.4 and 2.13 list every SettlementBudget window setter |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R7 — 2026-11-10 — re-run after adding `tightenReservedFloor` (2.13 `REQ-BUDGET-029`)

| Item | Value |
|---|---|
| Date | 2026-11-10 (11:27) |
| What ran | Every model, with two readings updated for the SettlementBudget reserved floor: `FV-CTL-58` drops every 1.5 row whose contract column is SettlementBudget (now including `reservedFloor`) and every compiled `ISettlementBudget*` tighten selector from the 1.4 and 1.5 parameter readings, so SettlementBudget parameters are compared by selector against the compiled `ISettlementBudget*` functions, 2.13, 2.15, 1.5, 1.4 and 3.8 and not against the 2.9 ParameterStore table (as for `perCall` and the windows); `FV-CTL-62` classifies `tightenReservedFloor` as a tightener and `loosenReservedFloor` as a forbidden loosen selector, and enumerates the SettlementBudget loosen selectors as SettlementBudget candidates for `setShortDelaySelector` |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | As in `FV-CTL-R5` |
| Results | 180 checks: 174 Z3 or enumeration checks (168 Verified, 6 Verified under bounded model, 0 Violated, 0 open findings) and 6 Quint invariants with no violation in 10,000 samples; `check_ids.py` 422 cited IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | None new |
| Findings resolved | None (the `FV-CTL-58` and `FV-CTL-62` counterexamples on `tightenReservedFloor` were model scope and classification gaps; the pages already agree: 4 SettlementBudget tighten selectors on all 7 SettlementBudget readings) |
| Spec state | AMM-neutral spec, decisions through `Q-390`; 1.4, 1.5, 2.13, 2.15 (`SHORT_ELIGIBLE`, `REQ-ACCESS-058`, `REQ-ACCESS-155`) and 3.8 `MKT-027` name `tightenReservedFloor` as short |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R8 — 2026-11-10 — models brought to the parameter decisions `Q-395`…`Q-401`

| Item | Value |
|---|---|
| Date | 2026-11-10 (13:10) |
| What ran | Every model after the removed mechanisms left them. `fv_ctl_params.py`: the tighten model drops `minOpeningHealthFactor` and the price-drop, pool-share, seizure, route-failure and cooldown breaker thresholds and adds `hardFloorHealthFactor` (0 = off, else [1e18, 1.25e18]) and `gateRecoverySeconds` ([600, 7,200]); `FV-CTL-132` checks that 2.9 stores only `breakerDeficitMax`; `FV-CTL-58` requires every SettlementBudget reading to be empty; `FV-CTL-59`, `60`, `138`, `141` and `142` now check that no SettlementBudget source exists and that a keeper-funded settlement balances with the caller's top-up (`Q-397`). `fv_ctl_breakers.py`: `keeperFloor` = 1, new borrowing halts only at 0 active keepers (`Q-400`); price drop, seizure and route failures are alerts that no gate reads; the concentration gate is `poolShareMaxBps` without a peg condition; `breakerDeficitMax` example at 10,000 GHO (`Q-399`). `fv_ctl_gates.py`: the post-action check is `max(1.00, hardFloor, minHealthFactor)` and a rescue restores HF 1.10 (`Q-398`). `fv_ctl_registry.py` `FV-CTL-80`: no market function opens in-kind settlement (`Q-401`). `fv_ctl_timelock.py`, `fv_ctl_access.py`, `fv_ctl_amm.py`, `fv_ctl_upgrade_lens.py`: in-kind and SettlementBudget selectors and roles removed |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | As in `FV-CTL-R7` |
| Results | 3 Violated, all against `contracts/src` while the interface changes were still in progress: `FV-CTL-58` (compiled ParameterStore tighten selectors still hold `tightenMinOpeningHealthFactor` and the five removed breaker tighteners and lack `tightenHardFloorHealthFactor` and `tightenGateRecoverySeconds`, which 2.9 and 2.15 already name), `FV-CTL-59` (the `liquidation/settlement-budget/` interfaces and their references still exist) and `FV-CTL-138` (a source still names a market window). Every other check Verified; `check_ids.py` 422 cited IDs, 0 undefined |
| Exit code | 1 |
| Findings produced | None: the three violations close when the contract interfaces match 2.9 and 2.15 |
| Spec state | Decisions through `Q-402`; 2.9 and 2.15 already updated |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R9 — 2026-11-10 — compiled interfaces and every page aligned after `Q-395`…`Q-401`

| Item | Value |
|---|---|
| Date | 2026-11-10 (14:05) |
| What ran | Every model, after `contracts/src` took the parameter decisions and the pages were aligned. `fv_ctl_params.py`: 3.8 `MKT-027` lists the ParameterStore tighten selectors under their compiled names, `tightenHardHealthFloor` and `tightenGateRecoverySeconds` included; its parser reads the list up to the MarketRegistry entries, since no SettlementBudget section exists (`Q-397`); the tighten model and `P049` use `hardHealthFloor` and `gateRecoverySeconds`; 1.5 states the hard floor's safer direction as "raise or enable"; 1.4 `REQ-ROLE-112` no longer names the merged breaker pool-share selector. `fv_ctl_timelock.py`: `SHORT_ELIGIBLE` uses `tightenHardHealthFloor` / `loosenHardHealthFloor` (31 pairs, equal to the compiled list and the 2.15 launch list). `fv_ctl_breakers.py`: `FNS_B` holds only the trip and reset selectors (`recordLiquidationOutcome` and `recordRecoveryShortfall` are removed, `Q-399`); the address-freeze model checks no keeper floor (`Q-400`, 2.8 `REQ-MREG-021`), so `FV-CTL-92` now shows liquidation stays open through `liquidatePermissionless` and new borrowing halts at 0 active keepers, new witness `FV-CTL-92-W` reaches 0 active keepers, and `FV-CTL-105` states that only a guardian freeze takes active keepers below `keeperFloor`. `fv_ctl_access.py`: the MarketRegistry recorder is `recordBreach` (RiskModule only), and the containment graph drops the SettlementBudget and liquidation-outcome edges |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | As in `FV-CTL-R7` |
| Results | 175 properties Verified (bounded where stated), 0 Violated, 0 Unknown, no open finding; Quint `governance.qnt` 6 invariants with no violation (10,000 samples each); `check_ids`: 422 cited spec IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | None. The three `FV-CTL-R8` violations are closed by the compiled interfaces and 3.8 `MKT-027` |
| Spec state | Decisions through `Q-402`; 2.11 `REQ-SWAP-107`, 3.6 `EMG-090` and `INV-085` state that `freezeAddress` checks no keeper floor |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R10 — 2026-11-11 — protected set with the public flash liquidation helper

| Item | Value |
|---|---|
| Date | 2026-11-11 |
| What ran | `fv_ctl_breakers.py` only: `PROTECTED_KINDS` gains `PublicFlashLiquidator`, and `FV-CTL-93` requires 2.8 `REQ-MREG-020` to name "the public flash liquidation helper (`FLASH_LIQUIDATOR`" |
| Command | `../../../spec/05-verification/.venv/bin/python fv_ctl_breakers.py`, from this folder |
| Tools | As in `FV-CTL-R7` |
| Results | 21 checks, 0 violated or unknown; `FV-CTL-93` Verified with the helper among the protected kinds |
| Exit code | 0 |
| Findings produced | None |
| Spec state | Decision of 2026-11-11: the public flash liquidation helper is in the protected set (2.8 `REQ-MREG-020`, `REQ-CONFIG-005`; 2.15 `REQ-ACCESS-157`; `INV-085`; 3.6 `EMG-090`) |
| Output | `results/fv_ctl_breakers.json` |

## FV-CTL-R11 — 2026-11-11 — three models brought to the current spec and code

| Item | Value |
|---|---|
| Date | 2026-11-11 (21:00) |
| What ran | Every model, after three checks that failed on rules the spec no longer states were updated. `fv_ctl_params.py` (`FV-CTL-55`): the 2.10 state-effects table now has the token-decimals rows of `REQ-ORACLE-107`; "Live, token decimals last verified more than `DECIMALS_CHECK_MAX_AGE` ago (bit 19)" is checked as Live (pledges allowed), and "A token's decimals changed or unreadable" as both Cached and Expired (pledges blocked), against the RiskModule rule `RiskModulePledgeLogic` applies. `fv_ctl_upgrade_lens.py` (`FV-CTL-78`): the Lens `premiumWithinMax` flag no longer exists (`Q-404`: `liquidate` takes no flash loan); the check now covers the loans that remain. Seven rules (`REQ-PSTORE-024`, `SPEC-LIQ-015`, `REQ-FLASH-001`, `-002`, `-003`, `REQ-SWAP-013`, `REQ-HELPER-005`) must state the exact form `φ × 10⁴ ≤ maxFlashFeeBps × F`; `REQ-SWAP-012`, `REQ-LENS-029` and `REQ-RISK-062` must keep the loan out of liquidation, the preview and the borrow gate; `SettlementMath.flashPremiumWithinCap`, which `AaveV3FlashSource` and `FlashLiquidatorBase` both call, is modelled branch by branch and must equal the exact form for every input; a ceiling quote that passes before the loan must imply that the Pool's half-up charge passes in the callback. A mutant that rounds the code's first branch up is caught. `fv_ctl_breakers.py` (`FV-CTL-93`): the protected set adds the flash source's `LENDER()`, every integration's pricing implementation and every AMM contract recorded with `recordIntegrationContracts` (replacing "position manager and factory"); each kind must be named in 2.8 `REQ-MREG-020` and must be a condition of `MarketRegistrySafetyLogic._isProtected`, and `freeze_check` now uses the set the code protects. `FV-CTL-104` is restated over 24 one-hour buckets (`REQ-MREG-019`), and the module text no longer lists a coverage breaker |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | Python 3.9.6 from `spec/05-verification/.venv`; z3-solver 4.13.0; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | As in `FV-CTL-R5` |
| Results | 175 Z3 or enumeration checks (169 Verified, 6 Verified under bounded model, 0 Violated, 0 Unknown, no open finding) and 6 Quint invariants with no violation in 10,000 samples; `check_ids.py` 423 cited spec IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | None. The three violations before this run came from models that encoded removed rules; the spec and the code agree on each |
| Spec state | Decisions through `Q-406`; 2.10 with `REQ-ORACLE-107` (`Q-405`); 2.8 `REQ-MREG-020` with the flash source's lender and `recordIntegrationContracts` (`REQ-MREG-035`); `Q-404` (no flash loan in a liquidation) |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |

## FV-CTL-R12 — 2026-11-13 — speed limits on every page; served price after ORACLE-02

| Item | Value |
|---|---|
| Date | 2026-11-13 |
| What ran | Every model, after the speed-limit tighten selectors (`tightenMarketSpeedLimits`, `tightenDebtSpeedLimit`, `Q-411`) were named on 1.4 `REQ-ROLE-027`, 1.5, 2.9 `REQ-CONFIG-049`, 2.15 and 3.8 `MKT-027`. `fv_ctl_params.py`: `marketSpeedLimits` and `debtSpeedLimit` added to the `REQ-CONFIG-049` reading (`FV-CTL-58`, each must appear in the page text); `FV-CTL-153` passes, so `FV-CTL-F-26` is resolved. `fv_ctl_oracle.py`: `FV-CTL-63`, 67, 110–113 encode the served price of `SPEC-ORC-017` after `ORACLE-02` (Drifting serves fresh; a disagreement serves `min(lower, fresh)`), exact per state |
| Command | `audit/formal-verification/control/run.sh` |
| Tools | As in `FV-CTL-R11` |
| Seeds and bounds | As in `FV-CTL-R5` |
| Results | 175 checks over 10 modules, 0 Violated, 0 Unknown, no open finding; 6 Quint invariants with no violation in 10,000 samples; `check_ids.py`: 423 cited spec IDs, 0 undefined |
| Exit code | 0 |
| Findings produced | None; `FV-CTL-F-26` resolved |
| Output | `results/run.log`, `results/<model>.json`, `results/quint.txt` |
