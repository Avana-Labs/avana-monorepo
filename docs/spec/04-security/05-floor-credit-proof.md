# 4.5 Floor Credit Proof

> **Status:** Draft · **Owner:** Avana Labs · **Last reviewed:** 2026-11-18

A band market accepts any concentrated-liquidity position that sits fully inside its band of ticks `[A, B]`, and credits it a fixed number of **band units**, where one band unit is one unit of liquidity spread over the whole band. The credit is computed once, at pledge, by [`FloorCreditMath`](../../../contracts/src/custody/lp-vault/libraries/FloorCreditMath.sol), and reads no pool price. It is what the position holds at each band edge divided by what one band unit holds there, the lesser of the two, which is

```
credit = L · min(r0, r1)
r0 = (1/√a − 1/√b) / (1/√A − 1/√B)        token0 side
r1 = (√b − √a)     / (√B − √A)            token1 side
```

for a position of liquidity `L` on the ticks `[a, b]` with `A ≤ a < b ≤ B`. Here and below `√x` is the square-root price of tick `x` as Uniswap's `TickMath` returns it (Q64.96; the scale `2^96` cancels in both ratios). This page proves three facts:

1. **Floor.** At every pool price, the position is worth at least `credit` band units.
2. **Edge minimum.** The least ratio of the two values, over all prices, is reached at a band edge (and at every price outside the band).
3. **Partial liquidation.** Unwinding from the position the liquidity worth the seized credit, at the oracle price, leaves remaining floor credit at least the remaining credit.

It then states what the integer code adds (rounding) and how each fact is established.

## Notation

Write `x = √a, y = √b, X = √A, Y = √B`, so `0 < X ≤ x < y ≤ Y`, and let `s > 0` be the square root of the pool price (token1 per token0). Uniswap's amounts for liquidity `L` on `[x, y]` at `s` are

| price | amount0 | amount1 |
|---|---|---|
| `s ≤ x` | `L (1/x − 1/y)` | `0` |
| `x < s < y` | `L (1/s − 1/y)` | `L (s − x)` |
| `s ≥ y` | `0` | `L (y − x)` |

and their value in token1 is `amount1 + s²·amount0`. For one unit of liquidity on `[x, y]` this value is

```
V_[x,y](s) = ∫_x^y h_s(u) du,      h_s(u) = min(1, s²/u²)
```

(check: for `s ≥ y` every `u ≤ s`, so `h = 1` and the integral is `y − x`; for `s ≤ x`, `h = s²/u²` and the integral is `s²(1/x − 1/y)`; in between it is `(s − x) + s²(1/s − 1/y)`). Write

```
ℓ(I) = ∫_I du,    κ(I) = ∫_I u⁻² du
r1 = ℓ([x,y]) / ℓ([X,Y]),    r0 = κ([x,y]) / κ([X,Y]),    m = min(r0, r1)
```

so the credit is `C = m·L`. Because `[x, y] ⊆ [X, Y]`, `r1 ≤ 1` and `r0 ≤ 1`, hence `m ≤ 1` and `C ≤ L`.

The NFT's value is `L·V_[x,y](s)`; the value of its credit is `C·V_[X,Y](s)`.

## 1. Floor: `C·V_[X,Y](s) ≤ L·V_[x,y](s)` for every `s > 0`

Dividing by `L`, it suffices to show `φ(s) := V_[x,y](s) − m·V_[X,Y](s) ≥ 0`. The key bound is that `h_s(u) = min(1, s²/u²)` is at most each of its two terms, so for every interval `I`

```
V_I(s) ≤ ℓ(I)         and         V_I(s) ≤ s²·κ(I).                         (★)
```

**Case `s ≤ x`.** Every `u ∈ [x, y]` has `u ≥ s`, so `V_[x,y](s) = s²·κ([x,y]) = r0·s²·κ([X,Y])`. By (★), `s²·κ([X,Y]) ≥ V_[X,Y](s)`, so `V_[x,y](s) ≥ r0·V_[X,Y](s) ≥ m·V_[X,Y](s)`.

**Case `s ≥ y`.** Every `u ∈ [x, y]` has `u ≤ s`, so `V_[x,y](s) = ℓ([x,y]) = r1·ℓ([X,Y]) ≥ r1·V_[X,Y](s) ≥ m·V_[X,Y](s)` by (★).

