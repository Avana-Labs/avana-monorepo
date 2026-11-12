# Units, oracle and backing models (MATH-UO)

Z3 models of how Avana measures and prices vault-token collateral: the vault-token unit and decimals, the LPOracle and DebtOracle price math and price states, the backing ledger in Collateralization and the USD exposure counters ([2.3](../../../02-contracts/03-collateralization.md), [2.4](../../../02-contracts/04-vault-tokens.md), [2.10](../../../02-contracts/10-lp-oracle.md)). Every `SPEC-UNIT-001…006`, `SPEC-ORC-001…023` and `SPEC-BACK-001…014` formula is cited by at least one check here; the worked examples of these pages are recomputed in [`../../sympy/sym08_units_oracle_backing_examples.py`](../../sympy/sym08_units_oracle_backing_examples.py) and the exact-real algebra in `sym03` and `sym04`.

Run one script with `../../.venv/bin/python <file>.py`, or every model with `../../run_all.sh`. Each check prints `PROVED` (no state violates the property), `COUNTEREXAMPLE` (Z3 found a state; the model is printed), `COMPUTED` (an exact-integer computation over the launch configuration) or `TIMEOUT`. A script exits 1 only when a result differs from the `expect` value recorded beside the check. Every check carries a `# MATH-UO-NN verifies: …` tag that `../../trace.py` reads.

## What is modelled

- Unbounded integers and reals unless a row says otherwise; bit-vector models (`uint128`, `uint256`) wherever overflow or truncation is the question.
- Uniswap v3: an exact port of `TickMath.getSqrtRatioAtTick` (checked against `MIN_SQRT_RATIO` and `MAX_SQRT_RATIO`), `Tick.tickSpacingToMaxLiquidityPerTick`, and the `SqrtPriceMath` burn formulas, which round down.
- Aave V4 Hub: `addCap` in whole tokens as `uint40` (`2^40 − 1` means no cap), `uint120` shares, `toValue = amount · price · 10^(18 − decimals)`, 224-bit `KeyValueList` values.
- Launch stablecoins in Uniswap address order (token0 < token1): USDC/USDT (`d = 6`), DAI/USDC (`d = 12`), GHO/USDC (`d = 12`), DAI/USDS (`d = 18`), GHO/DAI (`d = 18`); "USDC/GHO" checks that a listing name in the other order gives the same pool order.
- Constants: `MAX_ROUTE_ANSWER = 10^12` ($10,000, 8 decimals), `stableCeilingUsd = 10^8`, `MAX_FULL_RANGE_EPSILON = 10^-12`, `LISTING_SHOCK_FACTOR = 100`.

## Formulas

| Formula | Final rule | Rounding | Source |
|---|---|---|---|
| Decimals | smallest `d ∈ [6, 18]` with `10^d · v ≥ $1`, `v` the USD value of one credited unit at the listing prices; listing fails if none qualifies. A two-token full-range market with an even `d0 + d1` gives `d = (d0 + d1) / 2`, the special case `MATH-UO-01` checks | exact | `SPEC-UNIT-001`, `SPEC-ORC-005` |
| Unit | 1 base unit = 1 credited liquidity unit; mint and burn exactly the units credited or debited | none | `SPEC-UNIT-002`, `SPEC-BACK-002` |
| Whole-token value | `2·√(p0·p1)` USD, ideal full range; tick-bounded holdings worth `ideal·(1 − ε)`, `ε = (sP/sU + sL/sP)/2` (the two-token full-range reference of the composition) | — | `SPEC-UNIT-003`, `SPEC-ORC-006`, `SPEC-ORC-007` |
| Vault-token decimals | smallest `d ∈ [6, 18]` with `price8(10^d) ≥ 10^8` at listing prices | exact | `SPEC-ORC-005` |
| Composition (concentrated liquidity) | `s = min(max(s_O, s_a), s_b)`; `getAmountsForLiquidity(s, s_a, s_b, 10^d)` | down | `SPEC-ORC-006` |
| Aave value | `n · price8 / 10^d`; Aave computes `n · price8 · 10^(18 − d)` | Aave's | `SPEC-UNIT-004` |
| Hub cap | `addCap ≥ ⌈(marketUsdCap + topUpSliceUsd) / stressFloorUsd⌉` whole tokens | up | `SPEC-UNIT-005`, `MKT-014` |
| Supply bound | `totalSupply ≤ maxLiquidityPerTick(s) < 2^120` for `s ∈ {1, 10, 60, 200}` | none | `SPEC-UNIT-006` |
| Leg normalisation | signed answer `a`: 0 if `a ≤ 0` or `a ≥ 2^128`; else `a · 10^(8 − f)` if `f ≤ 8`, else `⌊a / 10^(f − 8)⌋`; 0 is a failure | down | `SPEC-ORC-001` |
| Route | `mulDiv(aA, aB, 10^(fA + fB − 8))` for `0 < aA, aB < 2^128`, else 0; `t_r = min` of leg times | down | `SPEC-ORC-002` |
| Agreement | `p, b ∈ [1, MAX_ROUTE_ANSWER]` and `\|p − b\| · 10^4 ≤ T · min(p, b)` | exact | `SPEC-ORC-003`, `SPEC-ORC-020` |
| Stable ceiling | `v = min(q, stableCeilingUsd)` for a USD stable | none | `SPEC-ORC-004` |
| sqrtPriceX96 | `num ≥ 2^128·den` → `MAX_SQRT_RATIO − 1`; `num ≥ 2^64·den` → `isqrt(mulDiv(num, 2^128, den)) · 2^32`, at most `MAX_SQRT_RATIO − 1`; else `isqrt(mulDiv(num, 2^192, den))`, at least `MIN_SQRT_RATIO` | down | `SPEC-ORC-009` |
| TWAP | `meanTick = ⌊Δ / W⌋`; pass iff `\|meanTick − tickRef\| ≤ τ`, `tickRef` from uncapped quotes | toward −∞ | `SPEC-ORC-010` |
| Vault-token price | `price8 = max(1, Σ_i ⌊(a_i − 1)⁺ · v_i / 10^(d_i)⌋)`, valid only for one length `n ∈ [2, 8]`, `a_i < 2^128`, `d_i ≤ 77`, `v_i ∈ [1, MAX_ROUTE_ANSWER]`; two-token full-range reference `isqrt(4·v0·v1) − 1` | down, then 1 raw unit per token | `SPEC-ORC-008` |
| USD band | `usdBandLow^⊗n ≤ ⊗ q_i` and `⊗ v_i ≤ usdBandHigh^⊗n`, `x ⊗ y = ⌊x·y/10^8⌋` left to right in pool order, saturating at `2^256 − 1` and staying there (n = 2: `usdBandLow² ≤ q0·q1` up to one floor) | down | `SPEC-ORC-011` |
| USD level | `usdLevel = max{L : L^⊗n ≤ ⊗ q_i}`; `usdBandLow ≤ usdLevel` iff the lower band test passes | down | `SPEC-ORC-011` |
| Served collateral price | Live `fresh`; Drifting `min(fresh, A)`; disagreement `min(price8(w0, w1), fresh, A)` with `w = ceil(min(p, b))`; Cached `A`; Expired `1` | as `price8` | `SPEC-ORC-012`, `SPEC-ORC-017` |
| Served debt price | Live `q`; disagreement `max(p, b, A)`; Cached `A`; Expired `⌈A·(10^4 + max(δ, 100))/10^4⌉`, `100 ≤ δ ≤ 5,000`, saturating at `2^256 − 1` | up | `SPEC-ORC-018` |
| Failure start | `failureStart = min(S_ts, failedSince, now)`, `staleAt = max(staleFrom_primary, staleFrom_alternate)` | none | `SPEC-ORC-013` |
| Recovery evidence | `B_i = S_primary ∩ S_alternate`; Expired by timestamps iff `\|B_i\| ≥ cachedWindow` and `E_i > recoveredAt` | none | `SPEC-ORC-014` |
| Feed age limit | `feedMaxAge = liquidationPriceMaxAge = feedHeartbeat + heartbeatMargin`; `borrowPriceMaxAge ≤ feedMaxAge` | none | `SPEC-ORC-019` |
| Age limits | `maxAge() = min_ℓ(updatedAt_ℓ + limit_ℓ) − servedUpdatedAt`; alternate legs use `min(liquidation, borrow)` | none | `SPEC-ORC-015` |
| Second source | `\|q − s\| · 10^4 ≤ S · min(q, s)` | exact | `SPEC-ORC-020` |
| Sequencer gate | ready iff up and `now ≥ startedAt + grace`; down pauses seizure; unknown blocks borrow only | none | `SPEC-ORC-021` |
| Grace covers every window | on a chain with a sequencer, `gracePeriod ≥ max(twapWindow, secondSource.twapWindow, standby.twapWindow)` over every configured market and its tokens | none | `REQ-PSTORE-034` |
| Observation buffer | `⌈W / CHAIN_BLOCK_TIME⌉ + 1` | up | `SPEC-ORC-022` |
| Gas guard | before a read with gas `G`: `gasleft ≥ ⌈64G/63⌉ + POST_CALL_GAS`; floor `max(W_poke, max_k(u_k + ⌈64·G_k/63⌉ + POST_CALL_GAS))` | up | `SPEC-ORC-023` |
| Token-decimals gate | `borrowAllowed ⇒ now − decimalsCheckedAt ≤ DECIMALS_CHECK_MAX_AGE = 7,200`; a `decimals()` read by `poke()` that fails or differs from the stored value fails the market (reason bit 1) | exact | `REQ-ORACLE-107` |
| Pause windows | `pauseActive = D ∧ now < s + pauseMax`; `disagreementExpired = D ∧ now ≥ s + pauseMax` (the same `s`) | none | `SPEC-ORC-016`, `REQ-ORACLE-095` |
| Full range | `tickLower = (MIN_TICK / s)·s`, `tickUpper = (MAX_TICK / s)·s` | toward zero | `SPEC-BACK-001` |
| Pledge charge | `usdCharge = mulDiv(c, max(price8, stressFloorUsd), 10^d, Ceil)`; minimum test `pledgeUsd = mulDiv(c, price8, 10^d, Floor)` | up / down | `SPEC-BACK-003`, `SPEC-CAP-001` |
| Counters at pledge | Regular `+= usdCharge − sliceUsd`, Slice `+= sliceUsd`, token0, token1, depositor `+= usdCharge` | none | `SPEC-BACK-004` |
| Release on exit | `remainingCharge = mulDiv(V0, remainingUnits, U0, Ceil)`; slice first; saturating counters | up | `SPEC-BACK-005` |
| Seizure list | largest first at insertion; debit from the head, `take_r = min(rem, credited_r)`, require `rem = 0` | none | `SPEC-BACK-006` |
| Debit equality | `sharesBefore − sharesAfter = u = supplyBefore − supplyAfter`, with shares = assets at `beginSeizure` | none | `SPEC-BACK-007` |
| Capped collect | `collect(a0, a1)` after `decreaseLiquidity`; book `min(r, a)` | Uniswap's (down) | `SPEC-BACK-008` |
| Backing gap | `gap = totalCredited + pending.units − totalSupply ≥ 0`; Adapter calls keep it unchanged | none | `SPEC-BACK-009`, `REQ-VTOKEN-016` |
| Live covers credit | `live_r ≥ credited_r` | none | `SPEC-BACK-010` |
| Shortfall | `max(accountCredited − S, 0)`, `S` = supplied shares before the call's own movement | none | `SPEC-BACK-011` |
| Pending payout | `⌊amount · x / units⌋`, the final settlement pays the remainder; require `supply + x ≤ totalCredited + units` | down | `SPEC-BACK-012` |
| Re-credit basis | `U0' = u_b + added`, `C0' = c_b + usdCharge` | none; exits up | `SPEC-BACK-013` |
| Rescue units | `L` if rescue, else `mulDiv(L, sliceUsd, usdCharge, Ceil)`; `min(rescueUnits, credited)` after a debit | up | `SPEC-BACK-014`, `REQ-COLL-016` |
| Standby switch | a route-version change reads `disagreeSince` as 0 and keeps `failedSince` | none | `REQ-ORACLE-095` |

