# aave-risk — Z3 models of Avana's risk arithmetic on Aave V4

These models check the risk formulas of the Avana Hub and Spokes ([2.1](../../../02-contracts/01-avana-hub-and-spokes.md)), the PositionProxy and AaveAdapter ([2.5](../../../02-contracts/05-position-proxy-and-proxy-manager.md), [2.6](../../../02-contracts/06-aave-adapter.md)), the RiskModule ([2.7](../../../02-contracts/07-risk-module.md)) and the MarketRegistry breakers ([2.8](../../../02-contracts/08-market-registry.md)) against the pinned Aave V4 code (`aave/aave-v4@a3ef63ea6415d25237a9775bf66e76e9993561c2`: `Spoke._processUserAccountData`, `Spoke._validateDynamicReserveConfig`, `LiquidationLogic.sol`, `UserPositionUtils.sol`, `Hub._applyPremiumDelta`, `AssetLogic.sol`, `SharesMath.sol`, `WadRayMath.sol`, `PercentageMath.sol`, `MathUtils.sol`). Every worked example on those pages, on the borrow, repay and emergency flows ([3.2](../../../03-operations/02-borrow.md), [3.3](../../../03-operations/03-repay.md), [3.6](../../../03-operations/06-emergency-operations.md)) and in the risk parameters ([1.5](../../../01-architecture/05-parameters.md), [2.9](../../../02-contracts/09-parameter-store.md)) is recomputed in exact integers.

Run: `../../run_all.sh`, or `../../.venv/bin/python <file>.py` from this folder. Each script prints one line per property: `PROVED` / `COUNTEREXAMPLE` / `TIMEOUT` for a solver query, `COMPUTED` for a table or a worked example whose stated figures all equal the exact evaluation, `MISMATCH` when a stated figure differs. A script exits 1 only when a result differs from the one recorded in it; every script exits 0 against the current spec.

**Units.** WAD = 1e18, RAY = 1e27, BPS = 1e4. Oracle prices have 8 decimals. Aave Value = `amount × price × 10^(18 − decimals)` (1e26 = $1, exact). Debt is `drawnShares × drawnIndex + premiumRay` (asset units × RAY). GHO has 18 decimals and a fixed $1 source; USDC 6 decimals; vault tokens 6–18 decimals. Cap amounts are 8-decimal USD. Integer division is modelled exactly: `q = floor(n/d)` as `q·d ≤ n < q·d + d`, `ceil` likewise. Real-valued models are used only for economic statements (cap sizing, repay with collateral, listing margin), and each on-chain rounding feeding them is proved one-sided in an integer property.

## Formulas modelled

