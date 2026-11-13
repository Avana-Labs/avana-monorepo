# SymPy algebra checks (`SYM-…`)

Each script checks that a formula of the specification equals the rule it implements, exactly and before rounding, derives the closed forms the specification states, and recomputes the worked examples on the spec pages in exact rational arithmetic. Rounding direction, integer widths and Solidity overflow are proved separately by the Z3 models in [`../z3/`](../z3/) (`MATH-…`); each SymPy group names the Z3 models that carry its rounded form.

Sources: the specification pages in [`spec/01-architecture`](../../01-architecture/) to [`spec/04-security`](../../04-security/), the decisions in [4.4](../../04-security/04-design-decisions.md), Aave V4 at `a3ef63e` (`LiquidationLogic.sol`, `Spoke.sol`, `UserPositionUtils.sol`, `Premium.sol`, `Hub.sol`) and Uniswap v3 (`SqrtPriceMath`, `TickMath`).

## Run

```bash
../.venv/bin/python sym05_settlement.py     # one script, from this folder
../run_all.sh                               # every spec-stage check
```

Each check prints `[CONSISTENT]` (the residual simplifies to 0, a non-negative certificate is proved, or a worked figure equals the exact value to its stated digits), `[INCONSISTENT]` (the residual and a numeric witness are printed) or `[DERIVED]` (a closed form, not a pass/fail check). Every check records its expected result; a script exits 1 only when a result differs from it. A deliberate wrong-reading check records `INCONSISTENT`; a figure or formula of the specification that does not hold keeps `CONSISTENT` as its expectation, so its script exits 1 until the specification changes.

Every check carries a `# SYM-NN verifies: <IDs>` tag directly above it, which [`../trace.py`](../trace.py) reads.

| Script | What it checks | Z3 models of the rounded form |
|---|---|---|
| `sym01_collateral_factor.py` | LP collateral factor and borrowing capacity, monotonicity, health factor, opening bound (`SPEC-CF-001`…`003`, `SPEC-HUB-001`, `SPEC-HUB-005`, `SPEC-PROXY-001`, `SPEC-PROXY-006`) | `z3/aave-risk/ar01`, `ar02` |
| `sym02_liquidation_sizing.py` | Aave V4 seizure, health factor after a partial liquidation, target sizing, bonus curve (`SPEC-HUB-005`, `SPEC-HUB-008`) | `z3/aave-risk/ar03`, `z3/settlement/st02` |
| `sym03_uniswap_fullrange.py` | Full-range amounts per unit liquidity, `SqrtPriceMath`, LP value identity and finite-tick bound (`SPEC-ORC-006`, `SPEC-ORC-007`, `SPEC-UNIT-002`, `SPEC-UNIT-003`, `SPEC-BACK-001`) | `z3/units-oracle/uo02`, `uo04` |
| `sym04_units_decimals_oracle.py` | Vault-token decimals, LPOracle 8-decimal price, Aave value, `sqrtPriceX96` from feeds, stable ceiling (`SPEC-UNIT-001`…`005`, `SPEC-ORC-004`…`010`) | `z3/units-oracle/uo01`, `uo03`, `uo05` |
| `sym05_settlement.py` | Recovery floor, effective slippage of one and two legs, waterfall in every case, the caller's rounding gap, the unwind value bound (`SPEC-LIQ-001`…`017`, `SPEC-SET-001`) | `z3/settlement/st01`…`st05` |
| `sym06_risk_premium.py` | User risk premium and borrow rate against Aave V4's code (`SPEC-HUB-004`, `SPEC-HUB-007`) | `z3/aave-risk/ar05` |
| `sym07_borrow_liquidation_walkthrough.py` | One position from borrow to liquidation: a $100,000 full-range position at a 35 % collateral factor, a price fall to HF 0.98, a 5 % bonus liquidation to a 1.05 target, the borrow rate with a 50 % premium (`SPEC-CF-001`, `SPEC-CF-003`, `SPEC-ORC-007`, `SPEC-HUB-005`, `SPEC-HUB-007`) | `z3/aave-risk/ar01`, `ar03` |
| `sym08_units_oracle_backing_examples.py` | Worked examples of vault tokens, Collateralization (partial removal, re-credit, rescue units, one-sided backing), LPOracle (backup routes, DebtOracle, standby, stale-at-Expired), LPVault, Lens, 3.1 Deposit, 3.4 Withdraw and 3.8 Market lifecycle | `z3/units-oracle/uo01`…`uo11` |
| `sym09_governance_timing_examples.py` | Timelock timing examples, delay floor and short-delay allowlist (`SPEC-GOV-001`…`015`) | `z3/governance/gv01`, `gv02` |
| `sym10_risk_examples.py` | Risk worked examples: repay with collateral, restore amount, rescue exclusion, cap sizing (incident and tail terms), addCap, repay quote, borrow rate, price-drop alert, opening bound, bonus curve, listing margin (`SPEC-PROXY-*`, `SPEC-CAP-*`, `SPEC-CF-*`, `SPEC-HUB-*`, `SPEC-BRK-001`) | `z3/aave-risk/ar01`…`ar10` |