## Properties

`COUNTEREXAMPLE (deliberate)` marks a wrong reading of a rule, or a case outside a stated bound, that shows why the final rule or bound is needed; each statement says which. Rows with a bracketed parameter list run once per case.

### `uo01_units_caps.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-01a` | launch pairs: (d0+d1) even and 12 <= d0+d1 <= 36, so d = (d0+d1)/2 is exact and in [6,18] | `SPEC-UNIT-001`, `SPEC-ORC-005`, `REQ-VTOKEN-022` | integers, decimals in [0, 255] | COMPUTED |
| `MATH-UO-01b` | wrong reading without the parity check: an odd d0+d1 truncates d, so 2d != d0+d1 and 2*sqrt(p0*p1) misprices a whole token by sqrt(10) | `SPEC-UNIT-001`, `SPEC-ORC-005`, `REQ-VTOKEN-022` | integers, decimals in [0, 255] | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-01c` | deployment check (d0+d1) % 2 == 0 and 12 <= d0+d1 <= 36 gives an integer d with 2d == d0+d1 and 6 <= d <= 18 | `SPEC-UNIT-001`, `SPEC-ORC-005`, `REQ-VTOKEN-022` | integers, decimals in [0, 255] | PROVED |
| `MATH-UO-02a` (USDC/USDT, DAI/USDC, GHO/USDC, DAI/USDS, GHO/DAI, USDC/GHO) | USD(one whole token) == 2*sqrt(p0*p1) | `SPEC-UNIT-003`, `SPEC-ORC-005`, `SPEC-ORC-008` | reals, prices > 0 | PROVED (6 of 6) |
| `MATH-UO-02b` | legs p0, p1 in [$0.50, $1.50] => whole-token value in [$1, $3] | `SPEC-UNIT-003`, `SPEC-ORC-005`, `SPEC-ORC-008` | reals, prices > 0 | PROVED |
| `MATH-UO-02c` | outside the stated bounds: a deep depeg of one or both legs takes a whole token below $1 | `SPEC-UNIT-003`, `SPEC-ORC-005`, `SPEC-ORC-008` | reals, prices > 0 | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-02d` | price resolution: relative step 1/price8 <= 1e-6 while a whole token is worth >= $0.01 | `SPEC-UNIT-003`, `SPEC-ORC-005`, `SPEC-ORC-008` | reals, prices > 0 | PROVED |
| `MATH-UO-03a` (d=6, d=12, d=18) | finite addCap (< 2^40-1) * 10^d never overflows and stays below 2^120 (Hub uint120 shares never bind first) | `SPEC-UNIT-005`, `MKT-014` | 256-bit vectors, d in {6,12,18} | PROVED (3 of 3) |
| `MATH-UO-03b` | addCap granularity: 1 cap unit = 1 whole token | `SPEC-UNIT-005`, `MKT-014` | 256-bit vectors, d in {6,12,18} | COMPUTED |
| `MATH-UO-04a` | credited units per pool fit Hub uint120 shares for every standard fee tier | `SPEC-UNIT-006`, `SPEC-BACK-001`, `SPEC-BACK-002`, `REQ-VTOKEN-022` | exact integers, spacings 1..16383 | COMPUTED |
| `MATH-UO-04b` | why only spacings 1, 10, 60, 200 are deployable: a spacing >= 6932 lets one pool hold more full-range liquidity than Hub uint120 shares | `SPEC-UNIT-006`, `SPEC-BACK-001`, `SPEC-BACK-002`, `REQ-VTOKEN-022` | exact integers, spacings 1..16383 | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-05a` | amount <= maxLiquidityPerTick(1) (~1.9e32 units), price8 <= 2e10: no overflow anywhere in Aave value math | `SPEC-UNIT-004`, `SPEC-UNIT-005` | 256-bit vectors | PROVED |
| `MATH-UO-05b` | finite Hub addCap (amount <= 2^40-2 whole tokens) and price8 <= 1e20: no overflow (value = whole * price8 * 1e18) | `SPEC-UNIT-004`, `SPEC-UNIT-005` | 256-bit vectors | PROVED |
| `MATH-UO-05c` | outside the stated bounds (2^120 units, d=6, price8 up to 1e12): overflow is reachable, which is why the bounds are listing conditions | `SPEC-UNIT-004`, `SPEC-UNIT-005` | 256-bit vectors | COUNTEREXAMPLE (deliberate) |

### `uo02_fullrange_amounts.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-06a` | e0 <= q0 and q0 - e0 == q0 * (sP/sU) | `SPEC-ORC-006`, `SPEC-UNIT-003` | reals, sL < sP < sU | PROVED |
| `MATH-UO-06b` | e1 <= q1 and q1 - e1 == q1 * (sL/sP) | `SPEC-ORC-006`, `SPEC-UNIT-003` | reals, sL < sP < sU | PROVED |
| `MATH-UO-06c` | value at reference price: exact == ideal * (1 - eps), eps = (sP/sU + sL/sP)/2 > 0 | `SPEC-ORC-006`, `SPEC-UNIT-003` | reals, sL < sP < sU | PROVED |
| `MATH-UO-07` (24 cases: 6 launch pairs x 4 tick spacings) | eps < 1e-12 for P_raw in [P/100, 100P] | `SPEC-ORC-006`, `SPEC-UNIT-003` | exact Q64.96 ticks, P_raw within a 100x shock | PROVED (24 of 24) |
| `MATH-UO-07z` | largest eps at $1 legs across launch pairs and fee tiers | `SPEC-ORC-006`, `SPEC-UNIT-003` | exact Q64.96 ticks, P_raw within a 100x shock | COMPUTED |
| `MATH-UO-08a` | amount0 <= exact0 and exact0 - amount0 < 1 + 1/SP (< 1.0000000003 raw units) | `SPEC-ORC-006`, `SPEC-BACK-008`, `SPEC-UNIT-003`, `REQ-VAULT-059` | reals with floor intervals; integers for 08c | PROVED |
| `MATH-UO-08b` | amount1 <= exact1 and exact1 - amount1 < 1 raw unit | `SPEC-ORC-006`, `SPEC-BACK-008`, `SPEC-UNIT-003`, `REQ-VAULT-059` | reals with floor intervals; integers for 08c | PROVED |
| `MATH-UO-09` | value_at_P(holdings at sQ) >= value_at_P(holdings at sP) (pool manipulation cannot inflate) | `SPEC-ORC-007` | reals, sL < sQ < sU | PROVED |
| `MATH-UO-08c` | capped collect pays exactly the principal a0, leaves exactly the accrued fees owed, and books min(r0, a0) = r0 <= a0 | `SPEC-ORC-006`, `SPEC-BACK-008`, `SPEC-UNIT-003`, `REQ-VAULT-059` | reals with floor intervals; integers for 08c | PROVED |

### `uo03_sqrtprice_from_feeds.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-10a` (USDC/USDT, DAI/USDC, GHO/USDC, DAI/USDS, GHO/DAI, USDC/GHO) | answers in [1, MAX_ROUTE_ANSWER]: num < 2^64 * den, so mulDiv runs and X < 2^256 | `SPEC-ORC-009` | integers, answers in [1, 1e12]; 10b answers up to 1e18 | PROVED (6 of 6) |
| `MATH-UO-10b` | wrong reading without the num >= 2^64*den pre-check: P_raw in [2^64, 2^128) is a valid Uniswap price but mulDiv reverts before the clamp (first hit d0=6, d1=8) | `SPEC-ORC-009` | integers, answers in [1, 1e12]; 10b answers up to 1e18 | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-10c` | after a successful mulDiv, sqrt(X) < 2^128 < MAX_SQRT_RATIO, so the upper clamp can never fire | `SPEC-ORC-009` | integers, answers in [1, 1e12]; 10b answers up to 1e18 | PROVED |
| `MATH-UO-11a` | below 2^64, X < 2^256 whenever mulDiv runs (no revert path) | `SPEC-ORC-009` | integers | PROVED |
| `MATH-UO-11c` | in [2^64, 2^128), Y = mulDiv(num, 2^128, den) < 2^256 (no revert path) and Y >= 2^192 | `SPEC-ORC-009` | integers | PROVED |
| `MATH-UO-11d` | in [2^64, 2^128), isqrt(Y) * 2^32 >= 2^128 > every lower-branch result (monotone across 2^64) | `SPEC-ORC-009` | integers | PROVED |
| `MATH-UO-11e` | below 2^64 the root is below 2^128 | `SPEC-ORC-009` | integers | PROVED |
| `MATH-UO-11b` | final sqrtPriceX96 is in [MIN_SQRT_RATIO, MAX_SQRT_RATIO) so getTickAtSqrtRatio never reverts | `SPEC-ORC-009`, `SPEC-ORC-010` | integers | PROVED |
| `MATH-UO-11f` | upper branch: isqrt(floor(t^2)) in (t - 1, t], so s in (s* - 2^32, s*]: never above the exact root | `SPEC-ORC-009` | integers and reals | PROVED |
| `MATH-UO-11g` | upper branch is monotone: q1 <= q2 gives isqrt(Y1) <= isqrt(Y2) | `SPEC-ORC-009` | integers and reals, q1 >= 2^64 | PROVED |
| `MATH-UO-11h` | across 2^64: 0 < s(q2) - s(q1) < s*(q2) - s*(q1) + 2 (monotone; jump bounded by the rounding) | `SPEC-ORC-009` | reals, the bounds of 11d, 11e, 11f, 12a | PROVED |
| `MATH-UO-11i` | at num = 2^64 * den the upper branch returns 2^128, the exact root; one step below, the lower branch | `SPEC-ORC-009` | exact integers | COMPUTED |
| `MATH-UO-11j` | wrong reading: MAX_SQRT_RATIO - 1 for every ratio in [2^64, 2^65] exceeds 2^31 times the exact root | `SPEC-ORC-009`, `REQ-ORACLE-104` | reals | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-11k` | upper-branch example: p0 = 1e8 (d0 = 6), p1 = 5 (d1 = 18): s = 354,319,114,228,591,420,592,203,432,319,359,385,600, 2,092,627,464 below the exact root | `SPEC-ORC-009` | exact integers | COMPUTED |
| `MATH-UO-12a` | floor(sqrt(floor(num*2^192/den))) in (s* - 2, s*] | `SPEC-ORC-009`, `SPEC-ORC-010` | reals; 12d integers, |delta| <= 2^60, W <= 1e6 | PROVED |
| `MATH-UO-12b` | gap S(t)-S(t-1) >= 214751 (> 2): s >= S(t*-1), so tickRef >= t* - 1 (at most 1 tick low, never high) | `SPEC-ORC-009`, `SPEC-ORC-010` | reals; 12d integers, |delta| <= 2^60, W <= 1e6 | PROVED |
| `MATH-UO-12e` | upper branch: gap S(t)-S(t-1) >= 1.701e+34 (> 2^32) for ticks >= 443637: tickRef >= t* - 1 | `SPEC-ORC-009`, `SPEC-ORC-010` | reals | PROVED |
| `MATH-UO-12c` | launch pairs at $1: 512-bit method vs priceX96 method | `SPEC-ORC-009`, `SPEC-ORC-010` | reals; 12d integers, |delta| <= 2^60, W <= 1e6 | COMPUTED |
| `MATH-UO-12d` | meanTick = trunc(delta/W) - [delta < 0 and delta mod W != 0] is floor(delta/W) (rounds toward -inf) | `SPEC-ORC-009`, `SPEC-ORC-010` | reals; 12d integers, |delta| <= 2^60, W <= 1e6 | PROVED |
| `MATH-UO-13` | wrong reading: listing "USDC/GHO" read as token0=USDC gives tickRef 276324 vs pool tick -276325: permanent Drifting for any tau below 552,000 ticks | `SPEC-ORC-009`, `SPEC-ORC-010` | integers, tau <= 10,000 | COUNTEREXAMPLE (deliberate) |

### `uo04_lporacle_price.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-14a` | price8 <= ideal (never above the closed-form value) | `SPEC-ORC-008`, `SPEC-ORC-002` | reals; 14d 256-bit vectors, answers <= 1e12 | PROVED |
| `MATH-UO-14b` | ideal - price8 < 1 unit (1e-8 USD); relative error < 1/price8 (<= 1e-8 when a whole token >= $1) | `SPEC-ORC-008`, `SPEC-ORC-002` | reals; 14d 256-bit vectors, answers <= 1e12 | PROVED |
| `MATH-UO-14c` | alternative 2*isqrt(a0*a1) is also <= ideal but can be up to 2 units low | `SPEC-ORC-008`, `SPEC-ORC-002` | reals; 14d 256-bit vectors, answers <= 1e12 | PROVED |
| `MATH-UO-14d` | answers <= 1e+12: 4*a0*a1 does not overflow uint256 and price8 < 2^255 (int256 cast safe) | `SPEC-ORC-008`, `SPEC-ORC-002` | reals; 14d 256-bit vectors, answers <= 1e12 | PROVED |
| `MATH-UO-15a` | a0, a1 >= 1  =>  floored root > 1 (so >= 2), hence served price8 = root - 1 >= 1; AaveOracle never sees 0 | `SPEC-ORC-008`, `SPEC-ORC-001` | reals; integers for feed decimals | PROVED |
| `MATH-UO-15b` | why a normalised 0 is a failure: a feed with > 8 decimals and a tiny positive answer normalises (floor) to 0 | `SPEC-ORC-008`, `SPEC-ORC-001` | reals; integers for feed decimals | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-15c` | 8-decimal feeds with answer > 0 never normalise to 0 | `SPEC-ORC-008`, `SPEC-ORC-001` | reals; integers for feed decimals | PROVED |
| `MATH-UO-16a` | wrong reading without the - 1: isqrt(4*a0*a1) can exceed the true value ideal*(1-eps) when 4*a0*a1 is a perfect square (e.g. both legs exactly $1.00000000) | `SPEC-ORC-008`, `SPEC-UNIT-003` | reals, eps <= 2.72e-14 | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-16b` | final: price8 = isqrt(4*a0*a1) - 1 is <= ideal*(1-eps) whenever ideal*eps < 1 (ideal < 3.6e13 for launch eps) | `SPEC-ORC-008`, `SPEC-UNIT-003` | reals, eps <= 2.72e-14 | PROVED |
| `MATH-UO-16c` | final formula keeps price8 > 0 for every positive answer pair (price8_fixed >= 1) | `SPEC-ORC-008`, `SPEC-UNIT-003` | reals, eps <= 2.72e-14 | PROVED |
| `MATH-UO-16d` | size of the overvaluation in MATH-UO-16a | `SPEC-ORC-008`, `SPEC-UNIT-003` | reals, eps <= 2.72e-14 | COMPUTED |
| `MATH-UO-17` | final formula, whole token in [$1, $10,000] (ideal in [1e8, 1e12]): 0 <= (true - price8_fixed)/true < 2.1e-8 | `SPEC-ORC-008` | reals, ideal in [1e8, 1e12] | PROVED |
| `MATH-UO-18` | 4*a0*a1 == 4*a1*a0: the closed form cannot be broken by token0/token1 orientation | `SPEC-ORC-008` | integers | PROVED |

### `uo05_stable_ceiling_band.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-19a` | capped value <= uncapped value and <= value with the stable leg exactly at the ceiling | `SPEC-ORC-004` | reals, ceiling 1e8 | PROVED |
| `MATH-UO-19b` | stable quote <= $1: the ceiling is a no-op (value unchanged) | `SPEC-ORC-004` | reals, ceiling 1e8 | PROVED |
| `MATH-UO-19c` | capped value is monotone non-decreasing in the stable quote (no inversion at the ceiling) | `SPEC-ORC-004` | reals, ceiling 1e8 | PROVED |
| `MATH-UO-20a` | wrong reading (ceiling applied before the TWAP check): GHO just above $1.005 with feeds and pool agreeing deviates > tau = 50 ticks -> false Drifting | `SPEC-ORC-010`, `SPEC-ORC-004`, `SPEC-ORC-003`, `SPEC-ORC-011` | reals and integers, quotes <= 1e12 | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-20b` | final rule (uncapped quotes): a stable at any premium whose pool ratio matches its quotes passes the TWAP comparison for every tau >= 0 | `SPEC-ORC-010`, `SPEC-ORC-004`, `SPEC-ORC-003`, `SPEC-ORC-011` | reals and integers, quotes <= 1e12 | PROVED |
| `MATH-UO-20c` | for a market of two stables, v0*v1 <= 1e16, so the upper bound never trips for any usdBandHigh >= $1 | `SPEC-ORC-010`, `SPEC-ORC-004`, `SPEC-ORC-003`, `SPEC-ORC-011` | reals and integers, quotes <= 1e12 | PROVED |
| `MATH-UO-20d` | the squared integer test low^2 <= q0*q1 is exactly low <= sqrt(q0*q1) (no rounding) | `SPEC-ORC-010`, `SPEC-ORC-004`, `SPEC-ORC-003`, `SPEC-ORC-011` | reals and integers, quotes <= 1e12 | PROVED |
| `MATH-UO-20e` | a stable above peg is tested at the ceiling: q0 > $1 gives v0 = 1e8, so the upper test reads 1e8 * v1 whatever the premium | `SPEC-ORC-010`, `SPEC-ORC-004`, `SPEC-ORC-003`, `SPEC-ORC-011` | reals and integers, quotes <= 1e12 | PROVED |
| `MATH-UO-21` | premium x on one uncapped leg: value rises by factor sqrt(1+x) <= 1 + x/2 | `SPEC-ORC-004` | reals, premium <= 100% | PROVED |