| Spec ID | Formula (final text) | Rounding | Script |
|---|---|---|---|
| `SPEC-HUB-001`, `SPEC-CF-001` | `CF_LP = ⌊min(CF0, CF1) × poolRiskFactor / 10^4⌋`; `B = Σ_m V_m × CF_m / 10^4`, `V_m = s_m × p_m × 10^(18 − d_m)` | down | ar01 |
| `SPEC-HUB-005`, `SPEC-CF-002` | (a) `⌈maxLB × CF / 10^4⌉ < 10^4`; (b) `minLB = 10^4 + ⌊(maxLB − 10^4) × LBF / 10^4⌋`, V4 bonus curve; (c) `THF − percentMulUp(LB × 1e14, CF) > 0` | up / down | ar01, ar03 |
| `SPEC-HUB-008`, `SPEC-PROXY-006` | `hf = ⌊Σ CF_m V_m × 1e14 × RAY / Σ_r DV_r × RAY⌋`, `DV_r = q_r × P_r × 10^(18 − e_r)`; borrow shares `⌈a × RAY / idx⌉`; repay restores `⌊x × RAY / idx⌋`; `getUserTotalDebt = ⌈s × idx / RAY⌉ + ⌈prem / RAY⌉` | against the account | ar01, ar04, ar06 |
| `SPEC-PROXY-001`, `SPEC-CF-005` | pass ⇔ `hfEx ≥ max(1.00, hardHealthFloor, minHealthFactor)` (`Q-398`: no on-chain opening floor; the per-market hard floor is optional and 0 by default; the Lens recommends HF 1.10), `hfEx = max(0, hf − ⌈E × WAD × RAY / totalDebtValueRay⌉)`, `E = Σ_m ⌈u_m p_m CF_m 1e18 / (10^{d_m} 10^4)⌉` | E up, hfEx down | ar02 |
| `SPEC-CF-003` | `Σ_r DV_r ≤ B / max(1.00, hardHealthFloor, minHealthFactor)`; Lens recommended `⌊B / 1.10⌋` beside the maximum `B` (`Q-398`); faulty RiskModule: `≤ B` | inclusive on floored hf | ar01, ar02 |
| `SPEC-PROXY-002` | pass ⇔ `t_i ≤ now ∧ now − t_i ≤ borrowPriceMaxAge`, `borrowPriceMaxAge = min(heartbeat + 600, 4,200)` | none | ar10 |
| `SPEC-PROXY-003`, `SPEC-PROXY-007` | partial `x = min(M, D)`; repay-all `D_e ≤ M`, pulled `M`, `spent = min(received, D_e)`, refund `received − spent`; `quoteRepayAll = ⌈D_s (1 + ρ (t_d − t_s)/31,536,000) × 1.001⌉` | Aave up against the payer; quote up | ar04 |
| `SPEC-PROXY-004` | `drawn = balance_after − balance_before = amount`, forwarded `drawn` | none | ar10 |
| `SPEC-PROXY-005` | supply and withdraw move exactly `units`; Hub shares == assets | exact while A == S | ar06 |
| `SPEC-PROXY-008` | `G = totalCredited + pending − totalSupply`; pass ⇔ `T' ≤ C' + P' ∧ G' = G` | none | ar10 |
| `SPEC-PROXY-009` | `HF' = (A − a)/(D − y) ≥ max(HF, minHealthFactor)`; `HF' ≥ HF ⇔ yA ≥ aD`; `y ≤ (V(1 − s) − U)/(1 + f)` | floored HF compared | ar10 |
| `SPEC-HUB-002`, `SPEC-CAP-006` | `addCap ≥ ⌈(max(marketUsdCap, regularUsed) + max(topUpSliceUsd, sliceUsed)) / stressFloorUsd⌉` | up | ar08 |
| `SPEC-HUB-003` | `drawCap × 10^dec ≥ drawn + premium + ⌈deficitRay/RAY⌉ + amount`; `Σ_s drawCap_s ≤ creditLine` | Hub debt up | ar08 |
| `SPEC-HUB-004` | `threshold ≥ max collateralRisk + 1`; `Σ_i percentMulUp(d_i, r_i) ≤ percentMulUp(Σ d_i, T)` | premium shares up | ar05 |
| `SPEC-CAP-001` | `usdCharge = ⌈L × max(price8, floor) / 10^d⌉`; `pledgeUsd = ⌊L × price8 / 10^d⌋ ≥ minPledgeUsd` | charge up, value down | ar08 |
| `SPEC-CAP-002` | `room = max(K − R, 0)`; new pledge `c ≤ room`; top-up `slice = max(c − room, 0)`, `S + slice ≤ Z`; token and depositor tests on `c − slice` | none | ar08 |
| `SPEC-CAP-003` | `x = ⌈(h_o − hf) D / (WAD RAY)⌉`, `usdToRestore = ⌈x 10^4 / (CF 10^18)⌉`, `restoreBooked = ⌈usdToRestore × max(price8, floor) / served8⌉` | up | ar08 |
| `SPEC-CAP-004` | `charge(u) = ⌈C0 u / U0⌉`, `release = charge(u_b) − charge(u_a)`, slice first | up on the remaining charge | ar08 |
| `SPEC-CAP-005` | `(supply + L) × 10^4 ≤ poolShareMaxBps × liqHM` | floored liqHM | ar08 |
| `SPEC-CAP-007` | `λ = max(0, (1 + g)(1 + δ) − h0 (1 − dLP)/(CF × LB))`; `Σ debtCap × λ ≤ reserve`; `(K + Z) CF ≤ Σ debtCap × h_o`; tail `min((tokenUsdCap + Σ slices) CF_t, Σ drawCap) ≤ reserve` | conservative | ar07 |
| `SPEC-CAP-008` | `tail = min(⌈(tokenUsdCap + Σ slices) CF_t / 10^4⌉, drawCapUsd)`, `tailCoverageBps = ⌊funded × 10^4 / max tail⌋` | tail up, ratio down | ar08 |
| `SPEC-CF-004`, `SPEC-HUB-006` | `10^4 − CF > dev(r) + drift(r)` for every route | none | ar10 |
| `SPEC-BRK-001` | alert only (`Q-399`): ⇔ `now − at ≤ 7,200 ∧ price8 × 10^4 < cp × (10^4 − 300)`; no on-chain trip | none | ar09 |
| `SPEC-BRK-002` | tripped ⇔ `supply × 10^4 > poolShareMaxBps × liqHM` (one 10% value, `Q-399`) | floored liqHM | ar09 |
| `SPEC-BRK-003` | probe `None` never trips; revert, out-of-gas or malformed return trips; `paused()` true or `basisPointsRate() > 0` trips | none | ar09 |
| `SPEC-BRK-004` | `DEFICIT` ⇔ `deficitRay > breakerDeficitMax × RAY`, `breakerDeficitMax` 10,000 GHO (`Q-399`); no budget condition (`Q-397`) | none | ar09 |
| `SPEC-BRK-005`, `SPEC-BRK-006` | alerts only (`Q-399`): window of 3,600 s opened at the first record after expiry; alert when `seized_w × 10^4 > 2,000 × creditedAtStart` or 3 route failures; no latch or cooldown; a temporary gate reopens after 1,800 s of healthy observations | none | ar09 |
| `REQ-ADAPTER-082`, `REQ-MREG-023` | freeze read only on new-activity paths | — | ar10 |
| `SPEC-CHAIN-001` | `G(n) = 1,310,000 + 240,000 × n` gas units per liquidation of an account with `n` records; record cap 16, so `G(16) = 5,150,000 ≤ 16,777,216 / 2 = 8,388,608` (largest fitting count 29); keeper gas budget `k × G(16)`; no minimum debt (`Q-381`) | none | ch01, ar11 |
| `SPEC-CAP-009` | borrow capacity `capRay = ⌊totalCollateralValue × RAY × avgCollateralFactor / WAD⌋` (maximum at HF 1.00), recommended `⌊capRay × 100 / 110⌋` (HF 1.10, `Q-398`); the idle test is removed (`Q-396`) | capacity down, recommended down | ar11 |
| `SPEC-CAP-010` | `Σ drawCap ≤ line`; `line × 10^dec × coverageRatioBps ≤ funded × 10^4` | none | ar11 |

