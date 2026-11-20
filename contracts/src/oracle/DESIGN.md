# LPOracle design record

This record covers how Avana prices a band market's vault token for Aave V4: the decisions, every option weighed, a debate between two agents, worked examples and the final reasons. The code is [`LPOracle.sol`](LPOracle.sol) with [`LPPriceMath.sol`](LPPriceMath.sol). The credit it multiplies is in [`FloorCreditMath.sol`](../custody/lp-vault/libraries/FloorCreditMath.sol); the vault token is [`VaultToken.sol`](../vault-token/VaultToken.sol).

## What is priced

A band market is one pool and fixed band ticks `[A, B]`. Each pool has two: **Full range** (the band is the pool's usable tick range) and **Custom range** (Stable ±1%, Correlated ±5%, Volatile 0.345x–2.898x of the listing price). An NFT fully inside the band is credited once, at pledge:

```
credit = L · min( (1/√a − 1/√b) / (1/√A − 1/√B),  (√b − √a) / (√B − √A) )     (exactly L when [a, b] = [A, B])
```

One credit unit is one unit of liquidity spread over the band, and one vault-token base unit is one credit unit. So the oracle must answer one question: **what is one unit of band liquidity worth now?**

```
s      = √P,  P = (price0 / 10^d0) / (price1 / 10^d1)      fair price from the market's own Chainlink feeds
s'     = clamp(s, √A, √B)                                    the AMM's own composition outside the band
amount0 = U · (1/s' − 1/√B),  amount1 = U · (s' − √A)        U = 10^unitDecimals (one whole vault token)
answer = amount0 · price0 / 10^d0 + amount1 · price1 / 10^d1   USD, 8 decimals, rounded down, at least 1
```

Amounts use Uniswap v4-core `SqrtPriceMath` and `ClTickMath` (the repo's own copies), the same functions the LPVault credits with; no external Uniswap contract is called and nothing depends on the AMM, so one oracle serves Uniswap v3, v4 and Slipstream alike. For the Full range market `amount1 ≈ U·√P` and `amount0·P ≈ U·√P`, so one unit is worth `2·√P` in token1, and the clamp never binds.

The guarantee the whole credit design rests on: for every NFT inside the band and every price, **`credit × answer / U ≤ the NFT's value at the same price`**. FloorCreditMath proves the inequality for exact math (the position's value over the unit's is lowest at a band edge, and the credit is that lowest ratio). The oracle keeps it because every step rounds down. [`LPOracle.FloorCredit.fuzz.t.sol`](../../test/fuzz/LPOracle.FloorCredit.fuzz.t.sol) checks it through the deployed contract for random bands, positions, prices and decimals, and for the full range, with the pool's own rounding (one smallest unit of each token) as the only slack.

## Decisions

| # | Decision | Chosen | Rejected |
|---|---|---|---|
| 1 | Source of the price | The market's own Chainlink feeds for token0 and token1 (1 or 2 legs each), USD stablecoins capped at $1 | Pool spot (`slot0`); pool TWAP; TWAP + Chainlink hybrid; spot with a deviation guard |
| 2 | Outside the band | Clamp `√P` to `[√A, √B]`: the unit is all token0 below, all token1 above, valued at the feed prices | No clamp (in-range formula everywhere); revert or price 0 outside; graded haircut outside |
| 3 | Granularity | One immutable oracle per market, band and tokens read once from the LPVault | One shared registry oracle; one per pool for both markets |
| 4 | Feed checks | One check: each leg's answer is > 0 and below 2^128 (and the token price ≤ $10^10 for overflow safety). No round-time check | A single max-age check; the old borrow/liquidation freshness flags with a parameter store |
| 5 | Answer of 0 | Served as 1 | Revert |

## Options weighed

**1. Price source.**
- *Pool spot.* Free and always available, but one flash loan moves it inside a transaction: an attacker inflates the price, borrows, and lets it fall back. Rejected outright; Aave never prices collateral from an AMM spot price.
- *Pool TWAP (e.g. 30 min).* Every pool has one, so long-tail tokens could be listed. Moving a deep pool's TWAP is expensive, but a shallow pool's is not, and the oracle would then need per-pool liquidity checks, observation-buffer checks and a window per chain (the old code had all of these: `minObservations`, block-time rules). A TWAP also lags a real crash by its window, exactly when liquidations need the current price. Uniswap v4 pools have no built-in oracle at all, so v4 would need a hook.
- *Hybrid (Chainlink, bounded by a TWAP).* Catches a single bad feed, but adds the TWAP's machinery and a second failure mode: when the two differ, which one blocks what? Pausing or taking the min also stops liquidations during the dislocation it detects.
- *Chainlink fair price (chosen).* The same source Aave uses for every other reserve, already trusted by Aave governance and risk providers, unmovable by flash loans, available on every chain Avana targets for the tokens in scope. Pool-neutral: the oracle never touches the pool.

**2. Outside the band.**
- *No clamp.* The in-range formula past the band gives negative token amounts; the value is below the true value (the composition at the fair price minimises value) and can reach 0, which Aave refuses, so liquidations would stop in exactly the crash that needs them.
- *Revert or 0 outside.* Same failure: Aave reverts every health check of the reserve.
- *Graded haircut outside.* De-risks automatically, but the haircut is a second risk parameter on top of the LTV and threshold the DAO already votes per reserve, and it breaks the floor-credit identity (credit × price would be below what the NFT holds, so a healthy borrower could be liquidated by a parameter, not by a loss).
- *Clamp (chosen).* It is not an approximation: outside the band the AMM really holds only token0 (below) or only token1 (above), so the clamped amounts valued at the feed prices are the unit's true value. Risk outside the band is handled where Aave handles it: the LTV and threshold, the monitor alert, and the risk steward freezing the reserve.

**3. Granularity.**
- *Shared registry oracle.* One transaction updates a feed for every market, but it is a mutable, governed contract between Aave and every Avana reserve: one key compromise or bad update misprices them all at once, and Aave would read a price whose route can change without an Aave vote.
- *One per pool, serving both markets.* Saves one deployment per pool, but the two markets have different bands, so the contract needs a market index the Aave source interface cannot pass; it becomes two oracles in one.
- *One immutable per market (chosen).* Matches Aave's model (one source per reserve, changed only by an Aave vote), has no roles and no storage writes, and is audited once for all markets. Reading the band and tokens from the LPVault at construction rules out the worst misconfiguration: an oracle band that differs from the credit band.

**4. Feed checks.**
- *Freshness flags (old design).* Borrow and liquidation age limits per feed in a parameter store, with a `getPriceStatus` view the gates read. Cut in the policy audit: two extra contracts on the price path, per-feed parameters to govern, and a status Aave itself never reads.
- *A single max-age check that reverts.* Aave V4's `AaveOracle` calls only `latestAnswer()` and requires `> 0`. A revert on age would block liquidations as well as borrows, during an outage that is precisely when stale collateral must be liquidatable.
- *Answer > 0 only (chosen).* Required: a negative answer cast to unsigned would be a huge price, and 0 would make Aave revert anyway. Aave's own Chainlink sources do no more. Whether new borrows should also stop on an old round is a borrow-path rule, not a price rule; it belongs in the RiskModule (see "Open item").

**5. Answer of 0.** A vault token whose whole unit is worth under $10^-8 is a misconfigured market (the RiskModule chooses decimals so a whole token is worth at least $1 at listing). Serving 1 keeps Aave's health checks and liquidations working; the overstatement is at most $10^-8 per whole token. Reverting would freeze the reserve.

## Debate

Two agents argued. The opposing agent was asked to steelman the alternatives; its case is kept in full substance below, followed by the answer.

### Chainlink vs pool TWAP vs spot

**Against (opposing agent).** Chainlink covers only a few dozen Base assets, while most Slipstream volume is AERO, VIRTUAL, LSTs and new tokens; requiring two USD routes shuts out most pools, whereas a 30-minute TWAP exists for every pool with observations. The NFT's composition and the liquidation both follow the pool's price; Chainlink's 0.5% deviation and 20 min–24 h heartbeats leave 0.5–2% windows, a quarter of a ±1% band. The route is 2–4 feeds with no cross-check (LUNA's minAnswer floor in 2022, frozen deprecated feeds); a hybrid with a TWAP bound would catch a single-source failure. Moving a 30-minute TWAP on a deep Base pool costs millions, more than a capped $10,000 position returns. *Strongest point:* the design limits listings to Chainlink tokens and never checks the price against the pool where the collateral is held and liquidated.

**For (chosen design).** Coverage is a listing limit by intent: Avana lists pools whose tokens Aave already accepts as reserves, and those have Chainlink routes (two-leg routes cover LSTs, such as wstETH/ETH × ETH/USD). The gap between the feed and the pool does not create bad debt by itself, because the floor credit holds at *any* price: the NFT is worth at least `credit × unit value` whether the composition follows the pool or the feed. The gap only matters for the liquidator's execution, which the liquidation bonus covers (and the bonus is sized for the same Chainlink lag every Aave reserve has). A TWAP is cheap to move on exactly the shallow pools coverage would add, needs v4 hooks, and lags crashes. A hybrid's "which wins" rule would stop liquidations in the dislocation it detects. *Kept from the opposing side:* the listing analysis it asks for (share of target TVL with Chainlink routes on both tokens) belongs in each pool's ARFC; and the monitor compares feed and pool prices off-chain and alerts.

### Clamp vs no clamp

**Against.** Leaving the band almost always means a regime change (depeg, peg break, crash past 0.345x), and the clamp keeps reporting full value until a human freezes the reserve; a graded haircut would act automatically. Below a USDC/USDT band every vault token is 100% of the falling coin, sold into a one-sided book. Every NFT of a Custom range market leaves the band at once, concentrating liquidation supply where liquidity is thinnest. Reverting or 0 is agreed to be wrong. *Strongest point:* out of band is a regime the band was not sized for, and nothing reacts until a human does.

**For.** The clamp reports the true value of what is held, nothing more: at ETH $541 (0.3x) the Volatile unit is all ETH and priced at $541 per ETH, the same price every other Aave ETH reserve uses. A haircut inside the oracle would be an unvoted risk parameter that liquidates healthy borrowers. The concentration point is real and is handled by caps and the threshold: the DAO's LTV for a Custom range market is set knowing the collateral becomes one token at the band edge (the RiskModule's "lower of the two tokens' LTVs" rule, step 4). Depegs are handled by freezing, which the plan already adopts. *Kept:* the monitor's band-edge alert fires before the edge, not after.