### `uo06_agreement_twap.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-22a` | why the USD band exists: all four routes report k x true (k = 2): agreement and TWAP both pass, collateral overvalued 2x | `SPEC-ORC-003`, `SPEC-ORC-010`, `SPEC-ORC-011`, `MKT-005` | reals, T <= 2%, tau <= 200 ticks | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-22b` | why the two tokens' alternate routes share no intermediate feed: alternates through one shared X/ETH x ETH/USD leg carry the same error k and pass the TWAP gate | `SPEC-ORC-003`, `SPEC-ORC-010`, `SPEC-ORC-011`, `MKT-005` | reals, T <= 2%, tau <= 200 ticks | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-22c` | the USD band catches a downward common-mode error: k < usdBandLow with true prices <= $1 gives sqrt(q0*q1) < usdBandLow | `SPEC-ORC-003`, `SPEC-ORC-010`, `SPEC-ORC-011`, `MKT-005` | reals, T <= 2%, tau <= 200 ticks | PROVED |
| `MATH-UO-23a` | both routes report and alternates are correct (b_i = t_i): served value overvalued by at most factor (1 + T) | `SPEC-ORC-003`, `SPEC-ORC-010`, `SPEC-ORC-011` | reals, T <= 2%, tau <= 200 ticks | PROVED |
| `MATH-UO-23b` | only ONE token mispriced on all its routes (other token correct): TWAP bounds overvaluation by sqrt(g) (~ tau/2 bps) | `SPEC-ORC-003`, `SPEC-ORC-010`, `SPEC-ORC-011` | reals, T <= 2%, tau <= 200 ticks | PROVED |
| `MATH-UO-23c` | why the band is needed besides TWAP: mispricing split between the two tokens in the same direction escapes the TWAP gate even with tau = 0 ticks | `SPEC-ORC-003`, `SPEC-ORC-010`, `SPEC-ORC-011` | reals, T <= 2%, tau <= 200 ticks | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-24a` | wrong reading: deviation computed as floor(\|p-b\|*1e4 / b) <= T passes a deviation the exact rule (cross-multiplied, vs min) rejects | `SPEC-ORC-003` | integers; 24c 256-bit vectors | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-24b` | cross-multiplied rule \|p-b\|*1e4 <= T*min(p,b) is symmetric in (primary, alternate) for every T: both sides are symmetric terms | `SPEC-ORC-003` | integers; 24c 256-bit vectors | PROVED |
| `MATH-UO-24c` | p, b <= MAX_ROUTE_ANSWER and T < 2^16: \|p-b\|*1e4 and T*min(p,b) fit in 256 bits | `SPEC-ORC-003` | integers; 24c 256-bit vectors | PROVED |