**Case `x < s < y`.** Here `X ≤ x < s < y ≤ Y`, so both positions are in range and

```
V_[x,y](s) = 2s − x − s²/y,        V_[X,Y](s) = 2s − X − s²/Y
φ(s)       = 2(1 − m)s − x + mX − s²·(1/y − m/Y)
φ''(s)     = −2·(1/y − m/Y) ≤ 0          since m ≤ 1 and y ≤ Y.
```

`φ` is concave on `[x, y]`, so it attains its minimum there at an endpoint; `φ(x) ≥ 0` and `φ(y) ≥ 0` by the two cases above (they include `s = x` and `s = y`, and every `V` is continuous). Hence `φ ≥ 0` on the whole interval. ∎

The three cases cover every `s > 0`: prices below the band (`s < X`), inside the band but outside the position, inside the position, and above the band.

## 2. Edge minimum

Let `g(s) = V_[x,y](s) / V_[X,Y](s)` (both are positive for `s > 0`). Section 1 shows `g(s) ≥ m` everywhere. For `s ≤ X` both positions hold only token0, so `g(s) = κ([x,y])/κ([X,Y]) = r0`; for `s ≥ Y` both hold only token1, so `g(s) = r1`. So

```
min over s > 0 of g(s) = min(r0, r1) = m,
```

reached at the lower band edge `s = X` when `r0 ≤ r1`, at the upper edge `s = Y` otherwise (and at every price beyond that edge). No price inside the band gives a lower ratio, which is why the credit is the minimum of exactly these two ratios: any larger credit would be under-collateralised at one of the two edges, and any smaller one would leave value unused.

Consequences used by the fuzz tests:

- A position equal to the band (`x = X, y = Y`) gets `r0 = r1 = 1`, credit `L`.
- A near-full-range band (`X` near `MIN_SQRT_PRICE`, `Y` near `MAX_SQRT_PRICE`) has `ℓ([X,Y]) ≈ 2^160` in Q96 units, so `r1 = (y − x)/(Y − X)` is near 0 for any position that is not itself near full range: the band unit is worth almost nothing at most prices, and the credit, in those units, is correspondingly tiny.
- The credit is linear in `L`, hence non-decreasing in `L`.

## 3. Partial liquidation

Let a position of liquidity `L` carry credit `C ≤ m·L`. A liquidation at oracle price `s` seizes `c ≤ C` credit, valued at `c·V_[X,Y](s)`, by unwinding liquidity `λ` from the position whose value equals the seized value:

```
λ·V_[x,y](s) = c·V_[X,Y](s).
```

By Section 1, `V_[x,y](s) ≥ m·V_[X,Y](s)`, so `λ ≤ c/m`. The position keeps liquidity `L − λ ≥ L − c/m`, and its floor credit is

```
m·(L − λ) ≥ m·L − c ≥ C − c,
```

the remaining credit. So after any sequence of partial liquidations (each at its own oracle price) every position's floor still covers its remaining credit, and Section 1 applied to `L − λ` shows the remainder is still worth at least its remaining credit at every price. The same argument covers a withdrawal of liquidity `λ` that releases credit `c ≥ m·λ`, and a top-up that adds liquidity `λ` and credit `m·λ` (credit is linear in `L`).

## Integer arithmetic