## Properties

Bounds common to the integer models: shares and indices `< 2^120`, prices `< 2^64`, vault decimals 6–18, solver timeout 120 s per query.

### `ar01_health_factor.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-01a–d | `CF_LP` never above `min(CF0,CF1) × prf / 10^4`, at most 1 bps below, `≤ min(CF0, CF1)`, product `< 10^8` | SPEC-HUB-001, SPEC-CF-001 | `0 < CF < 10^4`, `0 < prf ≤ 10^4` | PROVED |
| MATH-AR-02a–b | `percentMulUp(maxLB, CF) < 10^4 ⇔ maxLB × CF ≤ 99,990,000`; with it and HF ≥ 1, collateral ≥ debt × maxLB | SPEC-HUB-005, SPEC-CF-002 | `maxLB ≤ 2 × 10^4` | PROVED |
| MATH-AR-02c | 3,150 and 3,276; largest listable CF 9,522 (maxLB 10,500), 9,090 (11,000) | SPEC-HUB-005, SPEC-CF-002 | — | COMPUTED |
| MATH-AR-03a–d | floored hf passes a WAD threshold only if the exact ratio does; hf ≤ exact; collateral amount rounds down; borrowed amount fully counted | SPEC-HUB-008, SPEC-PROXY-006, SPEC-PROXY-001, SPEC-CF-003 | — | PROVED |
| MATH-AR-04a | two markets, GHO + USDC debt: `hf ≥ 1e18 ⇔ Σ DV ≤ B` | SPEC-CF-001, SPEC-PROXY-006 | — | PROVED |
| MATH-AR-04b | `B = $24,600`; 8,000 GHO + 16,601.66 USDC exhaust it | SPEC-CF-001 | V4 port | COMPUTED |
| MATH-AR-05a–b | no overflow on the HF path | SPEC-PROXY-006, SPEC-HUB-008 | collateral ≤ $1e15, debt ≤ 1e15 units, index ≤ 1000 RAY | PROVED |
| MATH-AR-32 | 2,812, 3,120, 3,000 bps | SPEC-HUB-001, SPEC-CF-001 | — | COMPUTED |
| MATH-AR-33 | `V_A`, `V_B`, debt values, hf 3.075e18, 1,892,380,476,172,160,467, 1,069,634,976,194,099,615, 1,560,156,015,601,560,156, 1,075,969,665,932,110,452 | SPEC-PROXY-006, SPEC-PROXY-001, BOR-011 | V4 port | COMPUTED |
| MATH-AR-34 | a debt-asset price rise lowers hf | SPEC-PROXY-006 | — | PROVED |
| MATH-AR-35 | 9,523,809,523,809,523,809,524 shares; debt 10,000,000,000,000,000,000,001 | SPEC-HUB-008 | — | COMPUTED |

### `ar02_opening_gate.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-06a–d | the gate on `hfEx` implies the exact rescue-excluded ratio ≥ 1.10 when a 1.10 hard floor is set, ≥ 1.00 with the floor off (default, `Q-398`), ≥ the required maximum; no rounding bypass | SPEC-PROXY-001, SPEC-CF-003, SPEC-CF-005 | same-call read | PROVED |
| MATH-AR-07 | debt recorded ≥ amount borrowed | SPEC-HUB-008, SPEC-PROXY-004, SPEC-CF-003 | — | PROVED |
| MATH-AR-08a | the drawn index never decreases | SPEC-CF-003, SPEC-HUB-007 | — | PROVED |
| MATH-AR-08b | an account opened at 1.10 is below 1.10 one hour later at 9% (the gate is point-in-time) | SPEC-CF-003 | deliberate | COUNTEREXAMPLE |
| MATH-AR-08c | days for interest alone to take hf 1.10 (recommended) / 1.05 to 1.00 (632.6 / 323.8 days at 5.5%) | SPEC-CF-003, SPEC-HUB-007 | prices fixed | COMPUTED |
| MATH-AR-36a–e | `E` ≥ exact rescue value; `hfEx ≤ hf`; `E = 0 ⇒ hfEx = hf`; monotone in `E`; rescue units carry no new debt | SPEC-CF-005, INV-082 | — | PROVED |
| MATH-AR-36f | `E = $312`, `hfEx = 1.1688e18`, 1.0714 at 10,909.09, largest debt 10,625.45 (Aave hf 1.1294) | SPEC-CF-005, INV-082 | — | COMPUTED |
| MATH-AR-37 | Lens recommended vs maximum (`Q-398`): $100,000 at CF 70% gives 63,636 and 70,000; $22,363.63; 14,365.07 USDC meets HF 1.10; `15,600 / 1.10 / 0.9999 = 14,183.2365`, 14,183.23 USDC meets it and 14,183.24 is above it; previewBorrowMax 1.105501 and 572.58 | SPEC-CF-003, SPEC-PROXY-001, BOR-011 | V4 integers | COMPUTED (F-AR-1 resolved) |

