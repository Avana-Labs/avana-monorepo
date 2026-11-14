# Z3 recorded results

Copied from the Results sections of the Z3 folder READMEs in docs/spec/05-verification/z3/ as of 2026-11-10.

## z3/


Run on 2026-11-10 with Python 3.9.6 and z3-solver 4.13.0, 120 s per query, no timeouts.

| Folder | Scripts | Proved | Counterexample | Computed | Mismatch | Scripts exiting 1 |
|---|---|---|---|---|---|---|
| `units-oracle/` | 11 | 149 | 22 (all deliberate) | 8 | 0 | none |
| `aave-risk/` | 10 | 127 | 12 (all deliberate) | 41 | 0 | none (F-AR-1…F-AR-5 resolved in spec) |
| `settlement/` | 14 | 206 | 46 (all deliberate) | 17 | 0 | none (findings MATH-ST-58, 75, 77, 84 resolved in spec) |
| `docs/governance/` | 2 | 27 | 3 (all deliberate) | — | 0 | none |
| **Total** | **37** | **509** | **83** | **66** | **0** | **0** |

Findings against the final text, with counterexamples and the exact recommended changes, are listed in each folder's README:

| Check | Spec text | Severity | Summary |
|---|---|---|---|
| MATH-AR-37 | 2.6 and 3.2 worked examples | low | The "largest USDC borrow 14,183.24" fails the opening gate; 14,183.23 is the largest. Resolved in spec: MATH-AR-37 COMPUTED |
| MATH-AR-24d | `SPEC-HUB-004` example | low | Cites a 1,000 GHO minimum debt that no longer exists. Resolved in spec: MATH-AR-24d PROVED |
| MATH-AR-47c | `SPEC-CAP-003` | low | "At most 3 units" of rounding holds only while `price8 ≥ stressFloorUsd`. Resolved in spec: MATH-AR-47c PROVED |
| MATH-AR-44b, MATH-ST-77 | `SPEC-CAP-007`(ii), `SPEC-CAP-008`, `SPEC-FLR-005` | low (guidance) | The tail term divides by `minOpeningHealthFactor`; debt can reach collateral × `CF_t` before liquidation. Resolved in spec for `SPEC-CAP-007`, `SPEC-CAP-008`, `tokenUsdCap`, `Q-249` and `MKT-013`: MATH-AR-44b PROVED; `SPEC-FLR-005` resolved in spec under MATH-ST-77: MATH-ST-78 PROVED, MATH-ST-91 COMPUTED |
| MATH-AR-50c | `SPEC-CAP-006` | low | After a cap tightening a slice top-up can pass Avana's budget but fail the Hub's `addCap`. Resolved in spec: MATH-AR-50c PROVED |
| MATH-ST-58 | `SPEC-SET-002` example | low | Its parameters gave `s = 0`, so no draw happens. Resolved in spec (cBuy 150, `Bd = 1.000004089556` GHO): MATH-ST-58 COMPUTED |
| MATH-ST-84 | `SPEC-LIQ-014` example | low | `U` omitted the USDT price ($0.9995). Resolved in spec: MATH-ST-84 COMPUTED |
| MATH-ST-75 | `SPEC-LIQ-020` | low | The health-factor threshold ignored `U` and rounding. Resolved in spec: MATH-ST-75 PROVED (corrected threshold) |

## z3/aave-risk


| Date | Command | Versions | Bounds | Proved | Counterexample | Computed | Mismatch | Timeout | Exit |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-10 | `../../.venv/bin/python <file>.py` for `ar01` … `ar10` | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 122 | 16 (12 deliberate, 4 findings) | 40 | 1 (finding) | 0 | 0 for ar01, ar03, ar04, ar06, ar09, ar10; 1 for ar02 (F-AR-1), ar05 (F-AR-2), ar07 (F-AR-4), ar08 (F-AR-3, F-AR-5) |
| 2026-11-10 (after the spec fixes) | same | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 127 | 12 (all deliberate) | 41 | 0 | 0 | 0 for every script; F-AR-1…F-AR-5 resolved in spec |
| 2026-11-10 (restore amount divided by the served price, `SPEC-CAP-003`; `MATH-AR-47f` added) | same | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 127 | 12 (all deliberate) | 41 | 0 | 0 | 0 for every script; `ar08` 24 proved, 8 computed |
| 2026-11-10 (no minimum debt, `Q-381`: `MATH-CH-01` and `MATH-CAP-09` rewritten from the keeper break-even to the `SPEC-CHAIN-001` gas units model, and `MATH-CAP-09` adds the `SPEC-CAP-009` idle test; scripts renamed `ch01_gas_model.py` and `ar11_record_gas_credit_lines.py`) | `../../.venv/bin/python ch01_gas_model.py`, `ar11_record_gas_credit_lines.py` | Python 3.9.6, z3-solver 4.13.0 | 120 s per query | ch01 2, ar11 10 | 0 | ch01 7 figures, ar11 4 | 0 | 0 | 0 for both |
| 2026-11-10 (parameter decisions `Q-396`, `Q-398`, `Q-399`, `Q-400`: `ar02` gate at HF 1.00 with an optional hard floor and the Lens recommended borrow at HF 1.10; `ar09` price drop, seizure surge and route failures as alerts, pool share 10%, deficit 10,000 GHO, 30-minute reopening; `ar10` keeperFloor 1; `ar11` `MATH-CAP-09e–h` rewritten from the removed idle test to the Lens capacity) | same | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 139 | 12 (all deliberate) | 52 | 0 | 0 | 0 for every script |