### One oracle per market vs shared

**Against.** A feed used in 30 pools means 60 deployments and 60 repoints, each a week of Aave governance, during which reserves read a frozen price. A pool's two markets can read different feed versions mid-migration, so a user picks the friendlier one. Two markets of one pool read the same feeds twice in a health check (5–10k gas per cold read). 100+ hand-configured deployments are 100+ chances for a wrong route. *Strongest point:* one feed deprecation becomes dozens of week-long governance actions.

**For.** Chainlink announces deprecations months ahead, and an Aave payload repoints any number of reserves in one proposal, so the count of reserves does not change the number of votes. A mutable shared oracle would let one key or one bad update misprice every Avana reserve at once, and would let Avana change an Aave price without an Aave vote; immutability is worth more than the deploy count. Two markets of one pool are deployed in the same listing payload from the same route config, and `feedsOf` makes the check mechanical. The double read costs a few thousand gas only for an account holding both markets. *Kept:* the deployment script checks every oracle's `feedsOf`, `band()` and `tokens()` against the canonical token-to-feed table and the LPVault market before the listing payload is built (step 9).

### No staleness check vs a max-age check

**Against.** Aave V3's no-check rule covers one direct feed; here up to four legs compose one price, some with 24 h heartbeats. With a frozen ETH feed and ETH down 10%, a $10,000 full-range position is worth $10,000·√0.9 = $9,487 but is priced $10,000, a $513 (5.4%) overvaluation that new borrowers can draw against until a repoint a week later. No sequencer-uptime check is visible. Avana's own borrow path can refuse new borrows when a leg is older than 3× its heartbeat while `latestAnswer()` keeps answering, so liquidations never stop; the old flags did exactly that. *Strongest point:* a borrow-only freshness gate blocks the stale-price exploit without any risk to liquidations.