### `ar03_liquidation.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-09a–b | `minLB ≤ bonus ≤ maxLB`; bonus non-increasing in hf | SPEC-HUB-005 | — | PROVED |
| MATH-AR-09c | a curve outside `SPEC-HUB-005 (b)` pays < 1% at hf just below 1 | SPEC-HUB-005 | deliberate | COUNTEREXAMPLE |
| MATH-AR-10 | covering the target amount gives `hf_after ≥ targetHealthFactor` | SPEC-HUB-005 | one-sided roundings | PROVED |
| MATH-AR-11a, c | partial liquidation raises hf iff `hf ≥ LB × CF` ⇔ collateral ≥ debt × LB | SPEC-HUB-005, SPEC-HUB-008 | reals | PROVED |
| MATH-AR-11b | below `LB × CF` a partial liquidation lowers hf | SPEC-HUB-005 | deliberate | COUNTEREXAMPLE |
| MATH-AR-11d | V4 replay: hf 0.3500 → 0.3481 | SPEC-HUB-005 | — | COMPUTED |
| MATH-AR-12a–f | seized value ≤ paid × bonus in the normal, collateral-cap and premium-only branches | SPEC-HUB-008, SPEC-HUB-005 | A == S for d–f | PROVED |
| MATH-AR-13a–b | dust rule thresholds exact | SPEC-HUB-008, Q-169 | GHO $1 | PROVED |
| MATH-AR-14 | $50,000 LP, 15,918 GHO, hf 0.98, target 1.10: every curve reaches 1.100000 (SPEC-HUB-005 curve: 2.59% bonus, 2,448.72 GHO repaid) | SPEC-HUB-005 | V4 port | COMPUTED |
| MATH-AR-15a–b | debt ≤ 1,111 GHO at hf 0.98 is liquidated in full; seizing a $600 reserve leaves 608.87 GHO | SPEC-HUB-008, Q-169 | V4 port | COMPUTED |
| MATH-AR-38a | bound (a) and `THF ≥ 1e18` make `THF − percentMulUp(LB × 1e14, CF) > 0` | SPEC-HUB-005 | `LB ≤ maxLB` | PROVED |
| MATH-AR-38b | 3,276; minLB 10,200 ≥ 200; bonus 10,290 at hf 0.97 | SPEC-HUB-005 | V4 port | COMPUTED |

### `ar04_repay.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-16a–d | partial repay: `D − x ≤ D' ≤ D − x + ⌈idx/RAY⌉`; premium-only exact; repaying `x = D` restores every drawn share | SPEC-PROXY-003, SPEC-HUB-008 | idx < 2^100 | PROVED |
| MATH-AR-17a | a repay-all signed as a fixed amount leaves debt after one block | SPEC-PROXY-003, SPEC-PROXY-007 | deliberate | COUNTEREXAMPLE |
| MATH-AR-17b–d | `D_e ≤ M ⇒ spent = D_e`, debt 0, refund `M − D_e ≥ 0`; with a transfer fee nothing above `M` is pulled; partial `x ≤ min(M, D)` | SPEC-PROXY-003, SPEC-PROXY-007 | — | PROVED |
| MATH-AR-18a–c | interest never lowers debt | SPEC-PROXY-003, SPEC-HUB-007 | — | PROVED |
| MATH-AR-19 | total GHO debt < $1,000 is liquidated in full by the dust rule | SPEC-HUB-008, Q-169 | — | PROVED |
| MATH-AR-39 | `quoteRepayAll` ≥ live debt at any inclusion up to the deadline | SPEC-PROXY-007 | `D_s ≥ 20,000` units; growth ≤ quoted + 9 bps | PROVED |
| MATH-AR-40 | 5,024,657,535; 8,032,876,712,328,767,123,288; refunds 5,342,465 and 7,123,287,671,232,876,712; quote 5,029,687,935; `D_e` 5,024,657,765; refund 5,030,170; $13,057.03; HF 1.8840; 5,032.876…; 3,007.123… | SPEC-PROXY-003, SPEC-PROXY-007, REP-004, REP-010 | linear accrual | COMPUTED |