Per script (proved / counterexample / computed / mismatch), latest run: ar01 14/0/5/0; ar02 11/1/3/0; ar03 15/2/5/0; ar04 12/1/2/0; ar05 12/3/2/0; ar06 6/1/2/0; ar07 7/1/2/0; ar08 24/0/8/0 (includes MATH-AR-47f); ar09 12/2/6/0; ar10 14/1/6/0; ar11 10/0/4/0; ch01 2/0/7/0.


## z3/settlement


**315 checks after the removal of the settlement budget and of in-kind settlement, the flash-source cap rule, the LitePSM gem amount and the V3.4 half-up premium check (2026-11-10): every script exits 0, 0 mismatches, 0 timeouts.**

| Script | Checks | Proved | Counterexample | Computed | Mismatch | Exit |
|---|---|---|---|---|---|---|
| st01 | 4 | 2 | 2 | — | — | 0 |
| st02 | 117 | 94 | 23 | — | — | 0 |
| st03 | 14 | 12 | 2 | — | — | 0 |
| st04 | 19 | 14 | 4 | 1 | — | 0 |
| st05 | 6 | 4 | 2 | — | — | 0 |
| st06 | 5 | 4 | 1 | — | — | 0 |
| st07 | 6 | 3 | 3 | — | — | 0 |
| st08 | 11 | 10 | 1 | — | — | 0 |
| st09 | 7 | 6 | 1 | — | — | 0 |
| st10 | 26 | 22 | 4 | — | — | 0 |
| st11 | 11 | 8 | 2 | 1 | — | 0 |
| st12 | 15 | 14 | 1 | — | — | 0 |
| st13 | 4 | 3 | 1 | — | — | 0 |
| st14 | 16 | — | — | 16 | — | 0 |
| st15 | 8 | 3 | 1 | 4 | — | 0 |
| st16 | 46 | 29 | 8 | 9 | — | 0 |

### Run log

