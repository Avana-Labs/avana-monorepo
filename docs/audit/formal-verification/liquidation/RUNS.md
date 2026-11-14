# Liquidation area: run log

One entry per run of the liquidation checks (`FV-LIQ-*`). Each new run appends an entry; earlier entries are never edited. Findings are tracked in the [findings register](../../findings-register.md); the full results of the reported run are in [report.md](report.md).

`run.sh` in this folder treats a finding's counterexample check as passing when the counterexample exists (`expect_violation`), so it exits 0 while findings are open. It exits non-zero only on an unexpected violation, a solver timeout, a vacuous premise or a Quint result that differs from its expectation. Once a finding's rule changes, its counterexample check fails and is replaced by the fix proof.

## FV-LIQ-R1 — 2026-11-09 — reported run

| Item | Value |
|---|---|
| Date | 2026-11-09 |
| What ran | Seven Z3 and exact-integer model files (`fv_liq_01_settlement_math` … `fv_liq_07_system`), the Hypothesis cross-check on the Aave V4 port (`aave_ref.py`), and seven `quint run` checks of `liquidation.qnt` |
| Command | `docs/audit/formal-verification/liquidation/run.sh` |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Hypothesis 6.112.5; Quint 0.22.4 (`quint run`, randomized) |
| Seeds and bounds | Quint: 10,000 traces × 25 steps per check (`QNT_SAMPLES`, `QNT_STEPS`); `run.sh` passes no `--seed`, so each Quint check draws its own seed and prints it. Hypothesis: 2,845 successful random liquidations on the exact port. Amounts `< 2^128`, prices `< 2^64`, `b < 2^32`, `cBuy ≤ 300`, `drawnIndex ≤ 100 RAY`; escrow sums over 4 borrower slots; budget cap sums over 6 symbolic draws; all 170 control paths of `liquidate` and `liquidatePermissionless`. |
| Results | 148 checks pass: 81 formal proofs (11 of them over all 170 paths), 31 exact checks of worked examples, bounds and oracle edge cases, 1 Hypothesis cross-check, 14 finding counterexamples and replays, 2 accepted violations, 12 mutants caught, 7 Quint runs. Per file: 34, 16, 22, 13, 16, 26 and 14 obligations, 0 failed. |
| Exit code | 0 (finding counterexamples are expected results; see above) |
| Findings produced | `FV-LIQ-F-01` (`01d`, `01t`, `06v`), `FV-LIQ-F-02` (`01s`, `06w`), `FV-LIQ-F-03` (`01o`), `FV-LIQ-F-04` (`02o`), `FV-LIQ-F-05` (`06x`), `FV-LIQ-F-06` (`01z`, `06y`, `06z`, `07i`), `FV-LIQ-F-07` (`04k`), `FV-LIQ-F-08` (`03t` replays the mid-edit text; fixed in the final 2.11), `FV-LIQ-F-09` (fixed in the final 3.5; `06o` re-verifies) |
| Spec state | Decisions `Q-001`…`Q-240`; final pages 2.11–2.14, 2.17, 2.18, 3.5 and 3.9 of 2026-11-09; Aave V4 at `a3ef63ea6415d25237a9775bf66e76e9993561c2` |
| Output | Console only; the counts above are those stated in [report.md](report.md) section 7 |

## FV-LIQ-R2 — 2026-11-09 — confirmation re-run