**For.** The oracle is the wrong place: Aave reads only `latestAnswer()`, so any check here either reverts (stopping liquidations) or does nothing. The opposing agent's own proposal puts the check in the borrow path, not the oracle, and that is where it would go. The $513 scenario is the same exposure every Aave reserve priced by that feed has during the same freeze, and the steward freezes reserves on a stale-feed alert. *Kept as an open item:* whether the RiskModule (step 4) gates borrows on leg age and the L2 sequencer feed is decided in the RiskModule's design record; the oracle exposes `feedsOf` so it can.

## Worked examples

Base ETH/USDC, 0.05% pool (tick spacing 10). WETH is token0 (18 decimals), USDC token1 (6 decimals), ETH = $1,803.33 from the ETH/USD feed, USDC = $1.00. Every vault token has 18 decimals, so one whole token is 10^18 liquidity units. Bands: **Full range** ticks [−887,270, 887,270]; **Volatile Custom range** 0.345x–2.898x = ticks [−211,990, −190,700] ($622.09–$5,229.00). **Stable** USDC/USDT ±1% = ticks [−101, 100]. Unit prices are the contract's answers (`LPOracle.unit.t.sol` checks each to one part in 10^9).

**Price of one whole vault token**

| ETH price | Full range | Volatile 0.345x–2.898x | What one Volatile unit holds |
|---|---:|---:|---|
| $1,803.33 (listing) | $84,931,266 | $35,051,327 | 9,719 ETH + $17.5M USDC |
| $1,262.33 (−30%) | $71,058,596 | $28,660,132 | 14,317 ETH + $10.6M USDC |
| $2,705.00 (+50%) | $104,019,133 | $41,670,066 | 5,398 ETH + $27.1M USDC |
| $541.00 (0.3x, below the band) | $46,518,770 | $14,209,079 | 26,265 ETH, no USDC (clamped) |
| $5,770.66 (3.2x, above the band) | $151,929,668 | $47,370,112 | no ETH, $47.4M USDC (clamped) |

