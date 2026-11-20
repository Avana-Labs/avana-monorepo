# RiskModule: design record

**Status: locked (2026-11-19).** This record argues each decision in order: the thesis, the reasoning, each alternative with a worked example, a debate between two agents, and the conclusion. The credit math these rules build on is argued in the [LP-vault credit design record](../vault/DESIGN.md). Lifecycle: [LIFECYCLE.md](LIFECYCLE.md).

**How to read the numbers.** Every example is a $10,000 position. A cell shows the borrowing power, which is the position's credit value times the LTV. Positions use Uniswap's strategies, minted at the listing price:
- Full range
- Wide (−50% / +100%)
- Stable (±0.3%)
- One-sided lower or upper (50% of the price on one side)

Credit shares come from the floor-credit formula, `credit = L × min(r0, r1)`, computed in a short script. The pools are real: Base ETH/USDC 0.05% (tick spacing 10, $1,803.33 on the listing day used throughout), wstETH/WETH 0.01%, USDC/USDT 0.01% and WBTC/ETH 0.3%. LTVs are illustrative: the ARFC sets the live ones.
- ETH/USDC: 75%, the lower of WETH 80.5% and USDC 75%
- WBTC/ETH: 73%
- Stable and correlated pairs in their E-Mode-style Spoke: 93%

## Thesis

The RiskModule holds Avana's rules. It decides four things:

1. **Two markets per pool, listed in one DAO call.** `listPool` lists each pool as two ERC-20 markets at one LTV:
   - **Full range:** the band is the pool's usable tick range, and a full-range position gets credit `L`.
   - **Custom range:** a band around the listing price. Any position fully inside it gets its floor credit.
2. **The LTV rule.** An LP's LTV is the lower of its two tokens' LTVs on that Spoke. Correlated pairs use an E-Mode-style Spoke, Aave V4's form of E-Mode, with that Spoke's higher LTV.
3. **Widths are defaults; bands are fixed.** The Custom range width comes from the Spoke kind:

   | Spoke kind | Width | Ticks below / above |
   |---|---|---|
   | Stable | ±1% | 101 / 100 |
   | Correlated | ±5% | 513 / 488 |
   | Volatile | 0.345× – 2.898× | 10,643 / 10,641 |

   The DAO can change these defaults, and a listing can override them for its own pool. Once a market is listed, its band never changes.
4. **The depeg response.** The monitor alerts when a peg is off by more than 1%. The risk steward then freezes the pool's reserves until the peg returns. There is no lower-LTV market for depegs.

`listPool` makes three checks before it lists anything:
- The Custom range band contains the Chainlink price at execution.
- The band is at least `MIN_BAND_SPACINGS` (4) tick spacings wide.
- The band is strictly narrower than full range.

## Reasoning

| Constraint | Consequence |
|---|---|
| A listing proposal is written days before the timelock executes it | The proposal fixes the listing tick so voters see the exact band. Execution reads Chainlink and refuses if the price has left the band in the meantime. |
| An Aave collateral balance must not change by itself, and a vault token unit means "one unit of this band" | The band cannot change after listing (alternative 3b shows the over-credit). |
| Every market costs a reserve, an oracle, caps and monitoring | Use as few markets as serve users. Two per pool, argued in the credit record. |
| The floor credit is never worth more than the position at any price | A silly width loses business but cannot cause bad debt. A width is safe to delegate to defaults plus overrides; only the LTV is dangerous. |
| Floor credit at a band edge is all of one token | An LP can become entirely its weaker token. It must never borrow more than that token could on its own, which gives the lower-of-two rule. |
| Aave V4 already has a freeze held by the risk steward | A depeg needs no new mechanism, only an alert. |

What the contract owns and what it leaves out:
- **Vault tokens:** the RiskModule picks each market's decimals at listing, the fewest at which a whole token is worth at least $1. The VaultToken itself is deployed outside, because its market ID is known before listing. `activateMarket` then checks it: its market, Hub, LiquidationModule, decimals and AccessManager. Embedding the VaultToken creation code would push the RiskModule past EIP-170 (32.6 kB measured).
- **Activation check:**
  - the LPOracle prices this market with the listed feeds and decimals;
  - the Spoke reserve holds the vault token on the Spoke's Hub, with the oracle as its price source;
  - the vault token's draw cap is 0;
  - receive-shares is off;
  - the liquidation fee is 0;
  - the collateral factor equals the market's LTV.