| Item | Value |
|---|---|
| Date | 2026-11-09, 22:00 EST |
| What ran | The same checks as `FV-LIQ-R1`, to confirm the reported counts |
| Command | `docs/audit/formal-verification/liquidation/run.sh` |
| Tools | Python 3.9.6; z3-solver 4.13.0; Hypothesis 6.112.5; Quint 0.22.4; Node.js 22.18.0 |
| Seeds and bounds | Quint 10,000 × 25 per check, seeds drawn by Quint: `08a` `0x730041b2d2fb5`, `08b` `0x1eff993cb58c51`, `08c` `0x8a981957b5936`, `08w1` `0xb0c10a95eb2d9`, `08w2` `0x56d1e02cdb709`, `08w3` `0x1bee6b9d2c6b7e`, `08w4` `0xd5d14033e3fab`. Hypothesis: 2,845 successful calls. Other bounds unchanged. |
| Results | 148 `[PASS]`, 0 failed (34, 16, 22, 13, 16, 26 and 14 obligations; 7 Quint checks with their expected outcome: `08a`, `08b` hold, `08c` violated as expected, `08w1`…`08w4` witnesses reached). Identical to `FV-LIQ-R1`. |
| Exit code | 0 |
| Wall time | 135 s, run alongside the custody, control and simulation re-runs |
| Findings produced | None new |
| Spec state | Decisions `Q-001`…`Q-240`. Decisions `Q-241`…`Q-278` were recorded in 4.4 by then but are not modelled. |

## FV-LIQ-R3 — 2026-11-10 — re-verification against the final spec

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The seven model files and `liquidation.qnt`, updated to the final pages 2.11–2.14, 2.17, 2.18, 3.5 and 3.9: fee from the oracle value and the sell-back floor; the `s = 0` rule and two-leg liveness; the corrected draw bound with `perCall ≥ 2 × floorRoundingAllowanceGho`; `φD` on `min(F, Gcov)`; the Lens whole-debt preview and Aave-formula seizure; closed reserves skipped by `REQ-CONFIG-050`; per-reserve freshness, stale-at-Expired and lower-route valuation; per-leg `minOut`; the shortfall top-up and automatic in-kind; `probeLiquidation` and `reportRecoveryShortfall`; `deleverage`; the per-market budget cap; per-asset coverage and its breakers; the address freeze and the application pause in the Quint model. The rules that fix `FV-LIQ-F-01`…`F-09` are the main rules; the text they replaced runs as mutants |
| Command | `docs/audit/formal-verification/liquidation/run.sh` |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Hypothesis 6.112.5 (`derandomize=True`); Quint 0.22.4 (`quint run`, randomized); Node.js 22.18.0 |
| Seeds and bounds | Quint 10,000 traces × 25 steps per check, seeds drawn by Quint: `08a` `0x1d84f437bab6d`, `08b` `0xd44de49b39009`, `08c` `0xed2693746256f`, `08w1` `0x1a011d2dcb2811`, `08w2` `0x3756e6ba4e3f7`, `08w3` `0x10867c7fd773ab`, `08w4` `0x1efcb0d4b5ac49`, `08w5` `0x19ae68a75af1c1`, `08w6` `0x85e8c80b45d7b`. Hypothesis: 2,845 successful calls (02n), 6,000 examples (02o), 8,000 (02v), 8,000 (02z); decimals {6, 8, 12, 18}, prices 10⁴–10¹², drawn index RAY–3 RAY. All 170 control paths of `liquidate` and `liquidatePermissionless` and all 9 of `deleverage`; budget sums over 6 symbolic draws with 2 reserves and 2 markets; escrow sums over 4 borrower slots; amounts `< 2^128`, prices `< 2^64`. |
| Results | 256 `[PASS]`, 0 failed. Per file: 55, 29, 35, 16, 26, 68 and 18 obligations; 9 Quint checks with their expected outcome (`08a`, `08b` hold; `08c` violated as expected; `08w1`…`08w6` witnesses reached). By kind: 196 formal proofs and exact checks (19 over every path, 56 worked-example checks), 4 Hypothesis cross-checks, 30 mutants caught, 3 accepted violations, 14 counterexamples of new findings, 9 Quint runs. |
| Exit code | 0 |
| Findings produced | `FV-LIQ-F-10` Low (01z2, 06z), `F-11` Informational (01aj), `F-12` Informational (01ag2), `F-13` Medium (02x, 02x2), `F-14` Low (02y, 02y2), `F-15` Informational (05z), `F-16` Informational (06w2), `F-17` Informational (06bb2, 06bb3), `F-18` Informational (06ay2), `F-19` Informational (06ba2); [report.md](report.md) section 9 |
| Findings re-verified | `FV-LIQ-F-01`…`F-09` pass against the changed rules (report section 9) |
| Trace | `docs/spec/05-verification/trace.py`: 0 errors from this folder (the 14 errors it reports are spec pages citing `HYP-12`, `HYP-25`, `HYP-35` and `HYP-50`, which no model file defines) |
| Spec state | Decisions `Q-001`…`Q-278`; final pages 2.11–2.14, 2.17, 2.18, 3.5 and 3.9; Aave V4 at `a3ef63ea6415d25237a9775bf66e76e9993561c2` |
| Output | Console only |