Stable USDC/USDT ±1%: $10,024,291,047 per whole token at the peg; $9,993,089,013 with USDC at $0.995; $9,748,297,320 with USDC at $0.97 (below the band: all USDC, clamped). A USDC feed at $1.02 is valued at $1.00.

**$10,000 positions** (collateral = credit × unit price; position = what the NFT holds at that price)

| Position (market) | Credit / L | Listing | −30% | +50% |
|---|---:|---|---|---|
| Full range NFT (Full range) | 100% | $10,000 / $10,000 | $8,366.60 / $8,366.60 | $12,247.45 / $12,247.45 |
| Band-wide 0.345x–2.898x (Volatile) | 100% | $10,000 / $10,000 | $8,176.62 / $8,176.62 | $11,888.30 / $11,888.30 |
| Uniswap "Wide"-like 0.5x–2x (Volatile) | 63.4% | $8,933 / $10,000 | $7,304 / $8,044 | $10,620 / $11,638 |
| Narrow 0.9x–1.1x (Volatile) | 9.0% | $7,571 / $10,000 | $6,191 / $7,201 | $9,001 / $10,232 |

Read as "collateral / position". Collateral never exceeds the position; it equals it for an NFT on exactly its market's band, at any price. Past the band edge it converges to equality (0.5x–2x at ETH $541: $3,621.41 / $3,621.41). Stable ±1%: a band-wide $10,000 NFT is $10,000 / $10,000 at the peg and $9,724.68 / $9,724.68 with USDC at $0.97; a ±0.5% NFT gets 49.75% of L as credit and $9,987 / $10,000 at the peg.

**What the borrower sees.** At an LTV of 70% the full-range $10,000 NFT borrows up to $7,000. At −30% its collateral is $8,366.60, so a $7,000 debt is at 83.7% of collateral and liquidation starts at the DAO's threshold; at +50% the room grows to $8,573. The narrow NFT borrows 70% × $7,571 = $5,300 at listing: the floor credit trades borrowing power for a guarantee that holds at every price.

## Final reasons

1. **Chainlink, never the pool.** A flash loan cannot move it, Aave already trusts it for every other reserve, and the floor credit makes the pool-vs-feed gap harmless to solvency.
2. **Clamp to the band.** It is the AMM's real composition, so the price is exact outside the band, never negative, never zero; risk past the edge belongs to the LTV, the threshold and the steward's freeze, all Aave-native.
3. **One immutable oracle per market.** Aave's one-source-per-reserve model, no roles, no state, and the band read from the LPVault so price and credit cannot describe different liquidity.
4. **Only `answer > 0`.** Aave reads nothing else; a revert on age would stop liquidations. A borrow-side age gate, if any, belongs in the RiskModule.
5. **Rounding down everywhere, floor of 1.** The fuzz bound `credit × answer ≤ position value` holds through the deployed contract; the floor of 1 keeps Aave reading a misconfigured market instead of freezing it.

## Open item

- RiskModule (step 4): decide whether new borrows stop when a feed leg is older than a multiple of its heartbeat, or when the Base sequencer-uptime feed reports downtime. The oracle exposes `feedsOf(index)` for that rule.
