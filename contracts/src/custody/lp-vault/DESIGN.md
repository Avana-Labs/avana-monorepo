# LP-vault floor credit: design

How a concentrated-liquidity position becomes collateral in a band market, which markets a pool gets, what that means for a borrower, and how the math is checked. Lifecycle: [LIFECYCLE.md](LIFECYCLE.md). Proof: [4.5 Floor Credit Proof](../../../../docs/spec/04-security/05-floor-credit-proof.md).

## 1. Decision

| | |
|---|---|
| **Rule** | `credit = L × min(r0, r1)` band units, fixed at pledge. It is what the position holds at each band edge divided by what one band unit holds there: token0 at the lower edge (`r0`), token1 at the upper edge (`r1`), the lesser of the two. |
| **Band unit** | One unit of liquidity spread over the market's whole band `[A, B]`. |
| **Code** | [`libraries/FloorCreditMath.sol`](libraries/FloorCreditMath.sol): ticks and liquidity in, credit out; amounts from Uniswap v4-core `SqrtPriceMath`; rounds down. |

**Why.** Aave needs one fungible collateral token per market, so every position in a market must be counted in the same unit. The rule gives that unit and keeps three properties:

| Property | How |
|---|---|
| Fixed at pledge | The credit reads no pool price; it changes only on top-up, withdrawal or liquidation. |
| Never above the position's value | At every price the position is worth at least `credit` band units; the least ratio is at a band edge, which is where the `min` is taken. |
| Pool-neutral | Inputs are ticks and liquidity only, so any concentrated-liquidity AMM fits. |

**Who owns what.**

| Question | Owner |
|---|---|
| How many band units a position is worth | `FloorCreditMath` and the LPVault (this folder, step 2) |
| How many dollars one band unit is worth | LPOracle (step 3), [oracle LIFECYCLE.md](../../oracle/LIFECYCLE.md) |
| The LTV, and which markets each pool has | RiskModule (step 4), [risk-module LIFECYCLE.md](../../policy/risk-module/LIFECYCLE.md) |

## 2. Markets per pool

| Market | Band | Who it serves |
|---|---|---|
| Full range | The lowest and highest usable ticks. A full-range position gets `credit = L`. | Full-range positions |
| Wide | Uniswap's Wide preset, −50% / +100% around the price on listing day | Every narrower position inside it |
| New Wide | A new Wide market, opened by a keeper when the price nears the current Wide band's edge, with the preset the DAO approved at listing | Positions around the new price |

Uniswap's five price-range presets map onto these:

| Uniswap preset | Range | Market |
|---|---|---|
| Full range | all ticks | Full range |
| Wide | −50% / +100% | Wide (credit = `L`) |
| Stable | ±0.3% | Wide |
| One-sided lower | −50% to the price | Wide |
| One-sided upper | the price to +100% | Wide |

## 3. Examples

$10,000 position, 75% LTV, Base ETH/USDC Uniswap v3 0.05% at $1,803.33. Wide band $901.50 – $3,608.30. Borrowing power = credit × the band unit's value at the price × LTV. Ticks snap to the nearest usable tick (spacing 10), as Uniswap's interface does.

| Preset | Listing day | ETH −30% | ETH +50% |
|---|---|---|---|
| Full range | $7,500 | $6,275 | $9,186 |
| Wide | $7,500 | $6,033 | $8,729 |
| Stable ±0.3% | $6,216 | $5,000 | $7,234 |
| One-sided lower | $6,212 | $4,997 | $7,230 |
| One-sided upper | $6,213 | $4,998 | $7,231 |

- On listing day the percentages are the same in every pool, up to tick rounding: presets are percentages of the price.
- Stable and one-sided positions get about 83% of full range on listing day (79–80% after the moves above): their credit is the band unit count at the worse of the two edges.
- The borrowing power always stays below 75% of the position's value: after ETH −30% the Stable position is worth $7,007 and borrows $5,000.

With real LTVs, for a $10,000 full-range or Wide position:

| Pair | LTV | Borrowing power |
|---|---|---|
| Stablecoins, LSTs (E-Mode) | 90–93% | $9,000 – $9,300 |
| WBTC/ETH | 73% | $7,300 |
| AAVE or LINK pairs | 66% | $6,600 |
| Memecoins (estimate) | 25–30% | $2,500 – $3,000 |

An LP position's LTV is the lower of its two tokens' LTVs.

Numbers from a short script of the formula in floating point; the library's integer credit is at most these, and below them by at most 2 base units of the token.

## 4. Assurance

| Tool | What it shows | Where |
|---|---|---|
| Paper proof | The floor at every price (concavity inside the position), the minimum at a band edge, partial liquidation stays safe | [05-floor-credit-proof.md](../../../../docs/spec/04-security/05-floor-credit-proof.md) |
| Certora | The formula's math as pure numbers, over unbounded integers (rules below) | [`certora/specs/FloorCreditMath.spec`](../../../certora/specs/FloorCreditMath.spec) |
| Halmos | The code computes the formula (`check_creditMatchesReference`, bounded) | [`test/halmos/FloorCreditMath.halmos.t.sol`](../../../test/halmos/FloorCreditMath.halmos.t.sol) |
| Fuzz | Rounding and overflow over the whole tick and liquidity domain; the new code against the old ratio formula: never above it, below it by at most 2 base units of the token's value | [`test/fuzz/FloorCreditMath.fuzz.t.sol`](../../../test/fuzz/FloorCreditMath.fuzz.t.sol) |

Certora rules (local Prover, 2026-11-19; supplementary, not a merge gate):

| Rule | Shows | Result |
|---|---|---|
| `creditAtMostToken1Ratio` | credit ≤ L·r1 (upper edge) | Verified |
| `creditAtMostToken0Ratio` | credit ≤ L·r0 (lower edge) | Verified |
| `creditMonotoneInLiquidity` | more liquidity never earns less credit | Verified |
| `creditValueCoveredBelowPosition` | value floor, prices below the position | Verified |
| `creditValueCoveredAbovePosition` | value floor, prices above the position | Verified |
| `creditValueCoveredInsidePosition` | value floor, prices inside the position | Running |
| `creditRevertsOutsideTheBand` | a position outside its band gets no credit | Verified |

Related lifecycles: [LP vault](LIFECYCLE.md), [Uniswap v3 integration](../../amm/uniswap-v3/LIFECYCLE.md), [oracle](../../oracle/LIFECYCLE.md), [risk module](../../policy/risk-module/LIFECYCLE.md).