## FV-LIQ-R3a — 2026-11-10 — `SPEC-CAP-008` tail example after the `CF_t` correction

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | `fv_liq_05_escrow_coverage.py` only. Check `05y` now computes the `SPEC-CAP-008` example tail as `⌈450,000 × 10^8 × 3,120 / 10^4⌉` (no division by `minOpeningHealthFactor`, finding `F-AR-4`, `FINDING-167`) and expects `14,040,000,000,000` and `7,122` bps; its `REQ-LENS-034`, `SPEC-FLR-005` and `REQ-FLR-041` figures are unchanged |
| Command | `../../../spec/05-verification/.venv/bin/python -u fv_liq_05_escrow_coverage.py` from this folder |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0 |
| Results | 26 obligations, 0 failed; `05z` (`FV-LIQ-F-15`) still reports its counterexample, as recorded |
| Exit code | 0 |
| Spec state | `SPEC-CAP-007` (ii) and `SPEC-CAP-008` with the `CF_t` tail term; `SPEC-CAP-008` states that `drawCapUsd = type(uint256).max` when any `drawCap` is `MAX_ALLOWED_SPOKE_CAP` |
| Output | Console only |

## FV-LIQ-R4 — 2026-11-10 — findings `FV-LIQ-F-10`…`F-19` resolved in the spec

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| What ran | The seven model files and `liquidation.qnt` after the spec fixes of `FV-LIQ-F-10`…`F-19` and `HYP-85`. Each model now checks the final text, and each old text is kept as a mutant: `SPEC-LIQ-009` cap `max(0, R' − Gcov − φD)` (`01y2`, `06z2`; mutants `01z2`, `06z`); `SPEC-LIQ-020` threshold with `U + 2` (`01ak`; mutant `01aj`); `SPEC-LIQ-018` / `INV-083` sum bounds with the clamped-leg case and the LP-price term `⌈2·c·10¹⁰ / 10^d⌉` (`01ag`, `01ag3`; mutant `01ag2`); `REQ-LENS-028` margined whole-debt quote, implemented in `aave_ref.lens_preview` (`02v`, `02v2`, `02w`, `02x2`, `02y2`, `02z`, `06u`, `06x`; mutants `02x`, `02y`); `REQ-LENS-034` / `SPEC-CAP-008` / `SPEC-FLR-005` tail term `× CF_t` and unlimited draw cap (`05x`, `05y`, `05z2`, `06aw`; mutants `05z`, `06awm`); `SPEC-SET-002` example at cBuy 150 (`06w4`; mutant `06w2`); `LIQ-069` account 40,456.119927 USDC (`06bb`, `06bb3`, `06bb4`; mutant `06bb2`); `DEF-006` (`06ay2`; mutant `06ay2m`); `LIQ-068` (`06ba2`; mutant `06ba2m`) |
| Command | `docs/audit/formal-verification/liquidation/run.sh` |
| Tools | Python 3.9.6 from `docs/spec/05-verification/.venv`; z3-solver 4.13.0; Hypothesis 6.112.5 (`derandomize=True`); Quint 0.22.4 (`quint run`, randomized); Node.js 22.18.0 |
| Seeds and bounds | Quint 10,000 traces × 25 steps per check: `08a` `0x8c44d1e03f58b`, `08b` `0x17b04b8507aa07`, `08c` `0x1fceea8f5b625d`, `08w1` `0x77c1f108990b5`, `08w2` `0x1d68488e8fe321`, `08w3` `0x3eedb369358e7`, `08w4` `0xee78bf36c4fbf`, `08w5` `0x87068d763fb17`, `08w6` `0x30574d473d071`; Python bounds as in the model files |
| Results | 261 `[PASS]`, 0 failed. Per file: 55, 29, 35, 16, 27, 72 and 18 obligations; 9 Quint checks with their expected outcome. No finding counterexample remains: every earlier finding check is now a passing check of the final text or a mutant of the old text. 3 accepted violations (07c, 07d, 07i2) as before. 3 min 22 s wall |
| Exit code | 0 |
| Findings produced | None |
| Findings resolved | `FV-LIQ-F-10`…`F-19` (`FINDING-189`…`FINDING-198`) |
| Spec state | Decisions `Q-001`…`Q-278`; `SPEC-LIQ-009`, `SPEC-LIQ-014`, `SPEC-LIQ-018`, `SPEC-LIQ-020`, `REQ-SWAP-005`, `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-034`, `SPEC-SET-002`, `SPEC-FLR-005`, `REQ-FLR-041`, `SPEC-CAP-008`, `INV-036`, `INV-038`, `INV-083`, `INV-086`, `LIQ-068`, `LIQ-069`, `DEF-006` as fixed on 2026-11-10 |
| Output | Console only |