`FloorCreditMath.credit` takes ticks and liquidity only. It converts the ticks with `ClTickMath.getSqrtPriceAtTick` and computes each ratio as what the position holds at a band edge divided by what one band unit holds there, with Uniswap v4-core `SqrtPriceMath.getAmount0Delta` and `getAmount1Delta` (the amount math of Uniswap's `getAmountsForLiquidity`). With `U = 2^128 − 1` band units measuring one unit precisely:

```
a0 = getAmount0Delta(x, y, L, down)  = floor(L·2^96·Δ / (x·y))        token0 at √A (position)
u0 = getAmount0Delta(X, Y, U, up)    = ceil (U·2^96·D / (X·Y))        token0 at √A (U band units)
a1 = getAmount1Delta(x, y, L, down)  = floor(L·Δ / 2^96)              token1 at √B (position)
u1 = getAmount1Delta(X, Y, U, up)    = ceil (U·D / 2^96)              token1 at √B (U band units)
credit = min( floor(a0·U / u0), floor(a1·U / u1) )
```

with `Δ = y − x` and `D = Y − X`. Exactly, `a0·U/u0 = L·r0` and `a1·U/u1 = L·r1`; the position's amounts round down and the band unit's round up, so each side is at most its exact value:

- **Rounding favours the protocol:** `credit ≤ L·m`, the exact credit, so Sections 1–3 hold for the integer credit with room to spare.
- **Rounding is small in value:** the round-down of `a` costs less than one base unit of the token, and the round-up of `u` costs less than `L·r/U < 1` base unit, so the credit falls short of the exact formula by at most 2 base units of the token's value at the binding edge, plus one band unit. Counted in band units the shortfall can be large where one band unit holds far less than a base unit (a narrow band at low square-root prices); it is still worth at most 2 base units.
- **Monotone in `L`:** each step is a non-decreasing function of `L`, so the integer credit is too.
- **No overflow:** each amount is below `2^192` (`L·2^96·Δ/(x·y) < 2^128·2^96·2^160/2^64`), `mulDiv` keeps the 512-bit products, and each side is at most `L·r ≤ L`, so the result fits `uint128`. `credit` reverts unless `A ≤ a < b ≤ B`, because outside the band the formula over-credits (Section 1's first two cases use `[x, y] ⊆ [X, Y]`).

Two integer effects are left to the caller (LPVault, step 2 of the refactor) and are not covered by this library:

- **Token amounts.** Burning returns amounts rounded down. The floor compares exact values; a caller that compares rounded token amounts must allow one base unit per token.
- **Unwound liquidity.** Section 3 uses the exact `λ`. Rounded to an integer, `λ` should be rounded up (the liquidator receives at least the seized value), and the remaining credit should be stored as `min(C − c, credit(L − λ))`. That keeps "credit ≤ floor credit" true by construction; Section 3 shows the `min` takes `C − c` up to the rounding of `λ` and of the credit.

## How each fact is established

The inequality is proven on paper, above: Section 1 (the floor at every price, through (★) and the concavity of `φ` inside the position), Section 2 (the edge minimum) and Section 3 (partial liquidation). The code is checked against the formula, and its rounding and overflow are checked by fuzzing:

| Fact | Check |
|---|---|
| Floor at every price, edge minimum, partial liquidation | Proof, Sections 1–3 |
| The code computes the formula of the previous section | `test/halmos/FloorCreditMath.halmos.t.sol` (`check_creditMatchesReference`): bounded symbolic, five fixed shapes near `MIN_TICK`, `L < 2^64` |
| The amounts-based credit equals the ratio formula `L·min(r0, r1)`, never above it, within 2 base units of value | `test/fuzz/FloorCreditMath.fuzz.t.sol` (`testFuzz_creditMatchesRatioFormula`, `testFuzz_creditRoundsDown`), exact rational comparison over the whole tick and liquidity domain |
| Floor at every price, below, inside and above the band | `testFuzz_valueCoversCreditAtAnyPrice`, `testFuzz_valueCoversCreditAtEdges`, exact integer cross-multiplication |
| No overflow | every fuzz test, over `L` up to `2^128 − 1` and ticks across `[MIN_TICK, MAX_TICK]` |
| Monotone in `L` | `testFuzz_creditMonotoneInLiquidity` |
| Revert outside the band | `testFuzz_revertsOutsideBand` |
| A position equal to its band gets its liquidity, up to rounding | `testFuzz_fullBandPositionGetsItsLiquidity` |
| Near-full-range band gives near-0 credit | `testFuzz_nearFullRangeBandGivesNearZeroCredit` |
| Partial liquidation | `testFuzz_partialLiquidationKeepsFloor` |

Supplementary, not a merge gate: `contracts/certora/specs/FloorCreditMath.spec` (`certora/conf/FloorCreditMath.conf`) restates Sections 1–2 and the integer bounds as Certora rules over unbounded integers: the credit is at most `L·r0` and `L·r1`, is monotone in `L`, every credit within both edge bounds is worth at most the position at every price in the band (the inside case by Section 1's concavity argument), and `credit` reverts outside the band. Its runs are logged in `contracts/certora/RUNS.md`.