Common assumptions: exact real arithmetic; GHO priced at $1 (Aave's fixed GHO source); one LPOracle price for the health factor, the seizure and the recovery floor within one transaction; full-range positions.

## Results

**247 checks: 246 hold, 1 counterexample (the deliberate `SYM-42a`); 16 derived closed forms.** (Run of 2026-11-12, every script.)

- `SYM-42a` is a deliberate wrong reading: a subtractive slippage bound `s = bonus` leaves the slippage term `r·b²` short of the debt. The specification uses the multiplicative bound of `SPEC-LIQ-003` and `SPEC-LIQ-016` (`SYM-41a`–`c`), which covers it exactly.
- `SYM-138d` was a finding (below), now resolved in the spec; it holds against the corrected 3.4 figures.

### Findings

**SYM-138d (low, resolved in spec): a figure in the 3.4 Withdraw worked example could not occur.** In the "Reconcile on exit" table, row "At `WDR-028`", removing 12,000,000,000 units returns `a0 = 11,998,500,000` together with `a1 = 12,001,500,000`. With exact `TickMath` and the burn formulas at tick spacing 1, every pool price that returns that `a1` returns `a0` = 11,998,500,186 or 11,998,500,187. Recommended change to [3.4](../../03-operations/04-withdraw.md): replace `a0 = 11,998,500,000` with `a0 = 11,998,500,187` and `11,998.5 USDC` with `11,998.500187 USDC` in that row, and in the following `settlePending` sentence replace `floor(11,998,500,000 × 6 / 12) = 5,999,250,000` with `floor(11,998,500,187 × 6 / 12) = 5,999,250,093` (`SYM-138e` then records 5,999,250,093). **Resolved in spec:** [3.4](../../03-operations/04-withdraw.md) now states `a0 = 11,998,500,187`, `11,998.500187 USDC` and `5,999,250,093`; SYM-138d and SYM-138e hold.

### Run log

| Date | Command | Versions | Scope | Result | Exit |
|---|---|---|---|---|---|
| 2026-11-10 | `.venv/bin/python sympy/<script>.py` for each of the 10 scripts, from `spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym01 14/14, sym02 19/19, sym03 11/11, sym04 10/10, sym05 17/18 (SYM-42a wrong reading), sym06 10/10, sym07 18/18, sym08 73/74 (SYM-138d), sym09 9/9, sym10 47/47 consistent | 0 for nine scripts; 1 for `sym08` (SYM-138d) |
| 2026-11-10 (after the spec fixes) | same | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym01 14/14, sym02 19/19, sym03 11/11, sym04 10/10, sym05 17/18 (SYM-42a wrong reading), sym06 10/10, sym07 18/18, sym08 74/74, sym09 9/9, sym10 47/47 consistent; SYM-138d resolved in spec, SYM-139e and SYM-156a–d check the `CF_t` tail term | 0 for every script |
| 2026-11-10 (AMM-neutral oracle) | `.venv/bin/python sympy/<script>.py` for `sym03`, `sym04`, `sym08`, from `spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym03 11/11, sym04 10/10, sym08 80/80 consistent; SYM-125, SYM-127, SYM-129 to SYM-133 and SYM-135 recompute the AMM-neutral examples of 2.10 (clamped composition, per-feed freshness, n-token band), SYM-166, SYM-167 and SYM-169 to SYM-172 added | 0 for every script |
| 2026-11-10 (settlement budget and in-kind removed, alert-only breakers, keeper floor 1) | `../.venv/bin/python <script>.py` for each of the 10 scripts, from `spec/05-verification/sympy` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym05 21/22 (SYM-42a wrong reading), every other script consistent; SYM-45…48, -144, -145, -148, -160 restated to the new rules | 0 |
| 2026-11-10 (option C, `Q-404`: caller-funded liquidation, no premium term) | `../.venv/bin/python sym05_settlement.py`, from `spec/05-verification/sympy` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym05 22/23 consistent (SYM-42a wrong reading); SYM-41, -42, -44…47, -49, -180 restated to caller funding `Kf` with no premium term; SYM-44c added (derived) | 0 |
| 2026-11-10 (LPPriceMath input bounds) | `.venv/bin/python sympy/sym08_units_oracle_backing_examples.py`, from `spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym08 82/82 consistent; SYM-172 recomputes the poke floor with `POST_CALL_GAS` (556,588), SYM-190 the fixed-point USD level and the band's token order, SYM-191 the disagreement price `min(lower, fresh, A)` from full-range compositions | 0 |
| 2026-11-11 (LPOracle price-read gas) | `.venv/bin/python sympy/sym08_units_oracle_backing_examples.py`, from `spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym08 82/82 consistent; SYM-172 restated to the per-read poke floor `max(W_poke, max_k(u_k + ⌈64 G_k / 63⌉ + POST_CALL_GAS))` with the measured two-token worst case (805,471) and `G_inputs(2) = 430,000` |
| 2026-11-11 (LPOracle token-decimals reads in the poke) | `.venv/bin/python sympy/sym08_units_oracle_backing_examples.py`, from `spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym08 consistent; SYM-172 restated with the measured two-token worst case including the token-decimals reads (861,000, binding read at 748,926) and the 900,000 floor | 0 |
| 2026-11-12 (public lending, `Q-407`) | `../.venv/bin/python sym10_risk_examples.py`, from `spec/05-verification/sympy` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym10 51/51 consistent; SYM-192a–d added: the supply rate lenders earn under the flat borrow rate of `SPEC-HUB-007` and its worked example | 0 |
| 2026-11-12 (kinked rate curve and early withdrawals, `Q-408`) | `../.venv/bin/python sym10_risk_examples.py`, from `spec/05-verification/sympy` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym10 63/63 consistent; SYM-159b–d and SYM-192b–d restated at the curve rate of the `SPEC-HUB-007` example (7.50 % at U = 0.5), SYM-192e–k added (kink continuity, the curve at four utilizations, supply rate at U = 0.95), SYM-193a–e added (an early withdrawal before realization moves its share of an uncovered deficit onto the remaining suppliers, `DEF-014`) | 0 |
| 2026-11-12 (loss order, `Q-410`) | `../.venv/bin/python sym10_risk_examples.py`, from `spec/05-verification/sympy` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym10 64/64 consistent; SYM-193a–e rewritten from the pro-rata loss after an early withdrawal to the two loss layers and the first-come residual, SYM-193f added | 0 |
| 2026-11-12 (served price: the accepted price only while Cached, `SPEC-ORC-017`) | `.venv/bin/python sympy/sym08_units_oracle_backing_examples.py`, from `spec/05-verification` | Python 3.9.6, SymPy 1.13.3 | exact symbolic and rational arithmetic, no bounds or seeds | sym08 82/82 consistent, 0 differ from this README; SYM-133 restated (disagreement serves `min(lower, fresh)`, Drifting serves fresh 199,999,600 above A = 199,980,000) and SYM-191 (served `min(lower, fresh)` = 194,928,113) | 0 |

## Properties

### `sym01_collateral_factor.py`

Run: `14 checks: 14 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-01 | V4 HF(D) = 1  <=>  D = V_LP x min(CF0,CF1) x R_pool (SPEC-CF-001) | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-02a | dB/dV = min(CF0,CF1) x R >= 0 | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-02b | dB/dR = V x min(CF0,CF1) >= 0 | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-02c[CF0<CF1] | on CF0<CF1: dB/d(min) = V x R >= 0 and dB/d(max) = 0 | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-02c[CF1<CF0] | on CF1<CF0: dB/d(min) = V x R >= 0 and dB/d(max) = 0 | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-02d[CF0<=CF1] | B(CF0 + e) - B(CF0) >= 0 on branch CF0<=CF1 | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-02d[CF1<=CF0] | B(CF0 + e) - B(CF0) >= 0 on branch CF1<=CF0 | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-03[CF0<=CF1] | V x (larger CF) x R - B >= 0 on branch CF0<=CF1 (and = 0 for the smaller leg) | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-03[CF1<=CF0] | V x (larger CF) x R - B >= 0 on branch CF1<=CF0 (and = 0 for the smaller leg) | `SPEC-CF-001`, `SPEC-HUB-001` | Holds |
| SYM-04a | HF(V_liq) = 1 with V_liq = D / CF | `SPEC-PROXY-006` | Holds |
| SYM-04b | collateral drop to HF 1 = 1 - 1/HF0 (HF0 = V x CF / D) | `SPEC-PROXY-006` | Holds |
| SYM-05a | max debt at opening HF h_o = B / h_o | `SPEC-CF-003`, `SPEC-PROXY-001` | Holds |
| SYM-05b | binding opening limit | `SPEC-CF-003`, `SPEC-PROXY-001` | Derived |
| SYM-06a | pool-risk-factor ceiling implied by maxLB x CF < 1 (SPEC-HUB-005 (a), SPEC-CF-002) | `SPEC-HUB-005`, `SPEC-CF-002` | Derived |
| SYM-06b | T - LB x CF = (T - 1) + (1 - LB x CF) > 0 for T >= 1, LB x CF < 1 | `SPEC-HUB-005`, `SPEC-CF-002` | Holds |
| SYM-07 | two markets: D at HF 1 equals B_1 + B_2 (capacity is additive across markets) | `SPEC-CF-001`, `SPEC-PROXY-006` | Holds |

### `sym02_liquidation_sizing.py`

Run: `19 checks: 19 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-10a | code: seized collateral (whole tokens) = repay x LB x P_d / P_c | `SPEC-HUB-008`, `SPEC-HUB-005` | Holds |
| SYM-10b | seized USD value = repaid USD value x LB  (= repay x (1 + bonus) at GHO $1) | `SPEC-HUB-008`, `SPEC-HUB-005` | Holds |
| SYM-10c | collateral-capped branch: repaid value = seized value / LB (same ratio in every branch) | `SPEC-HUB-008`, `SPEC-HUB-005` | Holds |
| SYM-11 | HF after partial liquidation = (H x D - r x LB x CF) / (D - r) | `SPEC-HUB-005` | Holds |
| SYM-12a | solve HF_after = T  ->  r* = D (T - H) / (T - LB x CF) | `SPEC-HUB-005` | Holds |
| SYM-12b | V4 _calculateDebtToTargetHealthFactor (USD) == r* | `SPEC-HUB-005` | Holds |
| SYM-12c | HF after repaying r* is exactly T | `SPEC-HUB-005` | Holds |
| SYM-13a | dHF_after/dr = (W - LB x CF x D) / (D - r)^2  -> raises HF iff HF > LB x CF | `SPEC-HUB-005` | Holds |
| SYM-13b | r* - D = D (LB x CF - H) / (T - LB x CF)  -> partial (r* < D) iff HF > LB x CF | `SPEC-HUB-005` | Holds |
| SYM-13c | closed form: partial-liquidation regime | `SPEC-HUB-005` | Derived |
| SYM-14a | dr*/dH = -D / (T - LB x CF) < 0 (healthier account repays less) | `SPEC-HUB-005` | Holds |
| SYM-14b | dr*/dT = D (H - LB x CF) / (T - LB x CF)^2 (> 0 in the partial regime) | `SPEC-HUB-005` | Holds |
| SYM-14c | dr*/dLB = D CF (T - H) / (T - LB x CF)^2 (> 0 for H < T) | `SPEC-HUB-005` | Holds |
| SYM-15a | curve is continuous at hf_max: LB(hf_max) = maxLB | `SPEC-HUB-005`, `Q-179` | Holds |
| SYM-15b | LB(HF -> 1) = minLB = 1 + (maxLB - 1) x factor | `SPEC-HUB-005`, `Q-179` | Holds |
| SYM-15c | slope dLB/dHF = -(maxLB - 1)(1 - factor)/(1 - hf_max) (<= 0: bonus falls as HF rises) | `SPEC-HUB-005`, `Q-179` | Holds |
| SYM-15d | bonus b(HF) = LB - 1 = (maxLB - 1) [factor + (1 - factor)(1 - HF)/(1 - hf_max)] | `SPEC-HUB-005`, `Q-179` | Holds |
| SYM-15e | minimum bonus over the liquidatable range (SPEC-HUB-005 (b): minLB - 1 >= minLiquidationBonus) | `SPEC-HUB-005`, `Q-179` | Derived |
| SYM-16a | collateralSharesToLiquidator = seized x (1 - fee x (LB-1)/LB) | `SPEC-HUB-008`, `SPEC-LIQ-001` | Holds |
| SYM-16b | with liquidationFee = 0 LPVaultSwap receives all seized shares | `SPEC-HUB-008`, `SPEC-LIQ-001` | Holds |
| SYM-17 | single market: (V - r* LB) CF / (D - r*) = T | `SPEC-HUB-005` | Holds |

### `sym03_uniswap_fullrange.py`

Run: `11 checks: 11 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-20a | getAmount0Delta(s, s_upper, L) == L (1/sqrtP - 1/sqrtP_upper) | `SPEC-ORC-006` | Holds |
| SYM-20b | getAmount1Delta(s_lower, s, L) == L (sqrtP - sqrtP_lower) | `SPEC-ORC-006` | Holds |
| SYM-21a | x -> L/sqrtP as P_upper -> oo | `SPEC-ORC-006` | Holds |
| SYM-21b | y -> L sqrtP as P_lower -> 0 | `SPEC-ORC-006` | Holds |
| SYM-22a | value at fair spot P = p0/p1: x p0 + y p1 == 2 L sqrt(p0 p1) | `SPEC-ORC-007`, `SPEC-UNIT-003` | Holds |
| SYM-22b | legs are equal at the fair price: x p0 == y p1 | `SPEC-ORC-007`, `SPEC-UNIT-003` | Holds |
| SYM-23 | x p0 + y p1 - 2 L sqrt(p0 p1) = L (sqrt(p0) P^-1/4 - sqrt(p1) P^1/4)^2 >= 0 at any spot P | `SPEC-ORC-007` | Holds |
| SYM-24a | ideal - finite value at fair spot = L (p0/sqrtP_u + p1 sqrtP_l) | `SPEC-ORC-006`, `SPEC-BACK-001`, `SPEC-UNIT-003` | Holds |
| SYM-24b | relative overvaluation by 2 sqrt(p0 p1): eps = (sqrt(P/P_u) + sqrt(P_l/P)) / 2 | `SPEC-ORC-006`, `SPEC-BACK-001`, `SPEC-UNIT-003` | Holds |
| SYM-24c | eps for launch pools at $1 (the ideal value exceeds the tick-bounded holdings by eps; negligible) | `SPEC-ORC-006`, `SPEC-BACK-001`, `SPEC-UNIT-003` | Derived |
| SYM-25 | full-range amounts per unit of liquidity at the fair price (whole tokens) | `SPEC-UNIT-002`, `SPEC-ORC-006` | Derived |
| SYM-25b | x_raw / 10^d0 == L 10^-(d0+d1)/2 sqrt(P1/P0) | `SPEC-UNIT-002`, `SPEC-ORC-006` | Holds |
| SYM-26 | argmin_P (x p0 + y p1) = p0 / p1 (the oracle ratio) | `SPEC-ORC-007` | Holds |

### `sym04_units_decimals_oracle.py`

Run: `10 checks: 10 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-30a | value of one whole vault token = 2 sqrt(P0 P1) 10^(d - (d0+d1)/2) | `SPEC-UNIT-001`, `SPEC-UNIT-003`, `SPEC-ORC-005` | Holds |
| SYM-30b | whole-token value == 2 sqrt(P0 P1) solves to d = (d0 + d1)/2 (unique) | `SPEC-UNIT-001`, `SPEC-UNIT-003`, `SPEC-ORC-005` | Holds |
| SYM-30c | at peg P0 = P1 = $1 a whole token is worth exactly $2 | `SPEC-UNIT-001`, `SPEC-UNIT-003`, `SPEC-ORC-005` | Holds |
| SYM-30d | integer requirement: d0 + d1 must be even (every launch pair is; an odd sum reverts OddDecimalSum) | `SPEC-UNIT-001`, `SPEC-UNIT-003`, `SPEC-ORC-005` | Derived |
| SYM-31 | Aave value(n units) = n x price8 / 10^d equals n x 2 sqrt(p0 p1) (raw) iff d = (d0+d1)/2 | `SPEC-UNIT-004`, `SPEC-UNIT-003`, `SPEC-ORC-008` | Holds |
| SYM-32a | price8 = 2 sqrt(a0 a1) 10^(8 - (f0+f1)/2) | `SPEC-ORC-008`, `SPEC-ORC-004` | Holds |
| SYM-32b | with 8-dec feeds (f0 = f1 = 8): price8 = 2 sqrt(a0 a1) | `SPEC-ORC-008`, `SPEC-ORC-004` | Holds |
| SYM-32c | market with a USD stable leg (SPEC-ORC-004) | `SPEC-ORC-008`, `SPEC-ORC-004` | Derived |
| SYM-33a | sqrtPriceX96 = 2^96 sqrt(a0 10^(f1+d1) / (a1 10^(f0+d0))) squares to P_raw | `SPEC-ORC-009`, `SPEC-ORC-007`, `SPEC-ORC-010` | Holds |
| SYM-33b | 8-dec feeds: sqrtPriceX96 = 2^96 sqrt(a0/a1 x 10^(d1-d0)) | `SPEC-ORC-009`, `SPEC-ORC-007`, `SPEC-ORC-010` | Holds |
| SYM-33c | amounts at the feed-implied sqrtPrice, valued at the feeds: x p0 + y p1 == 2 L sqrt(p0 p1) | `SPEC-ORC-009`, `SPEC-ORC-007`, `SPEC-ORC-010` | Holds |
| SYM-33d | swapping token order inverts the ratio: sqrtX96' = 2^192 / sqrtX96 (orientation, MATH-UO-13) | `SPEC-ORC-009`, `SPEC-ORC-007`, `SPEC-ORC-010` | Holds |
| SYM-33e | reference ticks at $1/$1 (tick = log_1.0001 P_raw) | `SPEC-ORC-009`, `SPEC-ORC-007`, `SPEC-ORC-010` | Derived |
| SYM-34 | unit summary at peg | `SPEC-UNIT-005`, `SPEC-UNIT-004` | Derived |

### `sym05_settlement.py`

Run: `18 checks: 17 CONSISTENT, 1 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-40 | minRec = V (1 - s) - U - allowance = r (1 + b)(1 - s) - U - allowance | `SPEC-LIQ-005`, `SPEC-LIQ-004`, `LIQ-060` | Holds |
| SYM-41a | term >= r (1 + f)  <=>  s <= s* = 1 - (1 + f) / (1 + b) (f = 0 in a liquidation; f > 0 the listing check's helper premium) | `SPEC-LIQ-016`, `SPEC-LIQ-003` | Holds |
| SYM-41b | term - r (1 + f) = r (1 + b)(s* - s): the sign is exactly s <= s* | `SPEC-LIQ-016`, `SPEC-LIQ-003` | Holds |
| SYM-41c | a liquidation has no premium term: at f = 0 the bound is b / (1 + b) (`Q-404`) | `SPEC-LIQ-016`, `SPEC-LIQ-003` | Holds |
| SYM-42a | wrong reading: subtractive bound s = b leaves term - r = -r b^2 < 0 | `SPEC-LIQ-003` | Counterexample |
| SYM-42b | shortfall at the subtractive bound = r b^2 | `SPEC-LIQ-003` | Holds |
| SYM-42c | subtractive minus multiplicative bound = b^2 / (1 + b) | `SPEC-LIQ-003` | Holds |
| SYM-43 | net bonus b = b_gross (1 - lf): Aave's liquidation fee comes out of the bonus before slippage | `SPEC-LIQ-001` | Holds |
| SYM-44a | ds*/db = (1 + f) / (1 + b)^2 > 0: the minimum bonus is the binding case | `SPEC-LIQ-016`, `REQ-PSTORE-021` | Holds |
| SYM-44b | the listing check minLB (1 - smin) >= 1 + maxFlash implies the liquidation bound minLB (1 - smin) >= 1; the slack is maxFlash | `SPEC-LIQ-016`, `REQ-PSTORE-021` | Derived |
| SYM-45 | a helper's premium on its whole loan is paid from keeperOut: its net payout falls by f (F - r) against a loan of r, while keeperOut has no F term | `SPEC-LIQ-007`, `SPEC-SET-001` | Holds |
| SYM-46a | R' = r + alpha gain + q (S covers the fee): keeperOut = Kf + q | `SPEC-LIQ-010`, `SPEC-LIQ-009`, `SPEC-LIQ-008`, `SPEC-SET-001`, `SPEC-LIQ-017` | Holds |
| SYM-46b | 0 < S < alpha gain: A = S and keeperOut = Kf | `SPEC-LIQ-010`, `SPEC-LIQ-009`, `SPEC-LIQ-008`, `SPEC-SET-001`, `SPEC-LIQ-017` | Holds |
| SYM-46c | R' = r - d below the debt: keeperOut = Kf - d, the caller's loss, never negative for Kf >= r | `SPEC-LIQ-010`, `SPEC-SET-001`, `SPEC-LIQ-019`, `SPEC-LIQ-017` | Holds |
| SYM-46d | the uncapped fee alpha (V - r) has no term in R': d/dR' = 0 | `SPEC-LIQ-010`, `SPEC-LIQ-009`, `SPEC-LIQ-008`, `SPEC-SET-001`, `SPEC-LIQ-017` | Holds |
| SYM-47 | worst loss at R = minRec: r - minRec = r (1 + b)(s - s*_0) + U + allowance (<= U + allowance for s <= b / (1 + b)), borne in keeperOut | `SPEC-SET-001`, `SPEC-LIQ-019`, `INV-038` | Holds |
| SYM-48a | at the oracle-implied pool price P = p0 / p1 the unwound tokens are worth exactly the oracle value | `SPEC-LIQ-011`, `SPEC-LIQ-005` | Holds |
| SYM-48b | val - V_oracle = L (sqrt(p0) P^-1/4 - sqrt(p1) P^1/4)^2 >= 0: removal at any pool price returns at least the oracle value | `SPEC-LIQ-011`, `SPEC-LIQ-018`, `REQ-SWAP-025` | Holds |
| SYM-48c | no in-kind settlement: every liquidation swaps the unwound tokens into the debt asset; a token with no usable route reverts `NoRouteAvailable` | `SPEC-LIQ-011`, `REQ-SWAP-025` | Derived |
| SYM-49 | the fee base V - r = r b is fixed by the bonus alone (no premium term) | `SPEC-LIQ-009`, `SPEC-LIQ-008` | Holds |
| SYM-180a–d | Debt-asset settlement: `A + kr + B = S` with `B = S − G`; `B = R' − V`; `keeperOut = K + kr − (φ − φD)`; no buy leg gives `s* = (b − f)/(1 + b)` | `SPEC-LIQ-022`, `SPEC-LIQ-010`, `SPEC-SET-001`, `SPEC-LIQ-003`, `SPEC-LIQ-016` | Holds |

### `sym06_risk_premium.py`

Run: `10 checks: 10 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-50 | one collateral market (any value, any debt): V4 URP = collateralRisk | `SPEC-HUB-004`, `SPEC-HUB-007` | Holds |
| SYM-51a | D <= c1: V4 URP = rho1 (only the cheapest collateral backs the debt) | `SPEC-HUB-004` | Holds |
| SYM-51b | SPEC-HUB-004 form: the V4 walk is sum w x risk / sum w with w_i = min(value_i, debt left) in risk order | `SPEC-HUB-004` | Holds |
| SYM-51c | c1 < D <= c1 + c2: V4 URP = (c1 rho1 + (D - c1) rho2) / D | `SPEC-HUB-004` | Holds |
| SYM-51d | D > c1 + c2 (under-collateralised): V4 URP = value-weighted average of all collateral | `SPEC-HUB-004` | Holds |
| SYM-52 | rho_max - URP >= 0 (regime c1 < D <= c1 + c2 shown; the others are rho1 or the average) | `SPEC-HUB-004`, `Q-141` | Holds |
| SYM-53a | interest accrued since refresh = drawn interest x (1 + URP) (exact) | `SPEC-HUB-007` | Holds |
| SYM-53b | at the refresh instant (I = I_0) the rate on total debt = base x (1 + URP) | `SPEC-HUB-007` | Holds |
| SYM-53c | after accrual: rate on total debt - base x (1 + URP) = -base (1+RP) RP (I - I_0) / (I (1+RP) - RP I_0) | `SPEC-HUB-007` | Holds |
| SYM-53d | SPEC-HUB-007: premium accrues at drawnRate x URP on drawn debt only: d(premium)/dt = URP x d(drawn debt)/dt | `SPEC-HUB-007` | Holds |
| SYM-53e | one-year illustration, 4.5% continuously compounded base, URP 50%, no refresh | `SPEC-HUB-007` | Derived |
| SYM-54 | riskPremiumThreshold margin (Q-141) — closed form, rounding bounded by hand | `SPEC-HUB-004`, `Q-141` | Derived |

### `sym07_borrow_liquidation_walkthrough.py`

Run: `18 checks: 18 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-60 | LP CF = min(CF0, CF1) x pool risk factor = 70% x 50% = 35% | `SPEC-CF-001` | Holds |
| SYM-61 | borrowing capacity = $100,000 x 35% = 35,000 GHO | `SPEC-CF-001` | Holds |
| SYM-62 | interface limit at opening HF 1.10 'about 31,800' = 35,000 / 1.10 | `SPEC-CF-003` | Holds |
| SYM-63 | 25,000 GHO borrowed -> HF = 35,000 / 25,000 = 1.40 | `SPEC-CF-001`, `SPEC-HUB-008` | Holds |
| SYM-64 | collateral at HF 1 with debt unchanged 'about $71,400' = 25,000 / 0.35 | `SPEC-CF-001` | Holds |
| SYM-65 | collateral fall to HF 1 'about 29%' = 1 - 1/1.4 = 2/7 | `SPEC-CF-001` | Holds |
| SYM-66a | full range: value ratio 1/1.4 needs ETH price ratio (1/1.4)^2 = 25/49 | `SPEC-ORC-007` | Holds |
| SYM-66b | ETH decline 'roughly 49%' = 1 - 25/49 = 24/49 | `SPEC-ORC-007` | Holds |
| SYM-67 | HF at $70,000 = 70,000 x 0.35 / 25,000 = 0.98 | `SPEC-CF-001`, `SPEC-HUB-008` | Holds |
| SYM-68a | repay r* = 25,000 (1.05 - 0.98)/(1.05 - 1.05 x 0.35) = 1750 / 0.6825 = 2,564.10 | `SPEC-HUB-005` | Holds |
| SYM-68b | repays 'about 2,564 GHO' | `SPEC-HUB-005` | Holds |
| SYM-69a | removes 'about $2,692' = r x 1.05 | `SPEC-HUB-005` | Holds |
| SYM-69b | 'less than 4% of the position': 4% - r x 1.05 / 70,000 = 4% - 3.846% > 0 | `SPEC-HUB-005` | Holds |
| SYM-70a | leaves 'about $67,300' of collateral | `SPEC-HUB-005` | Holds |
| SYM-70b | leaves '22,436 GHO' of debt | `SPEC-HUB-005` | Holds |
| SYM-70c | HF after = (70,000 - r x 1.05) x 0.35 / (25,000 - r) = 1.05 exactly | `SPEC-HUB-005` | Holds |
| SYM-70d | assumptions the liquidation example needs (Aave V4 @ a3ef63e) | `SPEC-HUB-005` | Derived |
| SYM-71 | factor giving a 5% bonus at HF 0.98 for maxLB 1.10, hf_max 0.90 is 0.375 | `SPEC-HUB-005` | Holds |
| SYM-71b | general solution | `SPEC-HUB-005` | Derived |
| SYM-72 | 4.5% base x (1 + 50%) = 6.75% (single collateral market, URP = collateralRisk, APR at refresh: SYM-50, SYM-53) | `SPEC-HUB-007` | Holds |

### `sym08_units_oracle_backing_examples.py`

Run: `74 checks: 73 CONSISTENT, 1 INCONSISTENT`, exit 1.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-100a | SPEC-UNIT-001: USDC/USDT d = 6, DAI/USDC d = 12, GHO/DAI d = 18, DAI/USDS d = 18 | `SPEC-UNIT-001`, `SPEC-ORC-005`, `REQ-VTOKEN-022` | Holds |
| SYM-100b | SPEC-UNIT-001: a 6- and 7-decimal pair has an odd sum and reverts OddDecimalSum | `SPEC-UNIT-001`, `SPEC-ORC-005`, `REQ-VTOKEN-022` | Holds |
| SYM-101 | SPEC-UNIT-002 / SPEC-BACK-002: 5,000,000,000 units = 5,000 whole tokens at d = 6, worth $10,000 at $2.00 | `SPEC-UNIT-002`, `SPEC-BACK-002` | Holds |
| SYM-102a | SPEC-UNIT-003: legs at $1.00 give $2.00; USDT $0.64 with USDC $1.00 gives 2*sqrt(0.64) = $1.60 | `SPEC-UNIT-003`, `SPEC-ORC-008` | Holds |
| SYM-102b | SPEC-UNIT-003: L = 1 at pool price 1, 6 decimals: removal returns (0, 0) raw units; credited value floor(1 * price8 / 10^6) = 199 | `SPEC-UNIT-003`, `SPEC-ORC-008` | Holds |
| SYM-103 | SPEC-UNIT-004: 5e9 units at price8 2e8: value 5e9*2e8/1e6 = 1e12 ($10,000); Aave value 5e9*2e8*1e12 = 1e30 | `SPEC-UNIT-004` | Holds |
| SYM-104a | SPEC-UNIT-005: addCap >= ceil(5,500,000 / 1.00) = 5,500,000 whole tokens = 5.5e12 base units < 2^120 | `SPEC-UNIT-005`, `MKT-014` | Holds |
| SYM-104b | MKT-014: marketUsdCap $2,000,000 + slice $200,000 at stressFloorUsd $1.00 gives addCap >= 2,200,000 | `SPEC-UNIT-005`, `MKT-014` | Holds |
| SYM-105a | SPEC-UNIT-006: $100 million of USDC/USDT full-range liquidity at $2 per whole token is 5e13 units | `SPEC-UNIT-006` | Holds |
| SYM-105b | SPEC-UNIT-006: maxLiquidityPerTick(1) ~ 1.92e32 (within one unit of the last stated digit) | `SPEC-UNIT-006` | Holds |
| SYM-105c | SPEC-UNIT-006: maxLiquidityPerTick(200) ~ 3.83e34 (exact 3.835e34, within one unit of the last stated digit) | `SPEC-UNIT-006` | Holds |
| SYM-106 | SPEC-BACK-001: trunc(-887272/60)*60 = -887220; spacings 1, 10, 60, 200 give +-887272, +-887270, +-887220, +-887200 | `SPEC-BACK-001` | Holds |
| SYM-107 | SPEC-BACK-003: NFT 42 charges ceil(5e9*2e8/1e6) = 1e12 at price8 2e8 and 5e11 at the floor when price8 = 9e7 | `SPEC-BACK-003` | Holds |
| SYM-108 | SPEC-BACK-004: top-up charge 3e11 with slice 2e11 adds $1,000 regular, $2,000 slice, $3,000 per token and depositor | `SPEC-BACK-004` | Holds |
| SYM-109a | SPEC-BACK-005: reconciling 1,575,000,000 of NFT 42 leaves 685e9 and releases 315e9 ($3,150) | `SPEC-BACK-005` | Holds |
| SYM-109b | SPEC-BACK-005: the top-up record leaving in full with slice 2e11: fromSlice = 2e11 and regular drops by 1e11 ($1,000) | `SPEC-BACK-005` | Holds |
| SYM-110 | SPEC-BACK-006: a third 4e9 NFT goes after NFT 7; a 6e9 debit empties NFT 42 and leaves NFT 7 at 3e9 | `SPEC-BACK-006` | Holds |
| SYM-111 | SPEC-BACK-007: seizure of 1,575,000,000 from 9e9 shares / 12e9 supply leaves 7,425,000,000 and 10,425,000,000 | `SPEC-BACK-007` | Holds |
| SYM-112a | SPEC-BACK-008: USDT at $0.64 (sqrtP = 1.25): removing 1,575,000,000 units returns a0 = 1,259,999,999, a1 = 1,968,749,999 | `SPEC-BACK-008` | Holds |
| SYM-112b | SPEC-BACK-008: the removed principal is worth $2,520 at USDC $1.00 and USDT $0.64 | `SPEC-BACK-008` | Holds |
| SYM-112c | SPEC-BACK-008: a 10 bps transfer fee (rounded down) leaves r1 = 1,966,781,250 received | `SPEC-BACK-008` | Holds |
| SYM-113 | SPEC-BACK-009: gap 0 after the reconciled withdrawal; orphan-burn case gapBefore = gapAfter = 1,575,000,000 | `SPEC-BACK-009` | Holds |
| SYM-114 | SPEC-BACK-010: donation 1e8 then reconciling 1,575,000,000 leaves credited 3,425,000,000 and live 3,525,000,000 | `SPEC-BACK-010` | Holds |
| SYM-115 | SPEC-BACK-011: withdrawing NFT 42 with 3,425,000,000 units gives S = 7,425,000,000 and shortfall 1,575,000,000 | `SPEC-BACK-011` | Holds |
| SYM-116a | SPEC-BACK-012: settling 1e9 of 1,575,000,000 pays 799,999,999 and 1,249,999,999, leaving 460,000,000 and 718,750,000 | `SPEC-BACK-012` | Holds |
| SYM-116b | SPEC-BACK-012: the check passes at supply 575,000,000 after the burn, and without a burn reverts SupplyDropMismatch(0, 575,000,000) | `SPEC-BACK-012` | Holds |
| SYM-117 | SPEC-BACK-013: c_b = 8e11, re-credit charge 3e11, C0' = 1.1e12, a 2.75e9 removal leaves 5.5e11; life total $13,000 | `SPEC-BACK-013` | Holds |
| SYM-118 | SPEC-BACK-014: slice-only top-up books 1e9; ceil(1.5e9 * 2e11 / 3e11) = 1e9; capped at 3e8 after a seizure; rescue pledge 5e8 | `SPEC-BACK-014`, `REQ-COLL-016` | Holds |
| SYM-119 | REQ-COLL-017: repay with collateral of 8e8 units of NFT 7 (4e9, $8,000) leaves 3.2e9 units and a $6,400 charge | `REQ-COLL-017`, `SPEC-BACK-005` | Holds |
| SYM-120 | worked example 'reconcile on exit': every row has totalCredited + pending.units = totalSupply (gap 0) | `SPEC-BACK-009`, `SPEC-BACK-011`, `SPEC-BACK-012` | Holds |
| SYM-121 | SPEC-ORC-001: 99,987,000 from 8-, 18- and 6-decimal feeds | `SPEC-ORC-001` | Holds |
| SYM-122 | SPEC-ORC-002: USDT/ETH x ETH/USD = floor(3.333e14 * 3e11 / 1e18) = 99,990,000; route time = 1,762,649,000 | `SPEC-ORC-002` | Holds |
| SYM-123 | SPEC-ORC-003: T = 225, p = 100,010,000: b = 99,900,000 agrees (1.1e9 <= 2.24775e10); b = 97,500,000 disagrees (2.51e10 > 2.19375e10) | `SPEC-ORC-003` | Holds |
| SYM-124 | SPEC-ORC-004: GHO at 100,300,000 is valued at 100,000,000; USDC at 99,987,000 passes unchanged | `SPEC-ORC-004` | Holds |
| SYM-125 | SPEC-ORC-006: USDC/USDT [-100, 100], d = 9, token1 at 0.952: clamped a = (0, 9,999,541), price8 = 951,956,208; unclamped a1 = 29,887,349 ($28.45) | `SPEC-ORC-006` | Holds |
| SYM-126 | SPEC-ORC-007: pool at P = 1.21 holds x = 0.9091, y = 1.1, worth $2.0091; excess 0.0091 | `SPEC-ORC-007` | Holds |
| SYM-127 | SPEC-ORC-008: USDC/USDT [-10, 10], d = 10: a = (5,648,563, 4,348,479), price8 = 564,782,768 + 434,847,800 = 999,630,568; DAI/USDC full range d = 12: 199,999,799 vs closed form 199,999,999 | `SPEC-ORC-008`, `SPEC-ORC-012` | Holds |
| SYM-167 | SPEC-ORC-005: smallest d with a whole token >= $1: DAI/USDC full range 12; USDC/USDT [-10, 10] 10 (d = 9 gives 99,963,04x < 1e8); USDC/USDT [-100, 100] depegged 9 | `SPEC-ORC-005` | Holds |
| SYM-128a | SPEC-ORC-009: DAI/USDC at $1: num = 1e14, den = 1e26, s = 79,228,162,514,264,337,593,543, no clamp | `SPEC-ORC-009` | Holds |
| SYM-128b | SPEC-ORC-010: tickRef = getTickAtSqrtRatio(s) = -276,325; delta -497,384,100 over 1,800 s truncates to -276,324 and rounds to -276,325 | `SPEC-ORC-010` | Holds |
| SYM-129 | SPEC-ORC-011: band 9e7 / 1.02e8 with fixed-point products: GHO/USDC 104,700,000 >= 81,000,000, capped 1e8 <= 104,040,000; 99,996,998 in band; 79,210,000 < 81,000,000; three tokens 99,970,002 >= 72,900,000 | `SPEC-ORC-011` | Holds |
| SYM-130 | SPEC-ORC-015: servedUpdatedAt 1,762,600,000; deadline 1,762,650,400; maxAge 50,400; on primaries: servedUpdatedAt 1,762,560,000, deadline 1,762,648,200, maxAge 88,200 | `SPEC-ORC-015`, `SPEC-ORC-012` | Holds |
| SYM-131 | SPEC-ORC-013: staleFrom 1,084,601 and 1,135,401; Cached until 1,139,000, Expired from 1,139,001; late-poke case Expired at 1,004,100 instead of Cached until 1,007,600 | `SPEC-ORC-013` | Holds |
| SYM-132 | SPEC-ORC-014: S_primary starts 1,084,601; alternate gap starts 1,134,201; B = [1,134,201, 1,190,000) lasts 55,799 >= 3,600; grace ends 1,191,800; fallback gap starts 1,081,001 | `SPEC-ORC-014` | Holds |
| SYM-133 | SPEC-ORC-016/017: pause ends 1,762,653,600; full-range USDC/USDT d = 6: lower composition (987,420, 1,012,739), lower = 197,483,855 = served min(lower, fresh 199,999,600) during the disagreement; Drifting serves fresh 199,999,600, above A = 199,980,000; Cached serves A | `SPEC-ORC-016`, `SPEC-ORC-017` | Holds |
| SYM-134a | SPEC-ORC-018: Expired USDC A = 99,990,000: delta 500 -> 104,989,500; delta 200 -> 101,989,800; A = 99,987,001 -> 104,986,352; disagreement -> 100,300,000 | `SPEC-ORC-018` | Holds |
| SYM-134b | SPEC-ORC-018: 10,000 USDC of debt counts as $10,498.95 when Expired | `SPEC-ORC-018` | Holds |
| SYM-135 | oracle rules: grace to 1,762,651,800 (not 1,762,648,200); price-drop alert 193,900,000*1e4 < 199,950,000*9,700; alternate leg age 21,601 at 1,762,661,601 against a lowered 21,600; limits 84,600 / 88,200 / 5,400 | `REQ-ORACLE-032`, `REQ-ORACLE-088`, `REQ-ORACLE-090`, `REQ-ORACLE-054` | Holds |
| SYM-166 | SPEC-ORC-019: USDT/USD round at 1,762,560,000 valid until 1,762,648,200 and Stale from 1,762,648,201; a 4,200 s limit would refuse it from 1,762,564,201 | `SPEC-ORC-019`, `REQ-ORACLE-054` | Holds |
| SYM-169 | SPEC-ORC-020: S = 100, q = 100,020,000: s = 99,400,000 confirmed (6.2e9 <= 9.94e9); s = 98,900,000 not (1.12e10 > 9.89e9) | `SPEC-ORC-020` | Holds |
| SYM-170 | SPEC-ORC-021: Base restart at 1,010,000 with grace 3,600: in grace until 1,013,599; borrowing from 1,013,600 on a round newer than the restart (a round of 1,009,000 or 1,010,000 keeps it closed, 1,013,000 opens it) | `SPEC-ORC-021`, `REQ-ORACLE-099` | Holds |
| SYM-171 | SPEC-ORC-022: W = 1,800: Ethereum 151, Base 901 observations; the Ethereum value on Base spans 300 s | `SPEC-ORC-022`, `REQ-ORACLE-055` | Holds |
| SYM-172 | SPEC-ORC-023: G = 50,000 needs 50,794 + 5,000 = 55,794; that gasleft forwards min(50,000, 54,923); G_inputs(2) = 150,000 + 2 · 140,000 = 430,000, bound 436,826 + 5,000; worst-case two-token poke with the token-decimals reads of REQ-ORACLE-107: binding read 748,926 + 50,794 + 5,000 = 804,720, W_poke 861,000, floor max = 861,000, 39,000 below POKE_MIN_GAS_FLOOR = 900,000 | `SPEC-ORC-023`, `REQ-ORACLE-038` | Holds |
| SYM-190 | SPEC-ORC-011: usdLevel 99,998,499 for (99,987,000, 100,010,000) (power 99,996,998, next 99,997,000); 89,000,000 for both at 0.89; 99,990,000 for the three-token pool; 90,000,001 = usdBandLow for (81,000,001, 1e8) in band, real root 90,000,000; order example 91,459,272 vs 91,459,273 against 91,459,273 | `SPEC-ORC-011`, `REQ-ORACLE-042` | Holds |
| SYM-191 | SPEC-ORC-017: full-range USDC/USDT d = 6: v = (97,544,839, 97,383,701) gives (999,173, 1,000,826) and fresh 194,928,113; w = (97,544,839, 97,383,663) <= v gives (999,173, 1,000,827) and lower 194,928,172; served min(lower, fresh) = 194,928,113 | `SPEC-ORC-017`, `REQ-ORACLE-086` | Holds |
| SYM-136 | REQ-VAULT-161: removing 1e9 units at pool price 1 returns about 1,000 USDC and 1,000 USDT (999999999, 999999999), both above the 995,000,000 minimums | `REQ-VAULT-161`, `SPEC-BACK-008` | Holds |
| SYM-137a | deposit: pledge value and charge 5e12 ($50,000); pool share 1.525e16 <= 4e16; capacity $15,600; dust 4e6 units = 8e8 < 1e9 | `DEP-012`, `DEP-018`, `SPEC-CAP-001`, `SPEC-CAP-005`, `DEP-004`, `SPEC-BACK-014`, `SPEC-CAP-003`, `DEP-025`, `SPEC-BACK-013` | Holds |
| SYM-137b | deposit: Avana holds 3.81% of the pool | `DEP-012`, `DEP-018`, `SPEC-CAP-001`, `SPEC-CAP-005`, `DEP-004`, `SPEC-BACK-014`, `SPEC-CAP-003`, `DEP-025`, `SPEC-BACK-013` | Holds |
| SYM-137c | deposit: restore amount ceil(900 / 0.312) = $2,884.61538462 (8 decimals); rescue ceil(276 / 0.312) = $884.61538462 | `DEP-012`, `DEP-018`, `SPEC-CAP-001`, `SPEC-CAP-005`, `DEP-004`, `SPEC-BACK-014`, `SPEC-CAP-003`, `DEP-025`, `SPEC-BACK-013` | Holds |
| SYM-137d | deposit: HF after the slice top-up 52,000 * 0.312 / 15,000 = 1.0816; after the rescue top-up 1.0982 | `DEP-012`, `DEP-018`, `SPEC-CAP-001`, `SPEC-CAP-005`, `DEP-004`, `SPEC-BACK-014`, `SPEC-CAP-003`, `DEP-025`, `SPEC-BACK-013` | Holds |
| SYM-137e | deposit: re-credit of 2.5e9 charges 5e11 ($5,000); record basis 27.5e9 units and $55,000 | `DEP-012`, `DEP-018`, `SPEC-CAP-001`, `SPEC-CAP-005`, `DEP-004`, `SPEC-BACK-014`, `SPEC-CAP-003`, `DEP-025`, `SPEC-BACK-013` | Holds |
| SYM-138a | withdraw path A: HF 1.56 before, 1.1143 after #9, 0.4457 if #7 left alone | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-138b | withdraw path C: refunds 7,123,287,671,232,876,712 GHO wei and 5,342,465 USDC base units | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-138c | withdraw partial record: ceil(50,000 * 20/25) = $40,000; reconcile: missing 12e9, #7 charge ceil(50,000*13/25) = $26,000 | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-138d | withdraw reconcile: removing 12e9 units with a1 = 12,001,500,000 returns a0 in [11998500186, 11998500187]; the stated a0 = 11,998,500,187 occurs | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-138e | withdraw reconcile: settling half pays floor(11,998,500,187 * 6/12) = 5,999,250,093 and 6,000,750,000 | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-138f | withdraw path E: mulDiv(4e6, 199,990,000, 1e6) = 799,960,000; mulDiv(5,001,000, ...) = 1,000,149,990; charge falls to $10.002 | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-138g | withdraw path E: collateral $179,991, CF-weighted $56,157.19, HF 5.6157; after the removal hfEx 2.4961 / 2.4962 | `WDR-008`, `WDR-018`, `WDR-016`, `SPEC-BACK-005`, `WDR-028`, `SPEC-BACK-008`, `SPEC-BACK-012`, `WDR-035`, `WDR-038` | Holds |
| SYM-139a | lifecycle: borrowPriceMaxAge = feedHeartbeat + heartbeatMargin (1,800 s, `SPEC-ORC-019`, no cap): USDC/USD 82,800 -> 84,600, USDT/USD 86,400 -> 88,200; CF 3,120 bps; 10,500*3,120/1e4 = 3,276; slippage min(100, 196) = 100; pledge 5e6 -> 1e9, 4,999,999 -> 999,999,800; 149 bps passes, 150 fails; CF 2,730; per-market window 500/3 GHO and 100 GHO floor | `MKT-005`, `MKT-010`, `MKT-011`, `MKT-043`, `MKT-049`, `MKT-052`, `MKT-053`, `MKT-054`, `SPEC-ORC-019`, `MKT-013`, `MKT-014` | Holds |
| SYM-139b | lifecycle: opening LTV 3,120 bps / 1.10 = 28.4% | `MKT-005`, `MKT-010`, `MKT-011`, `MKT-043`, `MKT-049`, `MKT-052`, `MKT-053`, `MKT-054`, `MKT-013`, `MKT-014` | Holds |
| SYM-139c | lifecycle: loss factor 1.0005 - 0.95 * 0.30 / 0.3276 = 0.1305 | `MKT-005`, `MKT-010`, `MKT-011`, `MKT-043`, `MKT-049`, `MKT-052`, `MKT-053`, `MKT-054`, `MKT-013`, `MKT-014` | Holds |
| SYM-139d | lifecycle: the 400,000 GHO reserve supports about 3,064,000 GHO of debt (to the nearest thousand) | `MKT-005`, `MKT-010`, `MKT-011`, `MKT-043`, `MKT-049`, `MKT-052`, `MKT-053`, `MKT-054`, `MKT-013`, `MKT-014` | Holds |
| SYM-139e | lifecycle: tail term CF_t = 0.312 and token cap 400,000 / 0.312 = $1,282,051 | `MKT-005`, `MKT-010`, `MKT-011`, `MKT-043`, `MKT-049`, `MKT-052`, `MKT-053`, `MKT-054`, `MKT-013`, `MKT-014` | Holds |
| SYM-139f | lifecycle: one loosening from 1.10 / $2,000,000 / 100 bps reaches at most 1.07 / $3,000,000 / 125 bps | `MKT-005`, `MKT-010`, `MKT-011`, `MKT-043`, `MKT-049`, `MKT-052`, `MKT-053`, `MKT-054`, `MKT-013`, `MKT-014` | Holds |
| SYM-140a | lens: HF 0.9997; debt repaid 4,990 USDC; after: 69,368.3 tokens, 35,466.12 USDC, HF 1.10 | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140b | lens: maxGhoSpend 5,004.97; ceil(1,060*1.003) = 1,063.18; c = 2,544.9 tokens; V = 5,089.80; slippage min(100, 166); floor 5,037.9019980002; A = 19.96; payout 79.84 | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140c | lens: bNet 10,500 slippage min(100, 476); minGhoPerWholeToken = 1,236.499998999999999999 GHO | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140d | lens: tail_USDT $93,600, tail_USDC $78,000, ratioBps 10,683; 5 whole tokens at $10 / $2; page walks 50 IDs; pending 1,208.65 | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140e | lens: Ht = 1.1055034 and amount = 15,436.376661 GHO | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140f | lens: ceil(10,000 * 1.0000030441 * 1.001) = 10,010.030472 USDC; repaid ceil(10,000.0304414) = 10,000.030442; refund 10.000030 | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140g | lens: re-credit charge ceil(2.5e9 * 199,990,000 / 1e6) = 499,975,000,000; Bob x = 1,979.999998, to wallet 20.000002 | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |
| SYM-140h | lens: Bob HF 1.406 before and 27,557.6 / 18,020.000002 = 1.5293 after | `REQ-LENS-009`, `REQ-LENS-017`, `REQ-LENS-028`, `REQ-LENS-029`, `REQ-LENS-016`, `REQ-LENS-034`, `REQ-LENS-018`, `REQ-LENS-014`, `REQ-LENS-026`, `REQ-LENS-035`, `REQ-LENS-036`, `REQ-LENS-038`, `SPEC-BACK-013` | Holds |

### `sym09_governance_timing_examples.py`

Run: `9 checks: 9 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-141 | SPEC-GOV-001: [tightenMarketUsdCap, disableRoute] needs 43,200 s; adding loosenTopUpSliceUsd needs 432,000 s and delay 43,200 reverts | `SPEC-GOV-001` | Holds |
| SYM-142 | SPEC-GOV-002/013: ready at 1,780,432,000, executable through 1,781,641,599, expired at 1,781,641,600; clean-up at 1,781,000,000 is refused | `SPEC-GOV-002`, `SPEC-GOV-013` | Holds |
| SYM-143 | SPEC-GOV-003/012: cut to 345,600 executes at 1,780,432,000; next upgrade ready at 1,780,777,600, 9 days after; 345,599, 259,200, 432,001, 864,000, 300,000 rejected | `SPEC-GOV-003`, `SPEC-GOV-012` | Holds |
| SYM-144 | SPEC-GOV-007/010: disableRoute scheduled at 1,780,000,000 executes no earlier than 1,780,043,200 and no later than 1,781,252,799; expired at 1,781,252,800 | `SPEC-GOV-007`, `SPEC-GOV-010` | Holds |
| SYM-145 | SPEC-GOV-008: 3 keepers, keeperFloor 1, MAX_KEEPERS 32: freeze -> 2, remove -> 1; next freeze reverts (0 < 1); removing the last active one reverts; add -> 2; a 33rd keeper reverts | `SPEC-GOV-008` | Holds |
| SYM-146 | SPEC-GOV-009/011: twap 50 -> 30 ok, then 40 NotStricter, 8 LivenessBound; minOpeningHF 1.10 -> 1.07 ok, 1.06 too large; slippage 100 -> 125 ok, 126 too large | `SPEC-GOV-009`, `SPEC-GOV-011` | Holds |
| SYM-147 | SPEC-GOV-011: cap 4e6 -> 6e6 passes (6e10 <= 6e10); next loosening refused until 1,780,864,000; slice from 0 capped at 600,000e8 | `SPEC-GOV-011` | Holds |
| SYM-148 | SPEC-GOV-012: grace HF 0.88 rejected; grace 7,200 ok and 7,201 rejected; twap 9 rejected | `SPEC-GOV-012` | Holds |
| SYM-149 | SPEC-GOV-014/015: k = 3 needs 259,248; k_max 14,399 at 432,000 and 7,199 at 345,600; k = 1 spare 86,376; k = 7,200 needs 345,612; 7,200 transactions at the floor; 43,200 < 3-day reaction | `SPEC-GOV-014`, `SPEC-GOV-015` | Holds |

### `sym10_risk_examples.py`

Run: `51 checks: 51 CONSISTENT, 0 INCONSISTENT`, exit 0.

| ID | Statement | Verifies | Result |
|---|---|---|---|
| SYM-150 | lemma: (A - a)/(D - y) - A/D = (y A - a D) / (D (D - y)), so HF' >= HF  <=>  y A >= a D | `SPEC-PROXY-009`, `INV-089` | Holds |
| SYM-151a | critical HF where the sized repayment exactly keeps HF: CF V (1 + f) / (V (1 - s) - U) | `SPEC-PROXY-009` | Holds |
| SYM-151b | with U = 0 the critical HF is CF (1 + f) / (1 - s) | `SPEC-PROXY-009` | Holds |
| SYM-152a | example: y = (3,000 x 0.99 - 0.01) / 1.0009 = 2,967.32 GHO | `SPEC-PROXY-009`, `REP-POST-008` | Holds |
| SYM-152b | example: HF' = 11,064 / 7,032.68 = 1.5732 | `SPEC-PROXY-009`, `REP-POST-008` | Holds |
| SYM-152c | example: lemma bound 936 / 1.20 = 780 | `SPEC-PROXY-009`, `REP-POST-008` | Holds |
| SYM-152d | example: critical HF 0.312 x 1.0009 / 0.99 = 0.3154 | `SPEC-PROXY-009`, `REP-POST-008` | Holds |
| SYM-153a | collateral value that restores h_o: u = (h_o - hf) x D / CF (x = (h_o - hf) D, usdToRestore = x / CF) | `SPEC-CAP-003`, `REQ-RISK-066` | Holds |
| SYM-153b | example: usdToRestore = 0.08 x 10,000 / 0.30 = $2,666.67 | `SPEC-CAP-003`, `REQ-RISK-066` | Holds |
| SYM-153c | example: restoreBooked at $0.80 with a $1.00 floor = $3,333.33 | `SPEC-CAP-003`, `REQ-RISK-066` | Holds |
| SYM-154a | hfEx = (A - E)/D = hf - E/D | `SPEC-CF-005`, `INV-082` | Holds |
| SYM-154b | largest debt with hfEx >= k: D* = (A - E)/k | `SPEC-CF-005`, `INV-082` | Holds |
| SYM-154c | example: hfEx = (12,000 - 312)/10,000 = 1.1688 | `SPEC-CF-005`, `INV-082` | Holds |
| SYM-154d | example: largest debt 11,688 / 1.10 = $10,625.45 | `SPEC-CF-005`, `INV-082` | Holds |
| SYM-154e | example: Aave hf at that debt 12,000 / 10,625.45 = 1.1294 | `SPEC-CF-005`, `INV-082` | Holds |
| SYM-154f | example: borrowing to hf 1.10 gives hfEx = 11,688 / 10,909.09 = 1.0714 | `SPEC-CF-005`, `INV-082` | Holds |
| SYM-155a | loss starts at dLP* = 1 - (1 + g)(1 + delta) CF LB / h0 | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-155b | d lambda / d dLP = h0 / (CF LB) > 0 (the loss grows linearly with the LP drop past dLP*) | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-155c | SPEC-CAP-007 Why: no loss up to a 65.5% LP drop | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-155d | example: lambda GHO = 0.096238 | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-155e | example: lambda USDC (delta 0.05) = 0.146288 | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-155f | example: 600,000 x lambda GHO = $57,743 (rounded up) | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-155g | example: 300,000 x lambda USDC = $43,887 (rounded up) | `SPEC-CAP-007`, `Q-192` | Holds |
| SYM-156a | largest token cap plus slices a reserve R covers: T + Z = R / CF | `SPEC-CAP-007`, `SPEC-CAP-008` | Holds |
| SYM-156b | launch: 400,000 GHO covers $1,282,051 of token cap plus slices (down) | `SPEC-CAP-007`, `SPEC-CAP-008` | Holds |
| SYM-156c | SPEC-CAP-008: tail of $1,800,000 at CF 0.312 = $561,600 | `SPEC-CAP-007`, `SPEC-CAP-008` | Holds |
| SYM-156d | SPEC-CAP-008: 400,000 / 561,600 = 71.22% (7,122 bps, down) | `SPEC-CAP-007`, `SPEC-CAP-008` | Holds |
| SYM-157a | units booked at >= floor F within K + Z: n F = K + Z gives n = (K + Z)/F | `SPEC-HUB-002`, `SPEC-CAP-006` | Holds |
| SYM-157b | example: 5,500,000 / 1.00 = 5,500,000 whole tokens | `SPEC-HUB-002`, `SPEC-CAP-006` | Holds |
| SYM-157c | example: 5,500,000 / 1.30 = 4,230,769.23 (addCap 4,230,770) | `SPEC-HUB-002`, `SPEC-CAP-006` | Holds |
| SYM-157d | example: 1,100,000 / 1.00 = 1,100,000 | `SPEC-HUB-002`, `SPEC-CAP-006` | Holds |
| SYM-158a | USDC 5,000 at 6.00% for 30 days = 5,024.657535 (rounded up to base units) | `SPEC-PROXY-003`, `SPEC-PROXY-007` | Holds |
| SYM-158b | GHO 8,000 at 5.00% for 30 days = 8,032.876712328767123288 (rounded up) | `SPEC-PROXY-003`, `SPEC-PROXY-007` | Holds |
| SYM-158c | quoteRepayAll = 5,024,657,535 x (1 + 0.06 x 600 / 31,536,000) x 1.001 -> 5,029,687,935 | `SPEC-PROXY-003`, `SPEC-PROXY-007` | Holds |
| SYM-159a | drawn interest b plus premium b x rp = b (1 + rp) | `SPEC-HUB-007` | Holds |
| SYM-159b | example: 100,000 x 7.50% (curve rate at U = 0.5) = 7,500 GHO drawn interest (before compounding) | `SPEC-HUB-007` | Holds |
| SYM-159c | example: premium 7,500 x 0.15 = 1,125 GHO | `SPEC-HUB-007` | Holds |
| SYM-159d | example: effective 7.50% x 1.15 = 8.625% | `SPEC-HUB-007` | Holds |
| SYM-160a | cp (1e4 - b) - 1e4 p = 1e4 cp x ((cp - p)/cp - b/1e4): the alert fires iff the drop exceeds b bps | `SPEC-BRK-001` | Holds |
| SYM-160b | example: $2.0000 to $1.9399 is a 3.005% drop, above the 3% alert threshold | `SPEC-BRK-001` | Holds |
| SYM-161 | SPEC-CF-003 example: 24,600 / 1.10 = $22,363.63 (cents, down) | `SPEC-CF-003` | Holds |
| SYM-162a | SPEC-HUB-005 example: minLB = 1 + 0.05 x 0.40 = 1.0200 | `SPEC-HUB-005` | Holds |
| SYM-162b | SPEC-HUB-005 example: bonus at hf 0.97 = 1.0290 | `SPEC-HUB-005` | Holds |
| SYM-163 | reported HF 1 and true price (1 - e) x reported: true collateral / debt = (1 - e)/CF, which is > 1 iff e < 1 - CF | `SPEC-CF-004`, `SPEC-HUB-006` | Holds |
| SYM-164a | 24,600 / 12,999.5 = 1.892380476172160467 (18 decimals, down) | `SPEC-PROXY-006`, `SPEC-PROXY-001` | Holds |
| SYM-164b | 24,600 / 22,998.5 = 1.069634976194099615 (18 decimals, down) | `SPEC-PROXY-006`, `SPEC-PROXY-001` | Holds |
| SYM-165 | SPEC-CF-001 example: (24,600 - 8,000) / 0.9999 = 16,601.66 USDC exhausts B | `SPEC-CF-001` | Holds |
| SYM-192a | supply rate = D r (1 + rp)(1 - f) / S = r (1 + rp) U (1 - f) with U = D / S | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192b | example: 900,000 x 7.50% x 1.15 = 77,625 GHO of borrow interest a year | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192c | example: U = 900,000 / 1,800,000 = 0.5; supply rate 0.075 x 1.15 x 0.5 x 0.9 = 3.88125% | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192d | example: the public lender's 500,000 GHO earns 19,406.25 GHO a year | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192e | the kinked curve is continuous at the kink: both branches equal base + before at U = U* | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192f | curve example: 5.50% + 3.60% x 0.5 / 0.9 = 7.50% at U = 0.5 | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192g | curve example: 9.10% + 50% x 0.05 / 0.10 = 34.10% at U = 0.95 | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192h | at U = 0.95: supply rate 0.341 x 1.15 x 0.95 x 0.9 = 33.528825% | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192i | curve example: 9.10% at the kink U = 0.9 | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192j | curve example: maximum 5.50% + 3.60% + 50% = 59.10% at U = 1 | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-192k | example: suppliers receive 77,625 x 0.9 = 69,862.5 GHO a year | `SPEC-HUB-007`, `REQ-HUB-008`, `REQ-HUB-009` | Holds |
| SYM-193a | the layers pay F_A + F_D and the rest D - F_A - F_D stays recorded | `REQ-FLR-027`, `DEF-014`, `SPEC-FLR-006`, `Q-410` | Holds |
| SYM-193b | after full repayment liquidity falls short of the lenders' claims by exactly the residual | `REQ-FLR-027`, `DEF-014`, `Q-410` | Holds |
| SYM-193c | an exit of x <= liquidity is paid x (price A / Sh unchanged); the claims left exceed the liquidity left by r | `REQ-FLR-027`, `DEF-014`, `Q-410` | Holds |
| SYM-193d | DEF-014 / TEST-299 example: 300,000 GHO against layers of 100,000 and 150,000 leaves 50,000 | `DEF-014`, `SPEC-FLR-006`, `Q-410` | Holds |
| SYM-193e | DEF-014 example: backed value per share (C - r) / Sh = 0.975 GHO, beside the 1 GHO Aave pays | `DEF-014`, `Q-410` | Holds |
| SYM-193f | DEF-014 / TEST-299 example: liquidity after full repayment is 1,950,000 GHO against 2,000,000 of claims | `DEF-014`, `Q-410` | Holds |

