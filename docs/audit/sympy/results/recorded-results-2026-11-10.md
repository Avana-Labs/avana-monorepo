# SymPy recorded results

Copied from docs/spec/05-verification/sympy/README.md (Results, Findings and Run log) as of 2026-11-10.

## Results

**230 checks: 229 hold, 1 counterexample; 16 derived closed forms.**

- `SYM-42a` is a deliberate wrong reading: a subtractive slippage bound `s = bonus − costs` leaves the slippage term `r·b·(b − f)` short of the debt. The specification uses the multiplicative bound of `SPEC-LIQ-003` and `SPEC-LIQ-016` (`SYM-41a`–`c`), which covers it exactly.
- `SYM-138d` was a finding (below), now resolved in the spec; it holds against the corrected 3.4 figures.

### Findings

**SYM-138d (low, resolved in spec): a figure in the 3.4 Withdraw worked example could not occur.** In the "Reconcile on exit" table, row "At `WDR-028`", removing 12,000,000,000 units returns `a0 = 11,998,500,000` together with `a1 = 12,001,500,000`. With exact `TickMath` and the burn formulas at tick spacing 1, every pool price that returns that `a1` returns `a0` = 11,998,500,186 or 11,998,500,187. Recommended change to [3.4](../../03-operations/04-withdraw.md): replace `a0 = 11,998,500,000` with `a0 = 11,998,500,187` and `11,998.5 USDC` with `11,998.500187 USDC` in that row, and in the following `settlePending` sentence replace `floor(11,998,500,000 × 6 / 12) = 5,999,250,000` with `floor(11,998,500,187 × 6 / 12) = 5,999,250,093` (`SYM-138e` then records 5,999,250,093). **Resolved in spec:** [3.4](../../03-operations/04-withdraw.md) now states `a0 = 11,998,500,187`, `11,998.500187 USDC` and `5,999,250,093`; SYM-138d and SYM-138e hold.

### Run log

| Date | Command | Versions | Scope | Result | Exit |
|---|---|---|---|---|---|
| 2026-11-10 | `.venv/bin/python sympy/<script>.py` for each of the 10 scripts, from `docs/spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym01 14/14, sym02 19/19, sym03 11/11, sym04 10/10, sym05 17/18 (SYM-42a wrong reading), sym06 10/10, sym07 18/18, sym08 73/74 (SYM-138d), sym09 9/9, sym10 47/47 consistent | 0 for nine scripts; 1 for `sym08` (SYM-138d) |
| 2026-11-10 (after the spec fixes) | same | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym01 14/14, sym02 19/19, sym03 11/11, sym04 10/10, sym05 17/18 (SYM-42a wrong reading), sym06 10/10, sym07 18/18, sym08 74/74, sym09 9/9, sym10 47/47 consistent; SYM-138d resolved in spec, SYM-139e and SYM-156a–d check the `CF_t` tail term | 0 for every script |
| 2026-11-10 (AMM-neutral oracle) | `.venv/bin/python sympy/<script>.py` for `sym03`, `sym04`, `sym08`, from `docs/spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym03 11/11, sym04 10/10, sym08 80/80 consistent; SYM-125, SYM-127, SYM-129 to SYM-133 and SYM-135 recompute the AMM-neutral examples of 2.10 (clamped composition, per-feed freshness, n-token band), SYM-166, SYM-167 and SYM-169 to SYM-172 added | 0 for every script |
| 2026-11-10 (settlement budget and in-kind removed, alert-only breakers, keeper floor 1) | `../.venv/bin/python <script>.py` for each of the 10 scripts, from `docs/spec/05-verification/sympy` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym05 21/22 (SYM-42a wrong reading), every other script consistent; SYM-45…48, -144, -145, -148, -160 restated to the new rules | 0 |
| 2026-11-10 (LPPriceMath input bounds) | `.venv/bin/python sympy/sym08_units_oracle_backing_examples.py`, from `docs/spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym08 82/82 consistent; SYM-172 recomputes the poke floor with `POST_CALL_GAS` (556,588), SYM-190 the fixed-point USD level and the band's token order, SYM-191 the disagreement price `min(lower, fresh, A)` from full-range compositions | 0 |

