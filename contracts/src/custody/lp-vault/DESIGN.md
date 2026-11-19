# LP-vault credit: design record

**Status: locked (2026-11-19).** This record states what a concentrated-liquidity position is worth as collateral, which markets a pool gets, the options that were weighed and why they lost, and how the math is checked. Lifecycle: [LIFECYCLE.md](LIFECYCLE.md). Proof: [4.5 Floor Credit Proof](../../../../docs/spec/04-security/05-floor-credit-proof.md).

Reading the percentages: every percentage below is **borrowing power as a share of the position's value**, at 75% LTV unless stated. 75% is the most any position can get; a position credited at its full value gets exactly 75%.

## 1. Decision

### The credit rule

| | |
|---|---|
| **Rule** | `credit = L × min(r0, r1)` band units, fixed at pledge: what the position holds at each band edge divided by what one band unit holds there (token0 at the lower edge, `r0`; token1 at the upper edge, `r1`), the lesser of the two. |
| **Band unit** | One unit of liquidity spread over the market's whole band. |
| **Code** | [`libraries/FloorCreditMath.sol`](libraries/FloorCreditMath.sol): ticks and liquidity in, credit out; amounts from Uniswap v4-core `SqrtPriceMath`; rounds down. |

Why this rule:

| Need | How the rule meets it |
|---|---|
| Aave lists one fungible ERC-20 per collateral market | Every position in a market is counted in the same unit, the band unit |
| The collateral balance must not move by itself | The credit reads no pool price; it changes only on top-up, withdrawal or liquidation |
| Never lend against value that is not there | At every price the position is worth at least `credit` band units; the least ratio is at a band edge, where the `min` is taken (proof, Sections 1–2) |
| Any concentrated-liquidity AMM | Inputs are ticks and liquidity only |

### Markets per pool

Two ERC-20 markets per pool, named with Uniswap's words:

| Market | Band | Accepts | Credit |
|---|---|---|---|
| Full range | The lowest and highest usable ticks | Full-range positions | `L` (75%) |
| Custom range | A band around the listing price, its width set by the Spoke (below) | Any range inside the band | `L × min(r0, r1)` |