### `ar05_risk_premium.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-20a–c | Hub and Spoke drawn-share books agree | SPEC-HUB-004, SPEC-HUB-008 | idx ≥ RAY | PROVED |
| MATH-AR-21 | user premium ≤ highest collateral risk | SPEC-HUB-004 | 3 collaterals | PROVED |
| MATH-AR-22 | threshold equal to the top risk breaks with two users | SPEC-HUB-004 | deliberate | COUNTEREXAMPLE |
| MATH-AR-23a–c | +1 bps passes when every user holds ≥ 9,999 shares (2, 3, 4, 6 users) or in the aggregate form | SPEC-HUB-004, Q-141 | — | PROVED |
| MATH-AR-24a | three one-share users break +1 bps alone | SPEC-HUB-004 | deliberate | COUNTEREXAMPLE |
| MATH-AR-24b–c | with one 1,000 GHO account, dust users cannot break it; > 1e16 needed | SPEC-HUB-004, Q-169 | index ≤ 10 | PROVED / COMPUTED |
| MATH-AR-24d | no minimum debt: a 1 wei borrow records exactly one drawn share (the example's corrected sentence) | SPEC-HUB-004, Q-169 | index in `[RAY, 2^100)` | PROVED (F-AR-2 resolved) |
| MATH-AR-25 | raising a collateralRisk above the threshold blocks liquidation's premium refresh | SPEC-HUB-004, Q-178 | deliberate | COUNTEREXAMPLE |
| MATH-AR-41 | 1,501; 750e18 vs 750.5e18 passes; two one-share users fail | SPEC-HUB-004 | — | COMPUTED |

### `ar06_vault_shares.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-26a–d | A == S makes every conversion exact and is kept by every Hub operation | SPEC-HUB-008, SPEC-HUB-002, SPEC-PROXY-005 | no drawn debt on the vault asset | PROVED |
| MATH-AR-26e | scope note | — | — | COMPUTED |
| MATH-AR-27 | one wei of interest on the vault asset breaks shares == assets | SPEC-HUB-002, SPEC-HUB-008 | deliberate | COUNTEREXAMPLE |
| MATH-AR-28 | liquidation fee 0 ⇒ no fee shares | SPEC-HUB-008 | — | PROVED |
| MATH-AR-42a–b | supply and withdraw move exactly `units`; 4,815,162,342 example | SPEC-PROXY-005, INV-066 | A == S | PROVED / COMPUTED |

### `ar07_pause_bad_debt.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-29a–b | collateral ≥ debt × LB clears the debt; any sequence repays at most `C/LB` | SPEC-CAP-007, Q-192 | reals | PROVED |
| MATH-AR-30a–c | deficit ≤ `D0 × λ`; none when `h0 (1 − dLP) ≥ (1+g)(1+δ) CF LB`; none up to a 65.4% drop at launch values | SPEC-CAP-007, Q-192, Q-234 | reals | PROVED |
| MATH-AR-30d | a 65.6% drop creates a deficit (boundary of the incident term) | SPEC-CAP-007 | deliberate | COUNTEREXAMPLE |
| MATH-AR-31 | loss table, 48 h, h0 0.95, δ 0 / 0.05 | SPEC-CAP-007, Q-192 | rate 6.75% | COMPUTED |
| MATH-AR-43 | 0.904762, λ 0.096238 / 0.146288, $57,743 ≤ $400,000, $43,887, 330,000 ≤ 990,000, 65.5%, 0.312, $1,282,051, $1,232,051 | SPEC-CAP-007, Q-249 | exact rationals | COMPUTED |
| MATH-AR-44a | collateral budget bounds the debt opened at `h_o` | SPEC-CAP-007, SPEC-CAP-008 | reals | PROVED |
| MATH-AR-44b | tail term: debt carried before liquidation ≤ booked × `CF_t` | SPEC-CAP-007, SPEC-CAP-008 | CF 0.312, h_o 1.10, ≤ 6% interest | PROVED (F-AR-4 resolved; the claim with `/ h_o` failed) |

### `ar08_caps.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-45a–d | charge ≥ value at the booking price and at the floor, ≥ 1; minimum test exact; products `< 2^184` | SPEC-CAP-001, INV-069 | L < 2^120 | PROVED |
| MATH-AR-45e | 9,999,500,000,000; 5,000,000,000,000; 999,950,000 reverts; 1,000,149,990 passes | SPEC-CAP-001 | d = 6 | COMPUTED |
| MATH-AR-46a–d | regular budget never exceeded; slice within Z; `R ≤ K`, `S ≤ Z` kept; token counter ≤ cap + slices | SPEC-CAP-002, INV-028 | — | PROVED |
| MATH-AR-46e | room $10,000, slice $10,000, R $1,000,000, new-account revert | SPEC-CAP-002 | — | COMPUTED |
| MATH-AR-47a–b | `usdToRestore` restores `h_o`; a top-up within `restoreBooked` has served value < `usdToRestore` + 1 | SPEC-CAP-003, REQ-RISK-066 | `served8 ≤ price8` | PROVED |
| MATH-AR-47f | a top-up worth `usdToRestore` at `served8` is charged at most `restoreBooked` (SIM-GAP-14) | SPEC-CAP-003, REQ-RISK-026, REQ-RISK-066 | `served8 ≤ price8` | PROVED |
| MATH-AR-47c | excess `< 3` units while `served8 = price8 ≥ stressFloorUsd` | SPEC-CAP-003 | floor $1, book price = `price8` | PROVED (F-AR-3 resolved) |
| MATH-AR-47d | excess `< max(price8, floor)/served8 + 2` units | SPEC-CAP-003 | same | PROVED |
| MATH-AR-47e | 8e28; 266,666,666,667; 333,333,333,334; Drifting 342,721,791,560 (old divisor 77.8%); $3,000 reverts, $2,000 fits | SPEC-CAP-003, REQ-RISK-066 | — | COMPUTED |
| MATH-AR-48a–d | `charge(U0) = C0`, `charge(0) = 0`; release within what the units carried; split-invariant; slice first | SPEC-CAP-004 | C0 < 2^184 | PROVED |
| MATH-AR-48e | 7,999,600,000,000; release 1,999,900,000,000; S 0; R −$14,999 | SPEC-CAP-004 | — | COMPUTED |
| MATH-AR-49a–c | floored liqHM only tightens; sides `< 2^134` and `< 2^142`; 1.9e16 passes, 2.1e16 fails | SPEC-CAP-005, REQ-RISK-023 | — | PROVED / COMPUTED |
| MATH-AR-50a–b | remaining charge ≥ `u × floor / 10^d`; credited units ≤ `addCap × 10^d` | SPEC-CAP-006, SPEC-HUB-002 | 3 records | PROVED |
| MATH-AR-50c | with `addCap ≥ ⌈(max(K, R) + max(Z, S)) / floor⌉`, every pledge or top-up within the Avana budget fits under `addCap` | SPEC-CAP-006, SPEC-HUB-002 | counters may exceed tightened caps | PROVED (F-AR-5 resolved) |
| MATH-AR-50d | 5,500,000; 4,230,770; 1,100,000; after a tightening 1,000,000, 910,000 > 600,000; `(2^40 − 1) × 10^18 < 2^120` | SPEC-HUB-002, SPEC-CAP-006 | — | COMPUTED |
| MATH-AR-51a–b | draws stay within the credit line; 2,003,475 reverts; largest borrow 96,525 | SPEC-HUB-003 | two Spokes | PROVED / COMPUTED |
| MATH-AR-52a–b | the ratio never overstates; tail 56,160,000,000,000; 7,122 bps with 400,000 GHO funded | SPEC-CAP-008 | — | PROVED / COMPUTED |

### `ar09_breakers.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-53a–c | price-drop alert (`Q-399`, no trip) fires exactly past 300 bps; a checkpoint older than 7,200 s never alerts; products `< 2^78` | SPEC-BRK-001, REQ-RISK-065 | 100–2,000 bps | PROVED |
| MATH-AR-53d | 193,990,000 alerts; 194,000,000 does not | SPEC-BRK-001 | — | COMPUTED |
| MATH-AR-54a–b | pledges within the pool-share cap never trip the 10% gate (one value, `Q-399`); floored liqHM trips earlier | SPEC-BRK-002, SPEC-CAP-005, REQ-PSTORE-016 | breaker ≥ cap | PROVED |
| MATH-AR-54c | an exempt rescue top-up can raise the share past the breaker | SPEC-BRK-002 | deliberate | COUNTEREXAMPLE |
| MATH-AR-54d, 55c, 56c | 2.1e12 trips at 1,000 bps; USDT rate 10 trips; deficit 10,000.5 GHO trips and exactly 10,000 does not | SPEC-BRK-002, SPEC-BRK-003, SPEC-BRK-004 | — | COMPUTED |
| MATH-AR-55a–b | `None` never trips; failure modes trip; fee rate > 0 trips | SPEC-BRK-003 | — | PROVED |
| MATH-AR-56a–b | DEFICIT on the ray value equals the rounded-up base units; max 0 trips on any deficit | SPEC-BRK-004, DEF-018 | — | PROVED |
| MATH-AR-57a–b | `creditedAtStart` is the credited total before the window; a temporary gate reopens only after 1,800 s of healthy observations (`Q-399`) | SPEC-BRK-005, REQ-MREG-026, EMG-089 | — | PROVED |
| MATH-AR-57c | rolling-hour reading of the window | SPEC-BRK-005 | deliberate | COUNTEREXAMPLE |
| MATH-AR-57d | 2,000,000,000 does not alert; one more unit does; EMG-089 figure; recovery window 1,800 s | SPEC-BRK-005, EMG-089 | state machine | COMPUTED |
| MATH-AR-58a–b | each observation adds 0 or 1; 10:05/10:31/10:52 alert at 10:52 (no latch); 11:07 restarts at 1 | SPEC-BRK-006, REQ-MREG-026 | — | PROVED / COMPUTED |

### `ar10_account_gates.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| MATH-AR-59a–c | age ≤ `min(heartbeat + 600, 4,200)`; no underflow; age 0 means same block | SPEC-PROXY-002, REQ-PROXY-064 | — | PROVED |
| MATH-AR-59d | 4,200; 4,300 fails; 3,900 passes | SPEC-PROXY-002 | — | COMPUTED |
| MATH-AR-60a–b | the proxy ends at its start balance; 370,000 example | SPEC-PROXY-004, BOR-POST-001 | — | PROVED / COMPUTED |
| MATH-AR-61a–d | conforming calls pass with any gap; pass ⇒ one-sided backing; a one-unit difference fails; 1,575,000,000 example | SPEC-PROXY-008, INV-080 | — | PROVED / COMPUTED |
| MATH-AR-62a, b, d | lemma; sizing bound ⇒ `HF' ≥ HF` above the critical HF; floored comparison agrees | SPEC-PROXY-009, INV-089, REP-POST-008 | reals | PROVED |
| MATH-AR-62c | below the critical HF the sized repayment lowers HF (the after-check refuses it) | SPEC-PROXY-009 | deliberate | COUNTEREXAMPLE |
| MATH-AR-62e | 2,967.319412528724148266; 7,032.680587…; fee 2.6706; 15.01 GHO; HF 1.5732; 780; 0.3154 | SPEC-PROXY-009, INV-089, REP-POST-008 | — | COMPUTED |
| MATH-AR-63a–b | margin keeps true collateral above debt; 50, 350, 75; 7,000 and 7,188 > 350 | SPEC-CF-004, SPEC-HUB-006 | reals | PROVED / COMPUTED |
| MATH-AR-64a–c | the freeze never changes an exit or liquidation; a frozen wallet opens no new exposure; unfrozen wallets unaffected | REQ-ADAPTER-082, REQ-MREG-023, REQ-PROXY-099, INV-081 | boolean model | PROVED |
| MATH-AR-65 | `keeperFloor` 1 (`Q-400`): freezing a third of 4 keepers is allowed, the last refused; MAX_KEEPERS 32; 4 active markets; target 1e18 out of bounds; one 10% pool-share value; breakerDeficitMax 10,000 GHO in bounds | REQ-MREG-021, REQ-MREG-031, REQ-PSTORE-022, REQ-PSTORE-016 | — | COMPUTED |

## Findings

Five findings, all resolved in the spec. Each script now encodes the corrected text as its claim and passes; the text each finding replaced is quoted below.

- **F-AR-1 (low) — largest single-market USDC borrow rounded up.** [2.6](../../../02-contracts/06-aave-adapter.md) Worked examples and [3.2](../../../03-operations/02-borrow.md) Worked Example state "The largest USDC borrow that passes … `15,600 / 1.10 / 0.9999 = 14,183.24` USDC". A borrow of 14,183.24 USDC gives `hf = 1,099,999,728,976,989,852 < 1.10e18` and reverts; 14,183.23 passes (MATH-AR-37). Change both sentences to: "`15,600 / 1.10 / 0.9999 = 14,183.2365`, so 14,183.23 USDC (rounded down; 14,183.24 reverts)". **Resolved in spec** (2.6, 3.2); MATH-AR-37 COMPUTED; the previewBorrowMax figures are unchanged.
- **F-AR-2 (low) — `SPEC-HUB-004` example cites a minimum debt that does not exist.** "Aave's 1,000 GHO minimum debt (`Q-072`) keeps every real account far above 9,999 shares": there is no minimum debt (`Q-072`, `Q-169`, `REQ-PROXY-016`), and a borrow of 1 wei records 1 drawn share (MATH-AR-24d). The check still holds through the aggregate form (MATH-AR-23c, MATH-AR-24b–c). Replace the sentence with: "There is no minimum debt (`Q-169`), so an account can hold a single drawn share; the aggregate form still holds because the other accounts' slack absorbs it: one 1,000 GHO account at the 1 bps margin covers more than 10^16 one-share accounts." **Resolved in spec** (`SPEC-HUB-004` example); MATH-AR-24d PROVED (a 1 wei borrow records exactly one drawn share).
- **F-AR-3 (low) — `SPEC-CAP-003` rounding bound.** "the bound exceeds the exact value by at most 3 units of 1e-8 USD" fails when `price8 < stressFloorUsd`: with `price8 = 1,000,000`, floor `10^8`, `hf = h_o − 1`, `D = 10^57`, `CF = 3,000`, `usdToRestore = 1` and `restoreBooked = 100` against an exact value near 0 (MATH-AR-47c). The bound that holds (MATH-AR-47d): replace with "Rounding: all up, so the bound exceeds the exact value by less than `max(price8, stressFloorUsd[m]) / price8 + 2` units of 1e-8 USD (less than 3 while `price8 ≥ stressFloorUsd[m]`)." **Resolved in spec** (`SPEC-CAP-003` rounding sentence); MATH-AR-47c PROVED for `price8 ≥ stressFloorUsd`, MATH-AR-47d for any price.
- **F-AR-4 (low) — `SPEC-CAP-007 (ii)` tail term uses the opening health factor.** "the debt those positions can carry is at most their booked value times `CF_t / minOpeningHealthFactor`" holds only at the moment of borrowing; interest accrued since (and LP value above the booked value) lets debt reach booked value × `CF_t` while the account is still not liquidatable (MATH-AR-44b: CF 0.312, `h_o` 1.10, opened at `h_o`, 3.1% interest later, still `hf ≥ 1`, debt 3.1% above the claim). The tail then understates the exposure by up to the factor 1.10. Replace `× CF_t / minOpeningHealthFactor` with `× CF_t` in `SPEC-CAP-007 (ii)`, `SPEC-CAP-008` (`⌈(tokenUsdCap[t] + Σ topUpSliceUsd[m]) × CF_t / 10^4⌉`), the `tokenUsdCap` row of [1.5](../../../01-architecture/05-parameters.md) and `Q-249`, with the reason "the debt those positions can carry before liquidation is at most their booked value times `CF_t` (health factor 1)". The examples become: a 100,000 GHO reserve covers $320,512 of token cap plus slices; the `SPEC-CAP-008` tail is $140,400 (`14,040,000,000,000`) and `tailCoverageBps = 7,122`. **Resolved in spec** (`SPEC-CAP-007 (ii)`, `SPEC-CAP-008`, [1.5](../../../01-architecture/05-parameters.md) `tokenUsdCap`, `Q-249`, `MKT-013`); MATH-AR-44b PROVED, MATH-AR-43 and MATH-AR-52b COMPUTED.
- **F-AR-5 (low) — `SPEC-CAP-006` after a cap tightening.** A tightening leaves existing records untouched (`REQ-RISK-042`), so the counters can exceed the new `marketUsdCap` (`R > K`). With `addCap` at the rule minimum `⌈(K + Z)/floor⌉`, the credited units plus a slice top-up can then exceed `addCap` and the Hub rejects a pledge Avana admitted (MATH-AR-50c). Example: `K` lowered from $1,000,000 to $500,000 with `R = $900,000` booked at the $1.00 floor, `Z = $100,000`, `addCap = 600,000`: a $10,000 rescue top-up passes Avana and needs 910,000 tokens of Hub room. Replace the rule with "`addCap(m) ≥ ceilDiv(max(marketUsdCap[m], regularUsed) + max(topUpSliceUsd[m], sliceUsed), stressFloorUsd[m])`, or equal `MAX_ALLOWED_SPOKE_CAP`", and the Why with "every live record's remaining charge is at least `u × stressFloorUsd / 10^d` and `R + S ≤ max(K, R) + max(Z, S)` at every point". **Resolved in spec** (`SPEC-CAP-006`, with a note in `SPEC-HUB-002`); MATH-AR-50c PROVED, the tightening example in MATH-AR-50d COMPUTED.

The other counterexamples are deliberate: wrong-reading checks (MATH-AR-17a, 22, 24a, 25, 27, 57c), and boundary checks that show where a proved bound stops (MATH-AR-08b, 09c, 11b, 30d, 54c, 62c). Each states behaviour the final spec accepts.

## Results

| Date | Command | Versions | Bounds | Proved | Counterexample | Computed | Mismatch | Timeout | Exit |
|---|---|---|---|---|---|---|---|---|---|
| 2026-11-10 | `../../.venv/bin/python <file>.py` for `ar01` … `ar10` | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 122 | 16 (12 deliberate, 4 findings) | 40 | 1 (finding) | 0 | 0 for ar01, ar03, ar04, ar06, ar09, ar10; 1 for ar02 (F-AR-1), ar05 (F-AR-2), ar07 (F-AR-4), ar08 (F-AR-3, F-AR-5) |
| 2026-11-10 (after the spec fixes) | same | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 127 | 12 (all deliberate) | 41 | 0 | 0 | 0 for every script; F-AR-1…F-AR-5 resolved in spec |
| 2026-11-10 (restore amount divided by the served price, `SPEC-CAP-003`; `MATH-AR-47f` added) | same | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 127 | 12 (all deliberate) | 41 | 0 | 0 | 0 for every script; `ar08` 24 proved, 8 computed |
| 2026-11-10 (no minimum debt, `Q-381`: `MATH-CH-01` and `MATH-CAP-09` rewritten from the keeper break-even to the `SPEC-CHAIN-001` gas units model, and `MATH-CAP-09` adds the `SPEC-CAP-009` idle test; scripts renamed `ch01_gas_model.py` and `ar11_record_gas_credit_lines.py`) | `../../.venv/bin/python ch01_gas_model.py`, `ar11_record_gas_credit_lines.py` | Python 3.9.6, z3-solver 4.13.0 | 120 s per query | ch01 2, ar11 10 | 0 | ch01 7 figures, ar11 4 | 0 | 0 | 0 for both |
| 2026-11-10 (parameter decisions `Q-396`, `Q-398`, `Q-399`, `Q-400`: `ar02` gate at HF 1.00 with an optional hard floor and the Lens recommended borrow at HF 1.10; `ar09` price drop, seizure surge and route failures as alerts, pool share 10%, deficit 10,000 GHO, 30-minute reopening; `ar10` keeperFloor 1; `ar11` `MATH-CAP-09e–h` rewritten from the removed idle test to the Lens capacity) | same | Python 3.9.6, z3-solver 4.13.0 | 120 s per query; integer bounds per table | 139 | 12 (all deliberate) | 52 | 0 | 0 | 0 for every script |

Per script (proved / counterexample / computed / mismatch), latest run: ar01 14/0/5/0; ar02 11/1/3/0; ar03 15/2/5/0; ar04 12/1/2/0; ar05 12/3/2/0; ar06 6/1/2/0; ar07 7/1/2/0; ar08 24/0/8/0 (includes MATH-AR-47f); ar09 12/2/6/0; ar10 14/1/6/0; ar11 10/0/4/0; ch01 2/0/7/0.

## Assumptions common to all models

- The LPOracle and DebtOracle prices are taken as served; their own rounding and state machines are modelled in `units-oracle/`.
- Settlement after a seizure (unwind, swaps, flash repayment, the fee and the sell-back floor) is modelled in `settlement/`.
- The vault-token Hub asset has A == S (proved inductive in MATH-AR-26) unless stated.
- `_common.py` holds the helpers; `_v4ref.py` is an exact-integer Python port of the V4 functions above, used for the worked examples.