- **Borrow-side gate:** `checkBorrow` passes only when three things hold:
  - the debt reserve is registered;
  - at least one keeper is registered;
  - the First-Loss Reserve of `(hub, asset)` holds the coverage ratio of the summed draw caps of every Spoke borrowing that asset.

## Decision 1: two markets per pool

The full comparison of one to nine markets is in the [credit record](../vault/DESIGN.md#alternatives). Here it is again on the real pools, on listing day.

| Base ETH/USDC 0.05%, 75% LTV | Full range | Wide | Stable ±0.3% | One-sided |
|---|---|---|---|---|
| **Two markets (chosen)** | $7,500 | $6,700 | $5,555 | $5,550 |
| One market, Full range only (debate) | $7,500 | rejected | rejected | rejected |
| One wide band, 0.25×–5× | rejected | $5,490 | $4,550 | $4,550 – $5,080 |
| Five markets (3 extra Narrow bands) | $7,500 | $6,700 | $7,160 | $5,550 |

| USDC/USDT 0.01%, 93% E-Mode | Full range | Stable ±0.3% |
|---|---|---|
| **Two markets (chosen, ±1% band)** | $9,300 | $9,283 |
| One market, Custom range only (debate) | rejected | $9,283 |

| wstETH/WETH 0.01%, 93% E-Mode | Full range | Stable ±0.3% |
|---|---|---|
| **Two markets (chosen, ±5% band)** | $9,300 | $9,187 |

### Debate

| Opposing agent: one market, chosen by Spoke kind | Proposing agent: two markets everywhere |
|---|---|
| On volatile pools the Custom range market is a weak product: Stable and one-sided positions get about 55.5% ($5,555). Anyone who wants 75% holds full range. | Concentrated LPs hold most volatile-pool liquidity, and they hold it for the fee income. Full range only leaves them two choices: give up that income or get no loan. $5,555 against $0 is the real choice. The opposing side concedes this as its proposal's weakness. |
| The second market multiplies with drift: three re-listings leave five reserves on one pool, with stranded positions. | A re-listing is a governance decision, not automatic. No keeper opens markets (plan, 2026-11-19). The Volatile band holds −31% / +45% before Wide stops fitting, and old markets keep serving their positions until they exit. It is a routine proposal, not an unbounded set. |
| On stable pools Full range is almost unused, so its market costs a reserve for close to no demand. | One shape for every pool keeps routing, listing and monitoring uniform: one `listPool`, one routing rule in the adapter. Wide and one-sided stable positions get $9,300 in Full range by re-minting full range, since Custom ±1% rejects them. An unused reserve costs a cap and an alert, not risk. |

**Why two markets.** The opposing proposal either shuts out concentrated volatile LPs or saves one quiet reserve on stable pools. Neither is worth losing the one shape that serves every Uniswap strategy.

## Decision 2: LP LTV = the lower of the two tokens' LTVs, E-Mode for correlated pairs

**The rule.** At each band edge, a position holds only one token. If the price leaves the position's range on the way to an edge, it already holds only one token. So an LP can become entirely its weaker token, and it must not borrow more than that token could on its own.

| Base ETH/USDC, $10,000 Stable ±0.3% position after ETH rises past its range (now ≈ $10,007 of USDC) | LTV | Borrowing power on that credit |
|---|---|---|
| **Lower of the two (chosen)** | 75% | the same as USDC on its own |
| Value-weighted average of WETH 80.5% and USDC 75% | 77.75% | 2.75 points more than Aave lends against the same USDC |
| Flat LP haircut | 50% | $2,500 less than USDC alone, for no risk the token does not already carry |
| Average minus a 5-point haircut (debate) | 72.75% | below USDC alone, without a derived reason |

| wstETH/WETH, $10,000 Stable ±0.3% in a ±5% band | LTV | Borrowing power |
|---|---|---|
| **E-Mode-style Spoke (chosen)** | 93% | $9,187 |
| Lower of the normal LTVs (wstETH 78.5%) | 78.5% | $7,754 |
| Average minus 5 points, no E-Mode (debate) | 74.5% | $7,360 |

### Debate

| Opposing agent: value-weighted LTV minus 5 points, no E-Mode | Proposing agent: lower of the two, E-Mode for correlated pairs |
|---|---|
| An LP NFT is not its tokens. Liquidating it means unwinding, selling two tokens into a stressed pool, gas and new oracle code. 93% leaves 7 points for all of that. | Avana liquidates in kind. The LiquidationModule unwinds only the liquidity worth the seized credit and hands both tokens to the liquidator. The liquidator then holds exactly what a liquidator of plain wstETH holds, so the sale risk is the token's own. The floor credit is never worth more than the position, so the LP is at most as risky as its weaker token. |
| Correlated pairs fail: stETH traded at 0.935 ETH in June 2022. At 93%, a $10,000 position borrows $9,188, and a 6.5% depeg takes it to HF 0.97. Under a 74.5% rule it stays at 1.02. | The same 6.5% move liquidates a plain wstETH E-Mode loan at 93% too. That is Aave's risk choice for wstETH, priced by its risk providers. Matching it adds no LP-specific risk. Below the token's own LTV, LP collateral is strictly worse than depositing the tokens, so no one would loop through it. The opposing side concedes that the looping demand is lost. |
| A haircut prices LP risk explicitly; the min-rule borrows token parameters that say nothing about LPs. | The LP-specific risk, the shape of the position, is already priced by the floor credit: a $10,000 narrow position is credited $7,407 in a volatile band, not $10,000. A second haircut on top counts the same risk twice. The 5 points have no derivation; the opposing side calls them "a judgement call". |

**Why the lower of the two.** It is the largest LTV that never lends more against an LP than Aave lends against the token the LP can turn into. Floor credit already prices the position's shape. E-Mode applies because Aave already accepts its correlation risk for the tokens themselves.

## Decision 3: widths are DAO defaults with a per-pool override; the band is fixed for life

### 3a. Where widths come from

| WBTC/ETH 0.3%, $10,000 Stable ±0.3%, 73% LTV | Band | Credit share | Borrowing power | Re-listing after a ratio move of |
|---|---|---|---|---|
| Volatile default | 0.345× – 2.898× | 74.0% | $5,406 | −31% / +45% (Wide) |
| **Per-pool override (chosen mechanism), volatility-scaled** | 0.70× – 1.43× | 91.1% | $6,653 | about −30% / +43% (Stable) |
| Hard-coded widths, no override | 0.345× – 2.898× | 74.0% | $5,406 | n/a: a calmer pair cannot get more |

### 3b. Whether a band can move after listing

Take a $10,000 Wide position credited in the Volatile band: credit share 89.3%, borrowing $6,700 at 75%. Suppose the band is moved and the credits are kept, as any re-band must do, because the credit is the vault token balance:

| New band | Value of the old credit, as a share of the position | Effect |
|---|---|---|
| **Fixed band (chosen)** | 89.3% at listing; never above 100% at any price | Safe |
| Narrowed to 0.70× – 1.43× | 35.4% | Every user is suddenly under-collateralized and liquidated |
| Widened to 0.25× – 5× | 114% at listing, up to 156% as the price moves | Lends against value that does not exist: bad debt |

### Debate

| Opposing agent: per-pool widths only, from realized volatility, no defaults | Proposing agent: defaults plus per-pool override |
|---|---|
| One Volatile width penalizes calmer pairs: WBTC/ETH would borrow $1,278 more per $10,000 at 0.70×–1.43×. | Agreed on the example, and the chosen design allows it. The listing sets `width` for WBTC/ETH, and the ARFC argues it. Defaults exist for the common case, so a listing needs no volatility study when the Spoke kind already fits. |
| Changing a default is a hidden change: it alters every future listing at once. | A default changes only through its own governance call (`setSpokeWidth`), which emits `SpokeWidthSet`. It touches no listed market. Every listing proposal shows its exact ticks, because `listingTick` and the width are in the calldata voters read. |
| Per-pool widths are reviewed together with their pool. | Both are reviewed: an override is in the pool's own proposal. Requiring a fresh width for every pool adds governance work. The opposing side concedes this as its weakness, along with early re-listings after a volatility spike. |

Both sides agree the band is fixed for life. 3b shows why.

**Why defaults with an override.** A width can only lose business, never cause bad debt, so the cheapest safe process wins. That is a default for the common case and an argued override for the rest. A band, once listed, defines the vault token's unit, so moving it re-prices every open credit (3b).

## Decision 4: depeg = alert above 1%, the steward freezes, no lower-LTV market

| USDC/USDT 0.01%, ±1% band, 93% E-Mode, $10,000 Stable ±0.3% | New loans after a 2% depeg | Loans opened before |
|---|---|---|
| **Alert, steward freezes (chosen)** | None once frozen (minutes to hours after the alert) | Unchanged; liquidated as normal if HF < 1 |
| Keep lending | The position has left its band: rejected by Custom range in any case. Full range keeps lending at 93% into the depeg. | Unchanged |
| Lower-LTV fallback market (e.g. ±5% at 75%) | $7,408 against a falling asset, at the moment no new loan should go out | Unchanged |
| Automatic on-chain freeze at 1% deviation (debate) | None from the block the trigger fires | Unchanged |

### Debate

| Opposing agent: permissionless on-chain freeze at 1% deviation, steward only unfreezes | Proposing agent: monitor alert, steward freeze |
|---|---|
| The off-chain path is slow; USDC broke peg on a Friday night (10 March 2023). The delay is an attack window. | The example's pledge happens at $0.99, inside 1%. An on-chain trigger at 1% lets it through too. The loss in the example comes from the later move to $0.88, and no freeze touches loans that are already open. The opposing side concedes this. The window that matters is the next few points. The steward's freeze is Aave's standard tool for exactly that, and it already holds the role. |
| Pledging during the delay buys cheap collateral at a high LTV: a $9,288 loan becomes about $400 of bad debt after a fall to $0.88. | An LTV of 93% is chosen for an asset Aave already lends against at 93% in E-Mode. A crash from $0.99 to $0.88 creates the same shortfall on plain USDC collateral. That risk belongs to the LTV choice, not to the LP wrapper. |
| Code-enforced, so a monitor outage no longer means no freeze. | The on-chain trigger needs a TWAP of the pool itself, which can be pushed over a short window to freeze a healthy market. The opposing side names this griefing risk. It also needs a freeze role for the RiskModule on the Aave Spoke, which widens what a compromised RiskModule can do. The monitor runs redundantly. |

**Why the steward freeze.** It uses Aave's own control with no new role and no manipulable trigger. It stops new loans as fast as on-chain checks would in any realistic depeg. A lower-LTV market would keep lending exactly when nothing should be lent. Possible later work, not adopted here: a Chainlink-only deviation check in `checkBorrow` (no pool TWAP), if monitor latency proves a problem in practice.

## Conclusion

The RiskModule keeps governance to one call per pool. That call lists two markets, Full range and Custom range, at the lower of the two tokens' LTVs, with E-Mode for correlated pairs. Bands come from Spoke defaults or an argued override, and they never move once listed. The width can only cost business; the LTV is the one dangerous knob, and Aave's ARFC and the timelock govern it. Depegs use Aave's own freeze. The listing checks catch a stale proposal (the price left the band), a band too thin to hold positions, and a band that is really full range. The activation check binds each market's token, oracle and Aave reserve to what was listed. The opposing agent's strongest points do not change the decisions:
- **Calmer volatile pairs:** they deserve narrower bands, and the per-pool override already gives them that.
- **Monitor latency:** a Chainlink-only `checkBorrow` deviation gate is recorded above as a possible later addition.

## Assurance

| Tool | What it shows | Where |
|---|---|---|
| Unit tests | Listing, the three listing checks, vault-token decimals, every activation reason, routing, eligibility, credit, coverage, fee, keepers, access | [`test/unit/RiskModule.Markets.unit.t.sol`](../../test/unit/RiskModule.Markets.unit.t.sol) |
| Fuzz tests | Bands are aligned, hold the requested width and the minimum span, and stay inside full range. Vault-token decimals are the fewest worth $1. Routing and credit agree at any price. Coverage rounds up exactly. | [`test/fuzz/RiskModule.Bands.fuzz.t.sol`](../../test/fuzz/RiskModule.Bands.fuzz.t.sol) |
| Floor-credit math | Proof, Certora, Halmos, fuzz | [credit record, Assurance](../vault/DESIGN.md#assurance) |