| Spoke | Custom range band |
|---|---|
| Stable LP | ±1% |
| Correlated LP | ±5% |
| Volatile LP | "Wide 67%": 0.345× to 2.898× the listing price (Uniswap's Wide preset gets exactly 67% in it on listing day) |

| Rule | |
|---|---|
| Listing | One DAO vote per pool, at one LTV; the markets are never changed afterwards |
| Routing (AaveAdapter, automatic) | A full-range position goes to Full range; otherwise to Custom range if it fits the band; otherwise it is rejected and the UI suggests Full range |
| Depeg | A monitor alerts at a deviation above 1%; the risk steward freezes the reserves (Aave practice: no new loans in a depeg) |
| Slow drift | For pairs that drift slowly by design (wstETH/ETH about +3% a year), a routine re-listing opens a new Custom range market |

### Who owns what

| Question | Owner |
|---|---|
| How many band units a position is worth | `FloorCreditMath` and the LPVault (this folder) |
| How many dollars one band unit is worth | LPOracle, [oracle LIFECYCLE.md](../../oracle/LIFECYCLE.md) |
| The LTV, and the markets of each pool | RiskModule, [risk-module LIFECYCLE.md](../../policy/risk-module/LIFECYCLE.md) |

## 2. Options weighed

Positions are Uniswap's presets: Full range, Wide (−50% / +100%), Stable (±0.3%), One-sided lower (−50% to the price), One-sided upper (the price to +100%). Volatile pool on listing day unless stated.

| Option | Result | Why rejected |
|---|---|---|
| (a) One market per exact range (the original design) | 75% for a position that matches a market's range exactly | Uniswap's presets are percentages of the price at the moment of minting, so they almost never match a listed range: almost every position is rejected |
| (b) One band, 0.25× to 5× (the step 1–2 default) | Stable 46%, Wide 55%, One-sided 45% / 51%; Full range rejected | Low for every preset, and full-range positions, the most common kind, have no market |
| (c) Live credit, re-marked to the position's value | About 73–75% (estimate; the credit follows the value) | In a crash, marking a balance down lowers health factors, and Aave's health-factor check blocks the very transfer that would do it; risk providers would not accept a collateral balance changed by an outside protocol |
| (d) 5–9 markets per pool | Only Stable ±0.3% gains: 72% in a ±15% market against 56% in Wide 67% | Many more markets, votes and oracles for one preset's gain |
| (e) 3 markets per pool (adds a wide market to the Stable Spoke) | A Stable user in a 2% depeg gets 55% instead of being rejected | Superseded by the resolution in Section 3: in a depeg, no new loans should go out |
| (f) A wider 2nd market (±5% Stable, ±15% Correlated) for depegs | ±5%: 72–74% through a 4% depeg (74% on peg) | Same: it keeps lending into a depeg, which the reserve freeze is there to stop; tighter bands give more on peg |

## 3. Debate: two or three markets

Both sides as argued; the resolution decided it.

| For 3 markets | For 2 markets |
|---|---|
| The Stable Spoke rejects Wide and one-sided positions even on day one | Wide and one-sided positions on a stable pair behave like full range; Full range at 75% serves them better than any band |
| A 2% depeg rejects Stable users exactly when demand peaks; a third market keeps them at 55% | Widening fixes depegs better than a third market: a ±5% band keeps 72–74% through a 4% depeg |
| Correlated pairs have the same problem at ±10% | Stable pairs hold mostly narrow positions (Flipside data), which tight bands credit at about 75% |
| Existing users are unaffected either way | |
| Concedes that Volatile pools need only two | |

**Resolution.** In a depeg no new loans should go out at all; Aave's practice is to freeze the reserve, and the risk steward does. That removes the depeg argument, which was the case for both a third market and a wider second one, so two markets with tight widths win.

## 4. Worked examples

$10,000 position, 75% LTV. Computed with the floor-credit formula; the library's integer credit is at most these, and below them by at most 2 base units of the token.

### Real pool on listing day: Base ETH/USDC Uniswap v3 0.05% at $1,803.33

Volatile Spoke, Custom range band $622.09 – $5,223.77 (0.345× to 2.898×, ticks snapped to the nearest usable tick, spacing 10, as Uniswap's interface does).

| Preset | Market | Borrowing power | Share |
|---|---|---|---|
| Full range | Full range | $7,500 | 75% |
| Wide | Custom range | $6,699 | 67% |
| Stable ±0.3% | Custom range | $5,555 | 56% |
| One-sided lower | Custom range | $5,552 | 56% |
| One-sided upper | Custom range | $5,550 | 56% |

The shares are the same in every pool on listing day, up to tick rounding: presets and bands are percentages of the price.

### Volatile drift: positions opened after the price has moved from listing

Each preset is minted around the new price; the Custom range band stays where it was listed.

| Price vs listing | Full range | Stable | Wide | One-sided lower | One-sided upper |
|---|---|---|---|---|---|
| −60% | 75% | 30% | rejected | rejected | 42% |
| −30% | 75% | 45% | 55% | 45% | 64% |
| −15% | 75% | 51% | 62% | 51% | 60% |
| 0% | 75% | 56% | 67% | 56% | 56% |
| +20% | 75% | 50% | 61% | 60% | 50% |
| +30% | 75% | 48% | 58% | 63% | 48% |
| +60% | 75% | 42% | rejected | 60% | rejected |

From about ±60% the Wide preset no longer fits the band; a new Custom range market is then due.

### Stable and Correlated Spokes on peg

| Spoke | Band | Position | Share |
|---|---|---|---|
| Stable LP | ±1% | Stable ±0.3% | 74.9% |
| Correlated LP | ±5% | Stable ±0.3% | 74.1% |

### Real LTVs

For a $10,000 position credited at its full value (Full range, or a custom range equal to its band). An LP position's LTV is the lower of its two tokens' LTVs.

| Pair | LTV | Borrowing power |
|---|---|---|
| Stablecoins (E-Mode) | 93% | about $9,300 |
| WBTC/ETH | 73% | $7,300 |
| AAVE or LINK pairs | 66% | $6,600 |
| Memecoins (estimate) | 25–30% | $2,500 – $3,000 |

## 5. Assurance

| Tool | What it shows | Where |
|---|---|---|
| Paper proof | The floor at every price (concavity inside the position), the minimum at a band edge, partial liquidation stays safe | [05-floor-credit-proof.md](../../../../docs/spec/04-security/05-floor-credit-proof.md) |
| Certora | The formula's math as pure numbers, over unbounded integers (rules below) | [`certora/specs/FloorCreditMath.spec`](../../../certora/specs/FloorCreditMath.spec) |
| Halmos | The code computes the formula (`check_creditMatchesReference`, bounded) | [`test/halmos/FloorCreditMath.halmos.t.sol`](../../../test/halmos/FloorCreditMath.halmos.t.sol) |
| Fuzz | Rounding and overflow over the whole tick and liquidity domain; the code against the ratio formula: never above it, below it by at most 2 base units of the token's value | [`test/fuzz/FloorCreditMath.fuzz.t.sol`](../../../test/fuzz/FloorCreditMath.fuzz.t.sol) |

Certora rules (local Prover, 2026-11-19; supplementary, not a merge gate; log in [`certora/RUNS.md`](../../../certora/RUNS.md)). 6 of 7 verified:

| Rule | Shows | Result |
|---|---|---|
| `creditAtMostToken1Ratio` | credit ≤ L·r1 (upper edge) | Verified |
| `creditAtMostToken0Ratio` | credit ≤ L·r0 (lower edge) | Verified |
| `creditMonotoneInLiquidity` | more liquidity never earns less credit | Verified |
| `creditValueCoveredBelowPosition` | value floor, prices below the position | Verified |
| `creditValueCoveredAbovePosition` | value floor, prices above the position | Verified |
| `creditValueCoveredInsidePosition` | value floor, prices inside the position | Timeout after 64 min, no counterexample: rests on the paper proof (concavity) and the fuzz test |
| `creditRevertsOutsideTheBand` | a position outside its band gets no credit | Verified |

Related lifecycles: [LP vault](LIFECYCLE.md), [Uniswap v3 integration](../../amm/uniswap-v3/LIFECYCLE.md), [oracle](../../oracle/LIFECYCLE.md), [risk module](../../policy/risk-module/LIFECYCLE.md), [AaveAdapter](../../policy/aave-adapter/LIFECYCLE.md).