## FV-LIQ-R5 — 2026-11-10 — re-run after the debt-asset settlement refactor

| Field | Value |
|---|---|
| Command | `QNT_SAMPLES=2000 bash run.sh`, from this folder |
| Versions | Python 3.9.6, z3-solver 4.13.0, Quint from `docs/spec/05-verification/node_modules` |
| Result | `LIQUIDATION AREA: all checks passed`, exit 0 |
| Spec state | 2.11, 2.12, 2.13 and 2.18 rewritten for debt-asset settlement through `IFlashSource` (`Q-333`…`Q-348`) |
| Models changed | None. The `fv_liq_*` models are self-contained and still encode the GHO-settlement design (GHO flash, buy leg, sell-back); none fails, because each checks its own stated figures. Their GHO-debt cases equal the new design with `cBuy = 0` and `Gcov = Gnet = D`; the buy-leg and sell-back checks (`FV-LIQ-06m` and the `Gcov` rows) no longer describe a live rule. The debt-asset waterfall, borrower surplus, flash checks and per-market budget windows are checked in `docs/spec/05-verification/z3/settlement` (`MATH-ST-14`…`20`, `51`…`55`, `68`…`70`, `96`…`103`) |
| Findings produced | None |
| Output | Console only |

## FV-LIQ-R6 — 2026-11-10 — models rewritten for debt-asset settlement