### `uo07_cap_counters.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-25a` | capReleased >= 0 and remainingCharge <= currentUsdCharge at every exit (charge monotone in remaining units) | `SPEC-BACK-005`, `SPEC-BACK-004` | integers, U0 < 2^120, V0 < 2^128 | PROVED |
| `MATH-UO-25b` | any split of exits telescopes: released1 + released2 == V0 - c(remaining); a record emptied in two exits releases exactly V0 | `SPEC-BACK-005`, `SPEC-BACK-004` | integers, U0 < 2^120, V0 < 2^128 | PROVED |
| `MATH-UO-25c` | conservative rounding: V0*r/U0 <= remainingCharge < V0*r/U0 + 1 and remainingCharge <= V0 | `SPEC-BACK-005`, `SPEC-BACK-004` | integers, U0 < 2^120, V0 < 2^128 | PROVED |
| `MATH-UO-25d` | slice first: Slice and Regular stay >= 0, the slice drops by min(capReleased, Slice), and Regular + Slice drops by exactly capReleased (saturation never clamps) | `SPEC-BACK-005`, `SPEC-BACK-004` | integers, U0 < 2^120, V0 < 2^128 | PROVED |
| `MATH-UO-25e` | token and depositor counters (>= sum of charges) fall by exactly capReleased; max(counter - capReleased, 0) never clamps | `SPEC-BACK-005`, `SPEC-BACK-004` | integers, U0 < 2^120, V0 < 2^128 | PROVED |
| `MATH-UO-26a` | wrong reading (fixed V0 / current U): two half-slices of a record decrement 1.5 x V0, wiping other records out of the counter | `SPEC-BACK-005` | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-26b` | size of the MATH-UO-26a error for n equal slices | `SPEC-BACK-005` | integers | COMPUTED |
| `MATH-UO-26c` | wrong reading (floor of V0*x/U0 per exit): three 1-unit exits of a 3-unit record leave a residue in the counter | `SPEC-BACK-005` | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-27b` (d=6, d=18) | usdCharge = ceil(c * max(price8, floor) / 10^d) is >= 1, >= the value at price8 and >= the value at the stress floor | `SPEC-BACK-003`, `SPEC-CAP-001`, `MKT-043` | integers, c < 2^120, price8 < 2^64, d in {6,18} | PROVED (2 of 2) |
| `MATH-UO-27c` (d=6, d=18) | pledgeUsd = floor(c * price8 / 10^d) never overstates the pledge (minPledgeUsd test is conservative) | `SPEC-BACK-003`, `SPEC-CAP-001`, `MKT-043` | integers, c < 2^120, price8 < 2^64, d in {6,18} | PROVED (2 of 2) |
| `MATH-UO-27a` (d=18) | wrong reading (floor-rounded charge): a dust pledge at $2 per whole token books 0 and the counters never see it | `SPEC-BACK-003`, `SPEC-CAP-001`, `MKT-043` | integers, c < 2^120, price8 < 2^64, d in {6,18} | COUNTEREXAMPLE, deliberate (1 of 1) |
| `MATH-UO-28a` | wrong reading (Hub cap sized at today's $2 price, charges at the oracle price): pledges at a 5% lower price fill K and leave no Hub room for the slice | `SPEC-UNIT-005`, `SPEC-BACK-003`, `MKT-014` | reals | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-28b` | final rule: charges at max(price, stressFloor) and addCap >= (K + slice) / stressFloor: the Hub never blocks a pledge Avana's caps admit, even at prices below the floor | `SPEC-UNIT-005`, `SPEC-BACK-003`, `MKT-014` | reals | PROVED |
| `MATH-UO-29a` | counter C <= cap K < 2^128 and charge v < 2^128: C + v cannot overflow | `SPEC-BACK-004`, `SPEC-BACK-005`, `SPEC-BACK-013`, `SPEC-BACK-003` | 256-bit vectors | PROVED |
| `MATH-UO-29b` | V0 < 2^128 and remainingUnits < 2^120: V0 * remainingUnits < 2^248 (no mulDiv overflow) | `SPEC-BACK-004`, `SPEC-BACK-005`, `SPEC-BACK-013`, `SPEC-BACK-003` | 256-bit vectors | PROVED |
| `MATH-UO-29c` | c < 2^120 and max(price8, floor) < 2^64: the charge product is below 2^184 | `SPEC-BACK-004`, `SPEC-BACK-005`, `SPEC-BACK-013`, `SPEC-BACK-003` | 256-bit vectors | PROVED |

### `uo08_backing_invariant.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-30a` | pledge: mint exactly L (no conversion) keeps supply == sum credited and l >= c; no overflow | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-30b` | donation (any amount Uniswap accepts) raises l only; credited and supply unchanged; never collateral | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-30c` | partial seizure: burn u == debit u == liquidity removed u (u <= c_r) keeps both invariants; no underflow | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-30d` | full seizure leaves the record open with c_r = 0 and l_r >= 0 (donations stay with the NFT) | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-30e` | withdraw: burning exactly c_r and closing the record keeps supply == sum credited of the rest | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-30f` | partial removal or deleverage release of u <= c_r: burn u == debit u == liquidity removed u keeps both invariants | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-30g` | re-credit: mint added = l_r - c_r and set c_r = l_r keeps supply == sum credited and l_r >= c_r | `SPEC-UNIT-002`, `SPEC-BACK-002`, `SPEC-BACK-009`, `SPEC-BACK-010`, `SPEC-BACK-013` | uint128 / uint256 bit-vectors, l <= maxLiquidityPerTick(1) | PROVED |
| `MATH-UO-31a` | why the equality is checked: burn != debit (e.g. burn what was received, debit what Aave reported) breaks supply == sum credited | `SPEC-BACK-007`, `SPEC-UNIT-002`, `SPEC-BACK-010` | uint128 / uint256 bit-vectors | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-31b` | why the equality is checked: removing more liquidity than debited (u_liq > u_debit) breaks l_r >= c_r when no donation covers it | `SPEC-BACK-007`, `SPEC-UNIT-002`, `SPEC-BACK-010` | uint128 / uint256 bit-vectors | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-32a-i` | lemma: q*M <= k*M < (q+1)*M with M > 0  =>  q <= k < q+1 | `SPEC-BACK-007` | integers, reserve of 1e18 shares | PROVED |
| `MATH-UO-32a` | shares == assets (checked at beginSeizure): received == shares removed and the proxy asset drop == received, so the exact debit check passes | `SPEC-BACK-007` | integers, reserve of 1e18 shares | PROVED |
| `MATH-UO-32b` | why beginSeizure requires shares == assets: with 0.1% drift the received units differ from the proxy's asset drop | `SPEC-BACK-007` | integers, reserve of 1e18 shares | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-32c` | why beginSeizure requires shares == assets: received units differ from the shares removed (a check in shares also fails) | `SPEC-BACK-007` | integers, reserve of 1e18 shares | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-33` | vault-token supply and Hub uint120 shares cannot overflow for standard fee tiers | `SPEC-UNIT-006`, `SPEC-BACK-009` | exact integers | COMPUTED |

### `uo09_backing_gap.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-34a` | Adapter call (mint or burn m with the matching credit change, reconcile s): gap unchanged and Y <= TC + P holds after | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-34b` | orphan burnSeized of u units never settled: gap grows by u and stays >= 0 (more backing than units) | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-34c` | settleSeizure u after the measured burn of u: gap unchanged | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-34d` | settlePending x with any burn b that passes Y + x <= TC + P: gap after >= 0, so pool tokens never leave for units still in circulation | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-34e` | with a conforming LPVaultSwap (gap 0) the check proves the call burned at least x units | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-34f` | after an orphan burn (gap = g > 0) a settlement of x <= g with no burn passes and leaves gap - x >= 0 | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-34g` | with no orphan burn the gap stays 0: a sequence Adapter call, settleSeizure u, settlePending x with burn x keeps gap == 0 | `SPEC-BACK-009`, `REQ-VTOKEN-016`, `SPEC-BACK-007`, `SPEC-BACK-012` | unbounded integers | PROVED |
| `MATH-UO-35` | wrong reading (Adapter requires Y == TC + P): after one orphan burn every later pledge in the market reverts | `SPEC-BACK-009`, `REQ-VTOKEN-016` | unbounded integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-36a` | release / releasePartial / releaseForDeleverage: S = shares after the withdrawal + units gives shortfall == unsettled seized units | `SPEC-BACK-011`, `SPEC-BACK-007` | unbounded integers | PROVED |
| `MATH-UO-36b` | releaseZeroCredit / recredit: S = current shares gives shortfall == unsettled seized units | `SPEC-BACK-011`, `SPEC-BACK-007` | unbounded integers | PROVED |
| `MATH-UO-36c` | settleSeizure: S = sharesBefore gives the earlier unsettled units, reconciled before the current seizure k is debited | `SPEC-BACK-011`, `SPEC-BACK-007` | unbounded integers | PROVED |
| `MATH-UO-36d` | a proxy supply above its credited units (unreachable) gives shortfall 0: the max(., 0) form is a no-op | `SPEC-BACK-011`, `SPEC-BACK-007` | unbounded integers | PROVED |
| `MATH-UO-37a` | partial settlement pays out <= its pro-rata share and leaves the remaining units backed by at least their share | `SPEC-BACK-012` | integers, amount < 2^128 | PROVED |
| `MATH-UO-37b` | two settlements (x1 then the rest) pay exactly the pending amount: no pool token is stranded | `SPEC-BACK-012` | integers, amount < 2^128 | PROVED |
| `MATH-UO-37c` | three settlements: the second floor payout also stays within the remainder; the final pays exactly what is left | `SPEC-BACK-012` | integers, amount < 2^128 | PROVED |
| `MATH-UO-38a` | debit u <= sum credited: takes sum to u (rem == 0) and each take <= its credited units | `SPEC-BACK-006` | integers, three records | PROVED |
| `MATH-UO-38b` | only the last record touched is partially debited: an earlier record is either untouched or emptied | `SPEC-BACK-006` | integers, three records | PROVED |
| `MATH-UO-38c` | a debit above the account-market's credited units leaves rem > 0, so the call reverts | `SPEC-BACK-006` | integers, three records | PROVED |

### `uo10_rebase_rescue.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-39a` | the record releases V0 - c_b before the re-credit and C0' after it: V0 + usdCharge over its life, exactly what was booked | `SPEC-BACK-013`, `SPEC-BACK-005` | unbounded integers | PROVED |
| `MATH-UO-39b` | after the rebase: remainingCharge <= C0', capReleased >= 0, and the last exit (remainingUnits = 0) leaves 0 | `SPEC-BACK-013`, `SPEC-BACK-005` | unbounded integers | PROVED |
| `MATH-UO-39c` | c_b = ceil(V0 * u_b / U0) <= V0, so the rebased charge C0' <= V0 + usdCharge and stays < 2^128 when both are below 2^127 | `SPEC-BACK-013`, `SPEC-BACK-005` | unbounded integers | PROVED |
| `MATH-UO-39d` | the record stores charges as uint64: with V0 < 2^64 and usdCharge < 2^64 the rebased C0' is below 2^65, so the sum never overflows and the InvalidCharge check C0' < 2^64 is the only bound a re-credit adds | `SPEC-BACK-013`, `REQ-VAULT-110` | unbounded integers | PROVED |
| `MATH-UO-40a` | rescueUnits <= L, = L when rescue, and >= L * sliceUsd / usdCharge (rounding up excludes at least the slice share) | `SPEC-BACK-014`, `REQ-COLL-016` | unbounded integers | PROVED |
| `MATH-UO-40b` | pledge or re-credit of L units adds rescueUnits <= L and L credited: rescueUnits <= credited is kept | `SPEC-BACK-014`, `REQ-COLL-016` | unbounded integers | PROVED |
| `MATH-UO-40c` | any debit followed by rescueUnits = min(rescueUnits, credited) keeps 0 <= rescueUnits <= credited and never lowers rescue units that still fit | `SPEC-BACK-014`, `REQ-COLL-016` | unbounded integers | PROVED |
| `MATH-UO-40d` | per-account sum: accountRescueUnits = sum of record rescue units <= accountCredited | `SPEC-BACK-014`, `REQ-COLL-016` | unbounded integers | PROVED |
| `MATH-UO-41` | Regular + Slice rise by exactly usdCharge, each by a non-negative part; token0, token1 and depositor rise by usdCharge | `SPEC-BACK-004` | unbounded integers | PROVED |

### `uo11_oracle_states.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-42a` | lemma: the floored square root is monotone (X1 <= X2 => isqrt(X1) <= isqrt(X2)) | `SPEC-ORC-008`, `SPEC-ORC-017`, `SPEC-ORC-004`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-42b` | lemma: 1 <= w_i <= v_i => 4*w0*w1 <= 4*v0*v1 | `SPEC-ORC-008`, `SPEC-ORC-017`, `SPEC-ORC-004`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-42c` | lemma: the disagreement price w = ceil(min(p, b)) is <= the valuation price v = ceil(q) for either quote route, and >= 1 | `SPEC-ORC-008`, `SPEC-ORC-017`, `SPEC-ORC-004`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-42d` | served >= 1 in every state; served <= A whenever the state is not Live; served <= fresh whenever not failed (Live, Drifting, disagreement) | `SPEC-ORC-008`, `SPEC-ORC-017`, `SPEC-ORC-004`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-42e` | fresh and lower are >= 1: prices >= 1 give isqrt(4*x0*x1) >= 2, so price8 >= 1 | `SPEC-ORC-008`, `SPEC-ORC-017`, `SPEC-ORC-004`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-43a` | served debt price >= 1 always, >= A whenever the state is not Live (debt that cannot be priced never counts lower) | `SPEC-ORC-018` | integers, A <= 1e12, delta in [100, 5000] | PROVED |
| `MATH-UO-43b-i` | lemma: 100 <= delta <= 5,000 and A >= 1 give 10,100*A <= A*(10^4 + delta) <= 15,000*A | `SPEC-ORC-018` | integers, A <= 1e12, delta in [100, 5000] | PROVED |
| `MATH-UO-43b` | Expired value ceil(A*(10^4+delta)/10^4) is strictly above A and never exceeds 1.5 * A + 1 | `SPEC-ORC-018` | integers, A <= 1e12, delta in [100, 5000] | PROVED |
| `MATH-UO-43c` | A <= MAX_ROUTE_ANSWER keeps A * (10^4 + delta) < 2^256 | `SPEC-ORC-018` | integers, A <= 1e12, delta in [100, 5000] | PROVED |
| `MATH-UO-43d` | the DebtOracle reads any uint16 stress rise into [100, 5,000] (min(max(read, 100), 5,000)), so MATH-UO-43b-i and -43b keep the Expired value in (A, 1.5 * A + 1] whatever the store returns | `SPEC-ORC-018`, `REQ-ORACLE-092` | integers, read in [0, 65,535] | PROVED |
| `MATH-UO-43e` | wrong reading (review DO-03): the lower bound alone; a store returning 65,535 bps serves ceil(A * 75,535 / 10^4) = 755,274,465 > 1.5 * A + 1 for A = 99,990,000 | `SPEC-ORC-018` | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-67` | while the routes disagree the reported route is the one whose value max(p, b, A) serves: the alternate serves b, the primary p, and none serves A, so the timestamp, legs and age limits always describe the served value | `SPEC-ORC-012`, `SPEC-ORC-015`, `SPEC-ORC-018`, `REQ-ORACLE-093` | integers, p ≠ b | PROVED |
| `MATH-UO-44a` | both routes stale: the market is Expired at every now >= staleAt + cachedWindow, whatever failedSince or the poke time | `SPEC-ORC-013` | integers (seconds) | PROVED |
| `MATH-UO-44b` | a late or missed poke can only report Expired earlier: failureStart <= staleAt and <= now | `SPEC-ORC-013` | integers (seconds) | PROVED |
| `MATH-UO-44c` | staleFrom is the first failed second: a leg updated at u with feedMaxAge m is valid at u + m and stale at u + m + 1 | `SPEC-ORC-013` | integers (seconds) | PROVED |
| `MATH-UO-45a` | pauseActive and disagreementExpired never both hold, and every disagreement blocks this market's seizure (liquidationPaused) | `SPEC-ORC-016`, `REQ-ORACLE-095` | integers (seconds) | PROVED |
| `MATH-UO-45b` | a disagreement first seen now (disagreeSince = 0, or a route-version change that reads it as 0) is in its pause window when pauseMax ≥ 1 | `SPEC-ORC-016`, `REQ-ORACLE-095` | integers (seconds) | PROVED |
| `MATH-UO-45c` | with pauseMax = 0, a disagreement read with disagreeSince = 0 is disagreementExpired, so liquidationPaused holds | `SPEC-ORC-016`, `REQ-ORACLE-095` | integers (seconds) | PROVED |
| `MATH-UO-46a` | maxAge() = deadline - servedUpdatedAt >= 0 (no underflow) and the consumer test now - servedUpdatedAt <= maxAge holds iff every leg is within its own limit | `SPEC-ORC-015`, `SPEC-ORC-012` | integers, three legs | PROVED |
| `MATH-UO-46b` | an alternate leg is held to min(liquidation age, borrow age): its liquidation limit never exceeds its borrow limit | `SPEC-ORC-015`, `SPEC-ORC-012` | integers, three legs | PROVED |
| `MATH-UO-47a` | the fallback prev (stored timestamp, never later than the true previous round) only lengthens the measured gap: same end, earlier or equal start | `SPEC-ORC-014` | integers (seconds) | PROVED |
| `MATH-UO-47b` | an outage that reached Expired by the true timestamps is also detected with the fallback, with the same end E_i (recoveredAt) | `SPEC-ORC-014` | integers (seconds) | PROVED |
| `MATH-UO-48a` | f > 8: n = floor(a / 10^(f-8)) satisfies n * 10^(f-8) <= a < (n+1) * 10^(f-8): rounded down, never above the feed | `SPEC-ORC-001`, `SPEC-ORC-002`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-48b` | two-leg route r = mulDiv(aA, aB, 10^(fA+fB-8)) floors: r <= aA*aB/10^k < r + 1 | `SPEC-ORC-001`, `SPEC-ORC-002`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-48c` | route timestamp = oldest leg and servedUpdatedAt = oldest route: the served age is never understated | `SPEC-ORC-001`, `SPEC-ORC-002`, `SPEC-ORC-012` | integers | PROVED |
| `MATH-UO-49` | a switch to a standby that is also stale never delays Cached or Expired: failureStart after the switch <= the stored failedSince | `REQ-ORACLE-095`, `SPEC-ORC-013` | integers (seconds) | PROVED |

### `uo12_amm_neutral_oracle.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-50a` | per-feed limits: maxAge = deadline − servedUpdatedAt ≥ 0, and now − servedUpdatedAt ≤ maxAge iff every leg is within its own heartbeat + margin | `SPEC-ORC-019`, `SPEC-ORC-015`, `REQ-ORACLE-002`, `REQ-ORACLE-054` | integers, three legs, heartbeats ≤ 86,400 | PROVED |
| `MATH-UO-50b` | wrong reading (old `min(heartbeat + 600, 4,200)`): a 86,400 s stable feed operating normally at age 13,500 s is refused | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-50c` | launch feed limits with a 1,800 s margin, and the `SPEC-ORC-015` example (50,400 s) | same | exact integers | COMPUTED |
| `MATH-UO-51a` | each floored amount within one raw unit above the exact amount: `(a_i − 1)⁺` valued at any prices never exceeds the exact composition value | `SPEC-ORC-006`, `SPEC-ORC-008`, `SPEC-ORC-005`, `REQ-ORACLE-012`, `REQ-ORACLE-050` | reals and integers | PROVED |
| `MATH-UO-51b` | above the range the unclamped token1 amount `L(sP − sa)` exceeds the true holding `L(sb − sa)` | same | reals | PROVED |
| `MATH-UO-51c` | exact-integer sampling (400 draws of range, spacing, decimals, prices $0.90–$1.10, `d` by `SPEC-ORC-005`): price8 ≤ exact fair value at the exact oracle price in every sample; RT-02 example ×2.989 unclamped; worked examples 951,956,208, 999,630,568, 199,999,799 | same | exact integers, 80-digit decimals | COMPUTED |
| `MATH-UO-52` | the composition value is non-decreasing in each price, so the stable ceiling and the lower route only lower price8 | `SPEC-ORC-007`, `SPEC-ORC-004`, `SPEC-ORC-017` | reals, minimum property instantiated | PROVED |
| `MATH-UO-53a` | n = 2: the exact band test implies the fixed-point test | `SPEC-ORC-011`, `REQ-ORACLE-015` | integers ≤ 10^12 | PROVED |
| `MATH-UO-53b` | n = 2: the fixed-point test passing implies `low² < q0·q1 + 10^8` | same | integers ≤ 10^12 | PROVED |
| `MATH-UO-53c` | n = 3: the left-to-right fixed-point product is within `qc/10^8 + 1` below the exact product / 10^16 | same | integers ≤ 10^12 | PROVED |
| `MATH-UO-53d` | band examples of `SPEC-ORC-011` | same | exact integers | COMPUTED |
| `MATH-UO-54a` | second-source test is symmetric in (quote, second source) | `SPEC-ORC-020`, `REQ-ORACLE-100` | integers ≤ 10^12, S < 2^16 | PROVED |
| `MATH-UO-54b` | both sides of the second-source test fit 256 bits | same | same | PROVED |
| `MATH-UO-54c` | `SPEC-ORC-020` example | same | exact integers | COMPUTED |
| `MATH-UO-55a` | borrowAllowed implies no sequencer feed, or up for at least the grace period | `SPEC-ORC-021`, `REQ-ORACLE-099`, `REQ-ORACLE-034`, `SPEC-ORC-016` | integers and booleans | PROVED |
| `MATH-UO-55f` | borrowAllowed on an L2 implies the served price comes from rounds newer than the sequencer's restart (`servedUpdatedAt > startedAt`) | same | same | PROVED |
| `MATH-UO-55g` | a chain without a sequencer feed is unchanged: borrowing is not gated on the round time | same | same | PROVED |
| `MATH-UO-55h` | wrong reading (the grace period alone): past the grace period a price from a round before the restart would admit a borrow | same | same | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-55b` | sequencer down: seizure paused and borrowing blocked | same | same | PROVED |
| `MATH-UO-55c` | an unreadable or unexpected uptime feed blocks borrowing but never pauses seizure by itself | same | same | PROVED |
| `MATH-UO-55d` | while the sequencer is up, exactly one of grace and ready holds | same | same | PROVED |
| `MATH-UO-55i` | an uptime answer that is not exactly 160 bytes is unknown: borrowing blocked and seizure not paused by it, whatever its words report | same | same | PROVED |
| `MATH-UO-55j` | wrong reading (any answer of at least 160 bytes decoded from its first five words): a 192-byte answer whose words report down pauses seizure | same | same | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-55e` | Base restart example, with the restart rule (a round of 1,009,000 or 1,010,000 keeps borrowing closed at 1,013,600; a round of 1,013,000 opens it) | same | exact integers | COMPUTED |
| `MATH-UO-56a` | `k = ⌈W / blockTime⌉ + 1` observations written one per block span `(k − 1)·blockTime ≥ W` | `SPEC-ORC-022`, `REQ-ORACLE-055` | integers, W, blockTime > 0 | PROVED |
| `MATH-UO-56b` | wrong reading: a 12 s-sized buffer (151) on 2 s blocks spans 300 s < 1,800 s | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-56c` | per-chain buffers for W = 1,800: Ethereum 151, Base 901 | same | exact integers | COMPUTED |
| `MATH-UO-57a` | pre-call check `gasleft ≥ ⌈64G/63⌉ + post`: the read receives exactly `G` | `SPEC-ORC-023`, `REQ-ORACLE-102`, `REQ-ORACLE-024`, `REQ-ORACLE-039`, `REQ-ORACLE-038` | integers, EVM 63/64 forwarding | PROVED |
| `MATH-UO-57b` | wrong reading (only `gasleft ≥ pokeMinGas` after the catch): a starved read is accepted as a feed failure | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-57c` | entry gas at `max(W_poke, max_k(u_k + ⌈64 G_k / 63⌉ + POST_CALL_GAS))`: every pre-call check passes and the whole poke fits | same | integers, three reads at `u_1 ≤ u_2 ≤ u_3 ≤ W_poke` | PROVED |
| `MATH-UO-57e` | the per-read floor is at most `W_poke + ⌈64 G_max / 63⌉ + POST_CALL_GAS` with `G_max` the largest `G_k` (the 1.5 single-term bound) | same | integers, three reads | PROVED |
| `MATH-UO-57d` | `SPEC-ORC-023` example: 55,794; `G_inputs(2) = 430,000` with bound 441,826; measured worst-case two-token poke with the token-decimals reads of `REQ-ORACLE-107`: `W_poke = 830,781`, binding feed read at `u = 718,836` gives 774,630, floor 830,781; `POKE_MIN_GAS_FLOOR = 900,000` leaves 69,219 gas until the fork calibration | same | exact integers | COMPUTED |
| `MATH-UO-57f` | two gas limits at which a read passes its pre-call check forward the same `G` to it, so a completed poke computes the same failure, timers and decimals result at any limit, and a limit short of a check reverts before the read | same | integers, EVM 63/64 forwarding | PROVED |
| `MATH-UO-57g` | the entry check measures gas left at the implementation: a proxy keeping 1/64 and spending `o ≥ 0` first leaves at most the caller's limit, so a transaction must cover `pokeMinGas` plus the work before the check | same | integers | PROVED |
| `MATH-UO-72a` | `borrowAllowed` implies every token confirmed and a token-decimals verification at most 7,200 s old | `REQ-ORACLE-107`, `REQ-ORACLE-100`, `SPEC-ORC-020`, `REQ-ORACLE-016` | integers and booleans | PROVED |
| `MATH-UO-72b` | a decimals mismatch fails the market: borrowing and this market's seizure are both blocked | same | same | PROVED |
| `MATH-UO-72c` | an unconfirmed token or an old verification blocks borrowing only: state and seizure pause are those of the same evaluation with every token confirmed and a fresh verification | same | same | PROVED |
| `MATH-UO-72d` | with a successful poke at least every keeper interval of at most 3,600 s, the 7,200 s gate never blocks (one missed run tolerated) | same | integers | PROVED |
| `MATH-UO-72e` | delayed detection: a view between a token's change and the next poke still uses the stored decimals; a risk-increasing call pokes first, so its window is empty | same | integers | COUNTEREXAMPLE (deliberate: the stated detection window) |
| `MATH-UO-72f` | `REQ-ORACLE-107` example: borrowing allowed at 8,200, not at 8,201; a change found at 1,060 is Cached until 4,659, Expired from 4,660 | same | exact integers | COMPUTED |

### `uo13_lppricemath_inputs.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-58a` | a signed answer in `(0, 2^128)` times `10^8` never overflows 256 bits | `SPEC-ORC-001`, `SPEC-ORC-002`, `REQ-ORACLE-002`, `REQ-ORACLE-049` | 256-bit bit-vectors | PROVED |
| `MATH-UO-58b` | `0 < aA, aB < 2^128` keeps `aA · aB < 2^256`, so the route's `mulDiv` never reverts | same | integers | PROVED |
| `MATH-UO-58c` | wrong reading (old bound `aA, aB < 2^255`): the `mulDiv` result can need more than 256 bits | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-58d` | wrong reading (unsigned input): a negative answer cast to `uint256` normalises from 18 decimals to more than `10^60` | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-58e` | every answer below `2^128` floors to 0 once `f ≥ 47` | same | exact integers | COMPUTED |
| `MATH-UO-59a` | `max(1, min(lower, fresh, A))` is ≥ 1, ≤ fresh and ≤ A | `SPEC-ORC-017`, `REQ-ORACLE-086`, `REQ-ORACLE-020`, `INV-087` | integers | PROVED |
| `MATH-UO-59b` | wrong reading (`min(lower, A)`): a floored lower price above fresh is served above fresh | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-59c` | full-range USDC/USDT, `d = 6`: `w ≤ v` gives lower 194,928,172 above fresh 194,928,113, both below the exact value 194,928,473 | same | exact integers, 80-digit decimals | COMPUTED |
| `MATH-UO-60a` | deviation: unsaturated, `\|x − y\| · 10^4` fits 256 bits and the floor is exact | `REQ-ORACLE-042`, `SPEC-ORC-003`, `SPEC-ORC-020` | integers ≤ `2^256 − 1` | PROVED |
| `MATH-UO-60b` | deviation saturates only when `\|x − y\| · 10^4` really needs more than 256 bits | same | same | PROVED |
| `MATH-UO-60c` | agreement inside `[1, MAX_ROUTE_ANSWER]` fits 256 bits; outside it is false for every input | same | integers, `T < 2^16` | PROVED |
| `MATH-UO-61a` | n = 2: `L ↦ L^⊗2` is non-decreasing | `SPEC-ORC-011`, `REQ-ORACLE-042` | integers ≤ 10^12 | PROVED |
| `MATH-UO-61b` | one `⊗` step: the raw products are ordered when both arguments grow | same | integers | PROVED |
| `MATH-UO-61c` | the saturating floor of a step keeps that order, so `L ↦ L^⊗n` is non-decreasing for every n | same | integers ≤ `2^256 − 1` | PROVED |
| `MATH-UO-61d` | the left-to-right product is non-decreasing in each argument, so `(min q)^⊗n ≤ ⊗q ≤ (max q)^⊗n` bound the search | same | integers ≤ 10^12, n = 3 | PROVED |
| `MATH-UO-61e` | n = 2: `usdBandLow ≤ usdLevel` iff `usdBandLow^⊗2 ≤ ⊗q` | same | integers ≤ 10^12 | PROVED |
| `MATH-UO-61f` | wrong reading (real root `⌊(P · 10^8)^(1/2)⌋`): the level sits below `usdBandLow` while the band passes | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-61g` | `usdLevel` of the `SPEC-ORC-011` examples: 99,998,499, 89,000,000, 99,990,000, and 90,000,001 for `(81,000,001, 10^8)` | same | exact integers | COMPUTED |
| `MATH-UO-61h` | every n: with the monotone power, `usdBandLow ≤ usdLevel` iff `usdBandLow^⊗n ≤ ⊗q` | same | integers | PROVED |
| `MATH-UO-62a` | eight quotes at `MAX_ROUTE_ANSWER` keep every intermediate below `2^256`: valid quotes never saturate | `SPEC-ORC-011` | exact integers | COMPUTED |
| `MATH-UO-62b` | sticky saturation: a saturated factor gives a saturated product; an unsaturated product is the exact floor and never `2^256 − 1` | same | integers | PROVED |
| `MATH-UO-62c` | wrong reading (non-sticky): a saturated product times 1 drops below the saturation value | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-63` | the fixed-point product depends on the order of its factors: 91,459,272 in pool order, 91,459,273 reversed, against `97,067,963^⊗3 = 91,459,273` | same | exact integers | COMPUTED |
| `MATH-UO-64` | with `a_i < 2^128` and `v_i ≤ MAX_ROUTE_ANSWER`, each term is below `2^168` and eight below `2^171` | `SPEC-ORC-008`, `REQ-ORACLE-103` | integers | PROVED |
| `MATH-UO-65` | Expired debt price with `δ` read as `max(δ, 100)` is ≥ `A + 1`; the saturated value is above `A` | `SPEC-ORC-018`, `REQ-ORACLE-093`, `INV-087` | integers ≤ `2^256 − 1` | PROVED |
| `MATH-UO-66a` | no route timestamps gives age 0 that every check refuses; a zero block time asks for `2^256 − 1` observations | `SPEC-ORC-012`, `SPEC-ORC-015`, `SPEC-ORC-022`, `SPEC-ORC-023`, `REQ-ORACLE-038`, `REQ-ORACLE-102` | integers | PROVED |
| `MATH-UO-66b` | one read's term `u_k + ⌈64G_k/63⌉ + POST_CALL_GAS` (`LPPriceMath.pokeMinGasFloor(u_k, G_k)`): the read's pre-call check passes after `u_k` of work | same | integers | PROVED |
| `MATH-UO-66c` | wrong reading (term without `POST_CALL_GAS`): read `k` fails its own pre-call check | same | integers | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-66d` | floor example with the token-decimals reads of `REQ-ORACLE-107`: binding read 718,836 + 50,794 + 5,000 = 774,630, `W_poke` 830,781, floor 830,781; configuration read bound 441,826 | same | exact integers | COMPUTED |

### `uo14_tolerance_standby.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-68a` | a stored tolerance `T ≥ max(dP + dA, dS + dA, dP + dS) + m` meets `d1 + d2 + m` for every route pair a standby switch can put in force | `REQ-CONFIG-024`, `REQ-MREG-027` | integers ≤ 10^4 bps | PROVED |
| `MATH-UO-68b` | the bound equals the in-force bound of one of the three pairs, so it is the least such value | same | same | PROVED |
| `MATH-UO-68c` | wrong reading (bound over the routes in force only): 25/25/120 bps with `m = 50` passes at `T = 100`, then the standby in place of the primary needs 195 | `REQ-CONFIG-024` | same | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-68d` | with no standby (`dS = 0`) the bound is `dP + dA + m` | `REQ-CONFIG-024` | same | PROVED |
| `MATH-UO-69` | examples: 25/25/25 → 100; 25/25/120 → 195; 40/25/120 → 210; USDC 25 / 150 / 25 → 225 | `REQ-CONFIG-024` | exact integers | COMPUTED |

### `uo15_debt_mark_seizure_order.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-70a` | a failed `markDebtFree` read that leaves at least `DEBT_MARK_GAS_FLOOR = 50,000` gas was given at least 63 × 50,000 = 3,150,000 (EIP-150: the read gets `A − ⌊A/64⌋`, an out-of-gas read leaves `⌊A/64⌋`) | `REQ-COLL-040` | integers | PROVED |
| `MATH-UO-70b` | a starved read whose cost is at most 3,150,000 leaves under 50,000, so the call reverts `InsufficientGas` instead of keeping the mark | `REQ-COLL-040` | same | PROVED |
| `MATH-UO-70c` | wrong reading (floor 1,000): a 600,000-gas read starved at 500,000 leaves over 1,000 gas and would keep the mark | `REQ-COLL-040` | same | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-71a` | the same units debited from either of two records release different charges when their bases differ, so the stored order decides the cap room released | `SPEC-BACK-006`, `SPEC-BACK-005` | integers | COUNTEREXAMPLE (deliberate: the stated per-record effect) |
| `MATH-UO-71b` | with equal bases and equal credit the release does not depend on the order | `SPEC-BACK-006`, `SPEC-BACK-005` | integers | PROVED |
| `MATH-UO-71c` | debiting a record without rescue units leaves the account's rescue units unchanged; debiting one with rescue units can only lower them, to `min(rescue, credit after)` | `SPEC-BACK-006`, `SPEC-BACK-014` | integers | PROVED |
| `MATH-UO-71d` | `SPEC-BACK-006` example: NFT 42 at the head releases 200,000,000,000 ($2,000) for a 1,000,000,000-unit debit | `SPEC-BACK-006` | exact integers | COMPUTED |

### `uo16_sequencer_twap_grace.py`

| ID | Statement | Verifies | Assumptions / bounds | Result |
|---|---|---|---|---|
| `MATH-UO-73a` | with `G ≥ max(Wm, Ws, Wb)`, every window read once borrowing reopens (`t ≥ t0 + G`) starts at or after the restart, so no consistency check and no recorded or standby pool-TWAP second source averages the outage | `REQ-PSTORE-034`, `SPEC-ORC-021` | integers, `G ≤ 7,200` | PROVED |
| `MATH-UO-73b` | wrong reading (grace checked against the market window only): `G = Wm = 1,800` and a 2,400 s standby read 600 s of the outage at the first borrow | `REQ-PSTORE-034` | same | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-73c` | the rule is inductive: each setter that writes one side and checks the rule after its write (`setSequencer`, `setTwapWindow`, `setInitialMarketParams`, `setSecondSource`), and a guardian switch or restore that moves no window, keeps it or reverts | `REQ-PSTORE-034` | same | PROVED |
| `MATH-UO-73d` | wrong reading (`setSecondSource` checks only the recorded window): a 3,601 s standby under a 3,600 s grace breaks the rule with no setter reverting | `REQ-PSTORE-034` | same | COUNTEREXAMPLE (deliberate) |
| `MATH-UO-73e` | every window up to 7,200 s has a grace in `[600, 7,200]` covering it (`max(600, W)`), so the rule never makes a valid window unlistable | `REQ-PSTORE-034`, `REQ-PSTORE-023` | integers | PROVED |
| `MATH-UO-74` | `REQ-PSTORE-034` example: with a 1,800 s market window and a 2,400 s standby, `setSequencer` 2,399 reverts, 2,400 passes, then `setTwapWindow` 2,401 reverts; the launch values (3,600 s grace, 1,800 s window) pass | `REQ-PSTORE-034` | exact integers | COMPUTED |

## Findings

No check in this folder finds a defect in the final spec. All 41 counterexamples are deliberate (24 in `uo01`…`uo11`, 6 in `uo12`, 6 in `uo13`, 1 in `uo14`, 2 in `uo15`, 2 in `uo16`): wrong readings the final rules replace (an unsigned answer, a sequencer grace checked against the market window only or the recorded second-source window only, a tolerance bound over the routes in force only, the `2^255` route bound, a disagreement price without `fresh`, the real-root USD level, non-sticky saturation, a poke floor without `POST_CALL_GAS`, odd decimal sums, no `num ≥ 2^64·den` pre-check, saturation at `MAX_SQRT_RATIO − 1` from `2^64`, a served price without the extra unit, the ceiling applied before the TWAP check, floor-division agreement, per-exit floor releases, a floor-rounded charge, a Hub cap sized at today's price, any-equality backing, unequal burn and debit, a view inside the stated token-decimals detection window, a sequencer answer of any length of at least 160 bytes decoded from its first five words) or cases outside a stated bound (deep depeg, non-standard tick spacing, overflow without listing bounds, common-mode errors that the USD band and the separate alternate feeds address, Hub share drift that `beginSeizure` rejects).

## Results

| Date | Command | Versions | Bounds | Proved | Counterexample | Computed | Timeout | Exit |
|---|---|---|---|---|---|---|---|---|
| 2026-11-10 | `../../.venv/bin/python <file>.py` for `uo01` … `uo11` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 149 | 22 (all deliberate) | 8 | 0 | 0 for every script |
| 2026-11-10 (AMM-neutral oracle) | `../../.venv/bin/python <file>.py` for `uo01` … `uo12` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 166 | 25 (all deliberate) | 15 | 0 | 0 for every script |
| 2026-11-10 (LPPriceMath input bounds) | `../../.venv/bin/python <file>.py` for `uo12`, `uo13` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 33 | 9 (all deliberate) | 13 | 0 | 0 for both scripts |
| 2026-11-11 (`SPEC-ORC-009` root above 2^64) | `../../.venv/bin/python uo03_sqrtprice_from_feeds.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 19 | 3 (all deliberate) | 3 | 0 | 0 |
| 2026-11-11 (LPOracle price-read gas: per-read poke floor, `G_inputs`) | `../../.venv/bin/python uo12_amm_neutral_oracle.py`, then `../../.venv/bin/python uo13_lppricemath_inputs.py`, one at a time | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | uo12 17, uo13 17 | uo12 3, uo13 6 (all deliberate) | uo12 7, uo13 6 | 0 | 0 for both scripts |
| 2026-11-11 (DebtOracle review: stress clamp, served route) | `../../.venv/bin/python uo11_oracle_states.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 25 | 1 (deliberate) | 0 | 0 | 0 |
| 2026-11-11 (ParameterStore fixes: tolerance bound over the standby) | `../../.venv/bin/python uo14_tolerance_standby.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 3 | 1 (deliberate) | 1 | 0 | 0 |
| 2026-11-11 (Collateralization fixes: `markDebtFree` gas floor, seizure-order effect) | `../../.venv/bin/python uo15_debt_mark_seizure_order.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 4 | 2 (deliberate) | 1 | 0 | 0 |
| 2026-11-11 (LPOracle token-decimals verification, second-source confirmation, poke floor 900,000) | `../../.venv/bin/python uo12_amm_neutral_oracle.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 23 | 4 (all deliberate) | 8 | 0 | 0 |
| 2026-11-11 (sequencer restart rule: a borrow needs a round newer than the restart) | `../../.venv/bin/python uo12_amm_neutral_oracle.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 25 | 5 (all deliberate) | 8 | 0 | 0 |
| 2026-11-11 (ParameterStore: sequencer grace covers every TWAP window) | `../../.venv/bin/python uo16_sequencer_twap_grace.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 3 | 2 (deliberate) | 1 | 0 | 0 |
| 2026-11-11 (sequencer answer of exactly 160 bytes) | `../../.venv/bin/python uo12_amm_neutral_oracle.py` | Python 3.9.6, z3-solver 4.13.0 | as in the property tables; 120 s per query | 26 | 6 (all deliberate) | 8 | 0 | 0 |

Per script: `uo01` 14 / 4 / 3, `uo02` 31 / 0 / 1, `uo03` 19 / 3 / 3 (since 2026-11-11, with the root above 2^64 of `SPEC-ORC-009`), `uo04` 10 / 2 / 1, `uo05` 8 / 1 / 0, `uo06` 5 / 4 / 0, `uo07` 13 / 4 / 1, `uo08` 9 / 4 / 1, `uo09` 17 / 1 / 0, `uo10` 8 / 0 / 0, `uo11` 25 / 1 / 0 (since 2026-11-11, with the DebtOracle stress clamp and served route), `uo12` 26 / 6 / 8 (since 2026-11-11, with `MATH-UO-57f`, `57g`, `72`, the restart rule `55f` to `55h` and the exact-length read `55i`, `55j`), `uo13` 17 / 6 / 6, `uo14` 3 / 1 / 1, `uo15` 4 / 2 / 1, `uo16` 3 / 2 / 1 (proved / counterexample / computed; `MATH-UO-45c` added on 2026-11-10 with the final `SPEC-ORC-016`; `uo13` added on 2026-11-10 with the LPPriceMath input bounds, the fixed-point USD level and the disagreement price `min(lower, fresh, A)`; it takes about 2 minutes). The slowest script, `uo01`, takes about 26 s.