| Date | Command | Versions | Bounds | Result | Exit |
|---|---|---|---|---|---|
| 2026-11-10 | `.venv/bin/python z3/settlement/<script>.py` for st01…st14, from `docs/spec/05-verification` | Python 3.9.6, z3-solver 4.13.0 | amounts < 2¹²⁸ (waterfall), `D ≤ 10²⁶` wei, shares < 2¹²⁰, 120 s per query; no random seeds | 269 checks as above; slowest script st10 (30 s) | 0 for st01–st03, st05–st11; 1 for st04, st12, st13, st14 (findings 1–4) |
| 2026-11-10 | `.venv/bin/python z3/settlement/<script>.py` for st04, st12, st13, st14, from `docs/spec/05-verification`, after the spec fixes of findings 1–4 | Python 3.9.6, z3-solver 4.13.0 | as above | st04 23 proved, 5 counterexamples, 1 computed; st12 13 / 1; st13 3 / 1; st14 16 computed; every script reports 0 results differing from the documented ones | 0 for all four |
| 2026-11-10 | `.venv/bin/python z3/settlement/<script>.py` for st01…st15, from `docs/spec/05-verification`, after the debt-asset settlement refactor (`Q-333`…`Q-348`) | Python 3.9.6, z3-solver 4.13.0 | as above | 277 checks; st03, st04, st11 and st15 rewritten or extended; 0 differ from documented results | 0 |
| 2026-11-10 | `.venv/bin/python <script>.py` for st01…st16, from `docs/spec/05-verification/z3/settlement` (consolidation: MATH-ST-72, `-85`, `-94` retargeted to the flash of the debt asset with payout in the debt asset; st16 added) | Python 3.9.6, z3-solver 4.13.0 | as above; the informational MATH-ST-64 maximum at s = 30 runs with a 600 s limit | 313 checks; 0 differ from documented results | 0 |
| 2026-11-10 | `.venv/bin/python z3/settlement/st10_leg_minout.py`, from `docs/spec/05-verification`, after the dust-leg rule (`REQ-SWAP-121`) | Python 3.9.6, z3-solver 4.13.0 | as above | st10: 26 checks (MATH-ST-111 added, 5 proved); 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st01…st16, from `docs/spec/05-verification/z3/settlement`, after the no-minimum-debt decision (`Q-381`) and the budget reserve, flash-source Hub and transfer-fee rules (`Q-387`, `Q-388`, `Q-390`): MATH-ST-108 rewritten to the record-cap gas fit, MATH-ST-109/110 extended, MATH-ST-111/112 added | Python 3.9.6, z3-solver 4.13.0 | as above | 322 checks (st16: 51); 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st01…st16, from `docs/spec/05-verification/z3/settlement`, after the removal of the settlement budget and in-kind settlement (`Q-397`, `Q-401`): st04 and st05 rewritten under their IDs to the caller's rounding gap and the payout escrow; st03, st11, st14, st15, st16 updated | Python 3.9.6, z3-solver 4.13.0 | as above | 303 checks; 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python st11_buy_leg.py`, from `docs/spec/05-verification/z3/settlement`, after the flash-source cap rule (SettlementMath review S3): MATH-ST-115 added | Python 3.9.6, z3-solver 4.13.0 | as above | st11: 10 checks (7 proved, 2 counterexamples, 1 computed) and one `[MAX]` of 999; 0 differ from documented results | 0 |
| 2026-11-10 | `.venv/bin/python z3/settlement/st15_debt_asset_settlement.py`, from `docs/spec/05-verification`: MATH-ST-120 added (LitePSM gem amount, `REQ-ROUTE-012`) | Python 3.9.6, z3-solver 4.13.0 | as above; `D < 2¹²⁸`, `tout < 10³⁶`, `c ≤ 10¹⁸` | st15: 8 checks (3 proved, 1 counterexample, 4 computed); 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python <script>.py` for st03, st04, st12, st14, st15, st16, from `docs/spec/05-verification/z3/settlement`, after the SettlementMath review fixes (S2 settlement gap on the whole flash obligation, S4 `ε` in `Vnet`): MATH-ST-121, `-122`, `-123` added; MATH-ST-17, `-18`, `-26`, `-53`, `-60` restated (a binding gap now settles with `keeperOut = 0`; MATH-ST-53 and `-60` were PROVED for `keeperOut < 0` before) | Python 3.9.6, z3-solver 4.13.0 | as above | st03 18 checks, st04 19, st12 19, st14 16, st15 8, st16 46; 0 differ from documented results | 0 |
| 2026-11-10 | `../../.venv/bin/python st11_buy_leg.py`, from `docs/spec/05-verification/z3/settlement`, after the flash-source review (V3.4 charges half-up; the source's ceiling quote is the binding gate): MATH-ST-115 gains the half-up ≤ quote check | Python 3.9.6, z3-solver 4.13.0 | as above | st11: 11 checks (8 proved, 2 counterexamples, 1 computed) and one `[MAX]` of 999; 0 differ from documented results | 0 |

## z3/governance


| Date | Command | Versions | Bounds | Proved | Counterexample | Timeout | Exit |
|---|---|---|---|---|---|---|---|
| 2026-11-10 | `../../.venv/bin/python gv01_timelock_timing.py`; `../../.venv/bin/python gv02_delay_floor_allowlist.py` | Python 3.9.6, z3-solver 4.13.0 | batches of 6 calls, sequences of 4–5 calls; 120 s per query | 27 (15 + 12) | 3 (2 + 1, all deliberate) | 0 | 0 for both scripts |

## z3/units-oracle


| Date | Command | Versions | Bounds | Proved | Counterexample | Computed | Timeout | Exit |
|---|---|---|---|---|---|---|---|---|
| 2026-11-10 | `../../.venv/bin/python <file>.py` for `uo01` … `uo11` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 149 | 22 (all deliberate) | 8 | 0 | 0 for every script |
| 2026-11-10 (AMM-neutral oracle) | `../../.venv/bin/python <file>.py` for `uo01` … `uo12` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 166 | 25 (all deliberate) | 15 | 0 | 0 for every script |
| 2026-11-10 (LPPriceMath input bounds) | `../../.venv/bin/python <file>.py` for `uo12`, `uo13` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 33 | 9 (all deliberate) | 13 | 0 | 0 for both scripts |

Per script: `uo01` 14 / 4 / 3, `uo02` 31 / 0 / 1, `uo03` 12 / 2 / 1, `uo04` 10 / 2 / 1, `uo05` 8 / 1 / 0, `uo06` 5 / 4 / 0, `uo07` 13 / 4 / 1, `uo08` 9 / 4 / 1, `uo09` 17 / 1 / 0, `uo10` 8 / 0 / 0, `uo11` 23 / 0 / 0, `uo12` 16 / 3 / 7, `uo13` 17 / 6 / 6 (proved / counterexample / computed; `MATH-UO-45c` added on 2026-11-10 with the final `SPEC-ORC-016`; `uo13` added on 2026-11-10 with the LPPriceMath input bounds, the fixed-point USD level and the disagreement price `min(lower, fresh, A)`; it takes about 2 minutes). The slowest script, `uo01`, takes about 26 s.

## z3/amm-pricing