| Field | Value |
|---|---|
| Command | `QNT_SAMPLES=2000 bash run.sh`, from this folder |
| Versions | Python 3.9.6, z3-solver 4.13.0, Hypothesis 6.112.5 (`derandomize=True`), Quint from `docs/spec/05-verification/node_modules` |
| Seeds and bounds | Quint 2,000 traces × 25 steps per check: `08a` `0x1a1b378e43c245`, `08b` `0x1656c8295f6ac3`, `08c` `0xde3fe33269141`, `08w1` `0x4eb46166b1607`, `08w2` `0x1696bbcfe85b45`, `08w3` `0x96bc0299ec70b`, `08w4` `0x1dfacd73327ff3`, `08w5` `0x1d12f41c869143`, `08w6` `0x80cb8a480180b`; Python bounds as in the model files |
| Results | 266 `[PASS]`, 0 failed: `FV-LIQ-01` 60, `02` 29, `03` 35, `04` 16, `05` 27, `06` 72, `07` 18 obligations, 9 Quint checks with their expected outcome; 3 accepted violations (07c, 07d, 07i2) as before. 113 s wall |
| Exit code | 0 |
| Spec state | 2.11 after `Q-333`…`Q-348`: flash loan of the debt asset through `IFlashSource` (Aave V3 Pool `flashLoan`), standard Spoke `liquidationCall(..., receiveShares = false)`, n-token unwind, swaps into the debt asset, payout split `A + kr + B = S` in the debt asset, per-market budget windows |
| Models changed | `fv_liq_01`: no buy-leg term in `SPEC-LIQ-003`, one-leg liveness, flash pre-loan bound (`01h`), `Gcov = Gnet = D` (`01i`), waterfall with the borrower surplus (`01j`…`01q`), leftover outside `R` (`01y2`, mutant `01z2`), no sell-back (`01ab`), deleverage flash sizing (`01ai`); new `01al`…`01ap` (payout split, `B = 0` after a shortfall or a draw, mutant without `B`, flash-source gates). `fv_liq_03`: one token `T` for funding, flash, legs and payouts; borrower surplus delivered or escrowed; buy and sell-back paths removed (62 paths, was 170); flash-source callback names. `fv_liq_04`: per-market window caps set at listing (`04m`). `fv_liq_06`: the 2.11 examples recomputed in USDC (`dd = 6`, 5 bps premium), buy-leg and sell-back examples replaced by the leftover, flash-bound, borrower-surplus and `s = 0` examples, gas guard `+ POST_CALL_GAS`. `fv_liq_02`, `fv_liq_07`: funding and leftover wording, self-liquidation with `B`, flash bound in place of the buy bound |
| Findings produced | None |
| Output | Console only |

## FV-LIQ-R7 — 2026-11-10 — re-run after the 2.11 alignment to the compiled interfaces

| Field | Value |
|---|---|
| Command | `QNT_SAMPLES=2000 bash run.sh`, from this folder |
| Versions | Python 3.9.6 from `docs/spec/05-verification/.venv`, z3-solver 4.13.0, Quint from `docs/spec/05-verification/node_modules` |
| Result | 266 `[PASS]`, 0 failed (the seven model files and 9 Quint checks at 2,000 traces × 25 steps); `LIQUIDATION AREA: all checks passed`, exit 0 |
| Spec state | 2.11 gas guards at `⌈64·G/63⌉ + POST_CALL_GAS` (5,000), as `FV-LIQ-06ah` assumes; flash source read from `MarketRegistry.flashSource()` with `flashPremium` and `LENDER()`; `REQ-SWAP-025` states that no pool spot price gates a liquidation; `LiquidationParams` with `keeperFunds` and `minAmounts` |
| Models changed | None since `FV-LIQ-R6` |
| Findings produced | None |
| Output | Console only |

## FV-LIQ-R8 — 2026-11-10 — re-run after the no-minimum-debt decision and the budget reserve, flash-source Hub and payout rules

| Field | Value |
|---|---|
| Command | `QNT_SAMPLES=2000 bash run.sh`, from this folder; then, from `docs/spec/05-verification`, every script of `z3/settlement`, `z3/units-oracle` and `sympy` with `.venv/bin/python` |
| Versions | Python 3.9.6 from `docs/spec/05-verification/.venv`, z3-solver 4.13.0, Quint from `docs/spec/05-verification/node_modules` |
| Result | Liquidation area: 271 `[PASS]`, 0 failed (the seven model files and 9 Quint checks at 2,000 traces × 25 steps); `LIQUIDATION AREA: all checks passed`, exit 0. `z3/settlement` st01…st16: 322 checks, 0 differ, every script exit 0. `z3/units-oracle` uo01…uo12: 206 checks, every script exit 0. `sympy` sym01…sym10: 240 checks, 0 differ from the README, every script exit 0 |
| Spec state | No minimum debt on any chain (`Q-381`); 2.13 reserved floor per market (`SPEC-SET-007`, `REQ-BUDGET-027`…`-029`, `Q-387`); 2.11 flash source refused when its `LENDER()` is any recorded Hub, per call and in `setFlashSource` (`REQ-FLASH-005`, `-006`, `Q-388`); every failed payout transfer goes to the PayoutEscrow (`REQ-SWAP-076`, `REQ-ESCROW-018`, `Q-389`); balance-delta flash path and the transfer-fee rules (`REQ-SWAP-108`, `-122`, `-123`, `REQ-FLASH-003`, `Q-390`) |
| Models changed | `fv_liq_04_budget.py`: `FV-LIQ-04o`, `-04p` (reserve split keeps `reservedSum ≤ balance` and other markets' reserves; a market can always draw its own reserve) and the mutant `-04pm` (shared balance only). `fv_liq_05_escrow_coverage.py`: `FV-LIQ-05aa` (a failed payout never reverts the settlement and is delivered or credited in full) and the mutant `-05am` (unguarded fee transfer). `st16_payout_split_gates.py`: MATH-ST-108 rewritten to the record-cap gas fit `G(16) = 5,150,000 ≤ 16,777,216` (the break-even and `minDebtUsd` checks removed), MATH-ST-109 reserve checks, MATH-ST-110 any-recorded-Hub check, MATH-ST-111 flash top-up loop, MATH-ST-112 measured conservation |
| Findings produced | None |
| Output | Console only |

## FV-LIQ-R9 — 2026-11-10 — re-run after the option C rewrite (caller-funded liquidation, one entry point)

| Field | Value |
|---|---|
| Command | `../../../spec/05-verification/.venv/bin/python -u <file>` for each of the seven model files, from this folder, one at a time (Quint not re-run) |
| Versions | Python 3.9.6 from `docs/spec/05-verification/.venv`, z3-solver 4.13.0 |
| Result | `fv_liq_01`: 60 obligations, 0 failed. `fv_liq_02`: 29, 0 failed. `fv_liq_03`: 36, 0 failed. `fv_liq_04`: 19, 0 failed. `fv_liq_05`: 30, 0 failed. `fv_liq_06`: 76, 0 failed. `fv_liq_07`: 18, 0 failed. Every file exit 0 |
| Spec state | `Q-404`: `liquidate` is the one entry point, open to every caller that is not frozen with both route modes; LPVaultSwap pulls `debtToCover`, measures `Kf` (`0 < Kf ≤ X`), passes `Kf` to `liquidationCall` and takes no flash loan; no premium or transfer-fee term in any liquidation formula (`SPEC-LIQ-002`, `-003`, `-007`…`-010`, `-019`, `SPEC-SET-001`: `g = max(0, D + A + B − Kf − R)`, never above the floor gap); `keeperOut` paid directly, never escrowed; flash liquidation helper `REQ-HELPER-001`…`-014`; the core flash source serves `deleverage` only |
| Models changed | `fv_liq_01`: slippage with no premium term (`-01b`, `-01d`), premium rate for deleverage and the helper (`-01e`), caller funding (`-01h`), the waterfall on `Kf ≥ D` (`-01j`, `-01l`, `-01m`, `-01n`, `-01t`, `-01p2`, `-01q`), F-03 closed by `Q-404` (`-01o`, mutant `-01om`), loss bound without a premium (`-01r`, `-01s`, `-01s2`, `-01sm`, `-01tm`). `fv_liq_03`: one entry point for any caller, `Kf` funding, the gap on `R_f`, `keeperOut` never escrowed, mutant `-03z2` (no `D ≤ Kf` bound). `fv_liq_04`: rewritten on caller funding. `fv_liq_05`: kind 1 (`keeperOut`) is no longer an escrow deposit. `fv_liq_06`: every 2.11, 2.13, 2.17 and 3.5 figure recomputed (`-06ae`: deleverage assetOut 19,237,964 at the ceiling quote; `-06ae2` records the half-up charge of 1,037,962, which pays the wallet 19,237,965). `fv_liq_07`: `-07g` wording |
| Findings produced | None new in the liquidation design; `fv_liq_06` replays two spec figures that did not reproduce: REQ-LENS-029 `recoveryFloor` (5,037.901998, corrected in 2.17) and the SPEC-LIQ-020 assetOut under the Pool's half-up premium (one unit more than the stated quote-based figure) |
| Output | Console only |

## FV-LIQ-R10 — 2026-11-11 — re-run after the 2026-11-11 decisions (charged premium, payout gas guard, one entry point in Quint)

| Field | Value |
|---|---|
| Command | `QNT_SAMPLES=2000 bash run.sh`, from this folder (the seven model files one after another, then the 9 Quint checks of `liquidation.qnt` one after another) |
| Versions | Python 3.9.6 from `docs/spec/05-verification/.venv`, z3-solver 4.13.0, Quint from `docs/spec/05-verification/node_modules` |
| Result | 277 `[PASS]`, 0 failed: `fv_liq_01` 60, `fv_liq_02` 29, `fv_liq_03` 36, `fv_liq_04` 19, `fv_liq_05` 30, `fv_liq_06` 76, `fv_liq_07` 18 obligations, and `FV-LIQ-08a`…`08w6` as expected at 2,000 traces × 25 steps; `LIQUIDATION AREA: all checks passed`, exit 0 |
| Spec state | 2.11 `SPEC-LIQ-020` example at the premium the Pool charges (`φ = 1,037,962`, `assetOut = 19,237,965`); 2.11 `REQ-SWAP-076` with LPVaultSwap's `POST_CALL_GAS = 10,000` (`required = 111,588`); the public flash liquidation helper in the protected set of 2.8 `REQ-MREG-020` |
| Models changed | `fv_liq_06`: `-06ae` checks the charged premium 1,037,962 and `assetOut = 19,237,965` beside the ceiling quote 1,037,963; `-06ae2` becomes the mutant of the earlier text (the quote gives 19,237,964, one unit below the wallet's receipt); `-06ah` checks `101,588 + 10,000 = 111,588`. `liquidation.qnt`: `liquidate(id, caller)` drops the permissionless flag, so any caller that is not frozen liquidates, a committed operator or not (`Q-404`) |
| Findings produced | None. The `-06ae2` finding of `FV-LIQ-R9` is closed by the restated `SPEC-LIQ-020` example |
| Output | Console only |

## FV-LIQ-R11 — 2026-11-11 — full re-run at the default Quint size

| Field | Value |
|---|---|
| Command | `bash run.sh`, from this folder (Quint at the default 10,000 traces × 25 steps) |
| Versions | Python 3.9.6 from `docs/spec/05-verification/.venv`, z3-solver 4.13.0, Quint 0.22.4 from `docs/spec/05-verification/node_modules` |
| Result | 277 `[PASS]`, 0 failed: `fv_liq_01` 60, `fv_liq_02` 29, `fv_liq_03` 36, `fv_liq_04` 19, `fv_liq_05` 30, `fv_liq_06` 76, `fv_liq_07` 18 obligations, and the 9 Quint checks `FV-LIQ-08a`…`08w6` as expected at 10,000 traces × 25 steps; `LIQUIDATION AREA: all checks passed`, exit 0 |
| Spec state | Decisions through `Q-406` |
| Models changed | None; full re-run alongside the control-area model updates of `FV-CTL-R11` |
| Findings produced | None |
| Output | Console only |
