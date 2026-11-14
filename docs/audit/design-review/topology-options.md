# Deployment topology for LP-collateral Borrow Spokes

Date: 2026-11-10. Question: how to map LP markets onto Aave V4 Borrow Spokes. Inputs: the 1,000-user simulation (`docs/audit/user-simulation/avana_sim/`) run with a new topology option, the listing steps of [3.8 Market Lifecycle](../../spec/03-operations/08-market-lifecycle.md) and the Hub rules of [2.1](../../spec/02-contracts/01-avana-hub-and-spokes.md). Runs: [`SIM-R7`](../user-simulation/RUNS.md).

## Recommendation

**Use T2: several markets per Borrow Spoke, one Spoke per (chain, AMM protocol, risk tier).** Do not open the cross-Hub credit line (T3) at launch.

Reasons, from the numbers below:

1. **Bad debt and supplier loss do not separate the options.** In the four specified scenarios (DAI to 0.92, USDT to 0.95, an 80% exit-depth crunch, both depegs at once) no account in any topology was liquidated and no bad debt arose: a stable LP at a collateral factor of 0.312 opened at HF ≥ 1.10 survives an LP drop of about 9%, which needs one token below about 0.83. In the tail case (DAI fails to 0.05 in one hour) bad debt was $8.1k in T1 and $6.7k in T2, 0.27% and 0.22% of the $3M Hub reserve, with overlapping ranges, and the First-Loss Reserve absorbed all of it in every run.
2. **T1 costs about 2.4 times as much governance work for each new market** (38 actions plus 2 for every Spoke already on the Hub, against 16), and fragments the credit line into more draw caps: 29 `DrawCapExceeded` refusals before the shock in T1 against 4 in T2, with the same people and the same total line.
3. **T2's cost is a wider blast radius, and that cost can be limited.** A market that fails takes the other markets of the same account with it: healthy collateral was blocked from borrowing and withdraw-with-debt for 6 to 69 million USD-hours per scenario. During an 8-hour oracle outage on DAI/USDC, 11.4 accounts on average (0 to 28) were liquidated through their healthy USDC/USDT collateral, an outcome T1 cannot produce. In the tail case the deficit breaker blocked four times as much collateral (1,720 against 427 million USD-hours) because it trips per Spoke. The grouping rule and the two decisions in the [last section](#what-t2-needs) limit this.
4. **T3 puts Stable Hub suppliers behind volatile collateral, with no matching gain.** Under a 40% WETH crash in 3 hours, 11.2 Volatile-Spoke accounts were liquidated and none left bad debt. Stable Hub exposure is bounded only by the Volatile Spoke's USDC draw cap ($200k, 6.7% of the Hub reserve), which is four times the assumed $50k USDC First-Loss Reserve. That breaks the tail term of `SPEC-CAP-007` unless the reserve is raised to match the cap.

## The options

| | T1: one market per Spoke | T2: several markets per Spoke | T3: cross-Hub credit line |
|---|---|---|---|
| Spokes in the model | `A:USDC/USDT`, `A:DAI/USDC`, `B:USDC/USDT` | `A:Stable` (USDC/USDT, DAI/USDC), `B:Stable` (USDC/USDT-B) | T2 plus `V:Volatile` (WETH/USDC), which borrows USDC from the Stable Hub |
| Accounts per person | one per market | one per Spoke | as T2, plus one on `V:Volatile` |
| Health factors per person | one per market | one per Spoke | as T2 |
| GHO / USDC draw caps | 0.9M/0.45M, 0.6M/0.3M, 0.5M/0.25M | 1.5M/0.75M, 0.5M/0.25M | 1.5M/0.6M, 0.5M/0.2M, V: 0/0.2M |

Chain A carries two pools of AMM protocol A (USDC/USDT, DAI/USDC). Chain B carries one USDC/USDT pool of AMM protocol B. A Spoke lives on one chain, so the chain-B market has its own Spoke in every option. Each option splits the Stable Hub's credit lines (GHO 2,000,000, USDC 1,000,000) over its Spokes in proportion to expected demand, with the draw caps summing to the line as `SPEC-HUB-003` requires.

## Method

**Engine.** The existing 1,000-user engine is used unchanged in its rules and gets two new options, `Sim(topology=..., scenario=...)`. The base runs are untouched: after the change the base variant still prints the fingerprint `b32c4c5cdc21307b` of `SIM-R5`. What the options change:

- **Markets** (`params.TOPO_MARKETS`). USDC/USDT (cap $8M, CF 0.312) and DAI/USDC ($5M, 0.300) on chain A, USDC/USDT-B ($4M, 0.312) on chain B, and for T3 WETH/USDC ($5M, CF 0.39 = min(0.80, 0.78) × poolRiskFactor 0.50). The WETH/USDC market skips the stable ceiling and the USD band, and its price-drop breaker is 15% and its TWAP tolerance 300 ticks.
- **Accounts.** A person whose markets sit on two Spokes becomes two users, one per Spoke. Each keeps the person's behaviour, check rhythm and arrival, and takes the share of size, cash, spare funds and guardian funds that its markets carry. A Spoke accepts only its own markets.
- **Draws.** Each Spoke's draw, its debt plus its uncovered deficit, is checked against its own draw cap as well as the Hub line. The SettlementBudget caps and the deficit breaker apply per (Spoke, debt reserve), as in `MKT-054` and 1.5.
- **People.** The same 985 people (same RNG draws) appear in every topology, choosing markets with weights 0.45 / 0.30 / 0.25. T3 adds 150 WETH/USDC LPs who borrow USDC; they are drawn from their own RNG, so the stable people stay identical.
- **No attackers.** There are no attackers, probes or pauses; only the scenario's shock acts.

**Scenarios** (`world.SCENARIOS`). The calm path is 40 days long and the shock starts on day 25. About three quarters of the people have arrived by then.

| Scenario | Shock |
|---|---|
| `calm` | none (control) |
| `dai-depeg` | DAI 1.00 → 0.92 in 6 h, held 1 day, back to 0.995 by day +4 |
| `usdt-depeg` | USDT 1.00 → 0.95, same shape; hits both USDC/USDT pools |
| `pool-crunch` | DAI/USDC: other LPs' liquidity and the exit depth of its seized collateral −80% for 5 days |
| `two-pool` | DAI → 0.92 and USDT → 0.95 at once |
| `oracle-stale` | every DAI route, the standby included, stops for 8 h while DAI drifts to 0.96, so DAI/USDC goes Cached and then Expired |
| `dai-crash` (tail) | DAI → 0.50 in 8 h, 0.70 by day +6 |
| `dai-failure` (tail) | DAI → 0.05 in 1 h, no recovery |
| `eth-crash` (T3 only) | WETH −40% in 3 h, −30% by day +6 |

Outside a shock, a stable token more than 1% off peg loses its primary route and trades on 10% of normal depth.

**Metrics.**

- **Bad debt.** Debt written off as deficit, plus debt left on accounts that are underwater at the end. As a share of the Hub reserve: of $3M.
- **Supplier loss.** Bad debt beyond the First-Loss Reserve (GHO 100,000 from 1.5; USDC 50,000 assumed).
- **Contagion.** An account liquidated on market *m* although *m* alone was healthy. "Alone" splits the account's debt over its markets in proportion to their CF-weighted value at peg, so *m*'s own health factor is `served_m / 2 × HF_peg`; the account counts when that is ≥ 1.
- **Keeper load.** The largest collateral value, and the largest number of calls, settled in one keeper scan, all of which the model lands in one block.
- **Capital efficiency.** Measured just before the shock:
  - debt ÷ borrow capacity at `minOpeningHealthFactor`;
  - shock-safe debt ÷ capacity, where shock-safe debt is the largest debt that keeps HF ≥ 1 after any one of DAI or USDT falls to 0.80, on the account's own collateral (this is where cross-collateral pays);
  - `DrawCapExceeded` refusals.
- **Blocked collateral.** USD-hours of collateral in indebted accounts whose borrow and withdraw-with-debt a market's state, price age or breaker blocks. It is split into collateral of the blocking market and healthy collateral of other markets in the same account. A separate figure counts collateral on a Spoke whose deficit breaker tripped.

**Seeds and runtime.** 5 seeds (20261109–20261113) per topology and scenario, 125 runs, 2,509,764 to 2,527,680 invariant checks per scenario, 0 violations. Wall time was 12 min 40 s on 8 processes. The machine was also running another verification job at the time; the 3,079 CPU-seconds come to about 6.5 minutes on 8 idle cores. Tables give the mean over seeds, with the range in brackets.

## Results

### Specified scenarios

| Scenario | Metric | T1 | T2 | T3 |
|---|---|---|---|---|
| all four (`dai-depeg`, `usdt-depeg`, `pool-crunch`, `two-pool`) | accounts liquidated, bad debt, supplier loss, keeper load | 0 | 0 | 0 |
| `dai-depeg` | healthy collateral blocked by another market (M USD-h) | 0 | 18.6 [11.7–25.0] | 18.7 |
| `usdt-depeg` | same | 0 | 5.7 [3.4–7.9] | 5.4 |
| `two-pool` | same | 0 | 13.9 [8.3–19.1] | 13.2 |
| `pool-crunch` | same | 0 | 0 | 0 |
| `oracle-stale` | accounts liquidated (all through a market healthy on its own) | **0** | **11.4 [0–28]** | 9.2 [0–20] |
| `oracle-stale` | collateral seized / bonus paid by users | $0 / $0 | $22.0k / $1.04k | $24.4k / $1.16k |
| `oracle-stale` | peak keeper settlement in one block | $0 | $13.5k (4.8 calls) | $14.8k (5.2 calls) |
| `oracle-stale` | healthy collateral blocked by another market (M USD-h) | 0 | 12.1 | 12.0 |

The pool crunch changes nothing on its own. No price moves, so no health factor moves and nothing is seized. Avana's full-range positions stay a small share of the pool's concentrated in-range liquidity even at −80%, so the pool-share breaker does not trip either. Exit depth matters only once liquidations happen, which the tail cases below cover.

The oracle outage is where the options differ. Once DAI/USDC is Expired its served price is 1 (10⁻⁸ USD per vault token, `REQ-ORACLE-085`) and LPVaultSwap does not seize it. In T2, an account that also holds USDC/USDT has its health factor fall below 1 and is liquidated through the USDC/USDT collateral, which is healthy. That is the rule as written in `SPEC-ORC-017`: "a stale or disagreeing market waits while the account's fresh markets are liquidated against it". In T1 the DAI/USDC account has no other market, so nothing can be seized; it waits out the outage and the 30-minute grace window, and recovers with the price.

### Tail sensitivity

| Metric | T1 | T2 | T3 |
|---|---|---|---|
| `dai-crash`: accounts liquidated | 29.6 [15–44] | 28.8 [11–38] | 26.2 |
| `dai-crash`: bad debt | $0 | $0 | $0 |
| `dai-failure`: accounts liquidated | 110 [64–160] | 119 [58–158] | 109 |
| `dai-failure`: through a market healthy on its own | 0 | 10.4 [3–18] | 10.6 |
| `dai-failure`: bad debt | $8.1k [0–29.3k] | $6.7k [0–20.9k] | $9.2k |
| `dai-failure`: bad debt / Hub reserve | 0.27% | 0.22% | 0.31% |
| `dai-failure`: supplier loss beyond First-Loss Reserve | $0 | $0 | $0 |
| `dai-failure`: peak keeper settlement in one block | $412k (99 calls) | $373k (100 calls) | $415k (90 calls) |
| `dai-failure`: liquidation bonus paid by users | $23.4k | $22.3k | $23.4k |
| `dai-failure`: collateral on a Spoke with a tripped deficit breaker (M USD-h) | 427 | 1,720 | 1,720 |
| `eth-crash` (T3): Volatile-Spoke accounts liquidated / bad debt | – | – | 11.2 [5–16] / $0 |

Cross-collateral lowers bad debt a little: the healthy market in a T2 account covers part of what the failed market cannot, $6.7k against $8.1k. The price is that 10 accounts on average lose healthy collateral to cover it. The ranges overlap, so the bad-debt difference is not significant at 5 seeds. Peak keeper load per block is the same in all three options: it is set by how many accounts hold the failing token, not by how they are grouped.

### Capital efficiency (before the shock, same people)

| Metric | T1 | T2 | T3 |
|---|---|---|---|
| Accounts (PositionProxies) | 626 | 600 | 713 |
| Debt / borrow capacity | 53.0% [50.1–54.6] | 53.1% [48.9–56.2] | 51.0% |
| Shock-safe debt / capacity | 98.4% | 98.5% | 98.5% |
| `DrawCapExceeded` refusals | 29 [0–65] | 4 [0–19] | 116 [79–200] |
| User gas, whole run | $65.2k | $63.7k | $76.1k |

Aave V4 gives no capacity for diversification: capacity is the sum of collateral value × CF in both T1 and T2, so the same people use the same share of it. Cross-collateral shows up only in shock-safe capacity, and only for people whose markets hold different tokens. Here that is +0.1 point overall, because most multi-market people hold the two USDC/USDT pools, which share USDT. For one person with two equal markets on different tokens the gain is 5.9% (0.947 against 0.894 of the post-shock collateral value, at an LP drop of 10.6% on one market). T1's extra draw caps strand line on full Spokes while others have room. T3's Volatile Spoke filled its $200k USDC cap within days, which accounts for its 116 refusals.

## Governance and deployment cost per new market

Counted from `MKT-018`, `MKT-023`, `MKT-026`, `MKT-044`, `MKT-054`, `SPEC-HUB-003` and `REQ-HUB-044`, for a market whose tokens are already listed.

| Item | Actions |
|---|---|
| **Market part** (every option) | **16** |
| Aave listing AIP: `addAssetWithDecimals`, fee-receiver caps at 0, `addSpoke` for the vault-token asset, `addReserve` (CF, bonus, LPOracle source) | 4 |
| Avana normal-delay batch: `deployVaultToken`, `registerMarket`, `setInitialMarketParams`, `setInitialMarketCaps`, route depth thresholds, `setRoute` × 4 (primary and backup for two tokens), `setInKindAutoTrigger` | 10 |
| LPOracle deployment; `activateMarket` at the short delay (plus the manifest and fork check off-chain) | 2 |
| **Spoke part** (a new Borrow Spoke on an existing Hub, GHO and USDC debt) | **22 + 2 per existing Spoke** |
| Aave: deploy the liquidation-manager Spoke and its AaveOracle, register it, list the GHO and USDC debt reserves, `addSpoke` with a draw cap for GHO and for USDC, `LiquidationConfig`, guardian freeze/pause roles, `riskPremiumThreshold` / `spokeUserReservesLimit` | 9 |
| Aave: lower the GHO and USDC draw caps of every existing Spoke so the sum stays within the line (`SPEC-HUB-003`) | 2 × existing |
| Avana: `approveSpoke`, `setLiquidationExpectations`, `approveDebtReserve` × 2, `setBuyRoute` × 2 and `setSellBackRoute` × 2 for USDC, `setBuySlippageAllowanceBps` and its minimum, `SettlementBudget.loosenCaps` × 2 | 12 |
| Keeper, indexer, monitoring and manifest set-up for the new Spoke | 1 |

| Option | Governance actions per new market | Draw caps on the Hub | Proxies per person |
|---|---|---|---|
| T1 | 16 + 22 + 2(n − 1) = **38 to 56** for the 1st to 10th Spoke on the Hub | 2 per market | one per market (a first pledge costs 900k gas against 480k, about $25 more at 20 gwei and $3,000 ETH) |
| T2 | **16** (plus 2 draw-cap changes if the Spoke's line is resized) | 2 per Spoke | one per Spoke |
| T3 | the first volatile market 16 + 22 + 2 × (Stable Spokes) ≈ **42**, each later one 16, plus a USDC First-Loss Reserve sized to the cross-Hub cap | +1 USDC cap on the Stable Hub | one more |

A new chain needs its own Hub, Lend Spoke, Coverage Spokes, credit lines and Avana contract set in every option, so chain B costs the same in each.

## What T2 needs

1. **Grouping rule.** One Spoke per (chain, AMM protocol, risk tier). Put in one Spoke only markets whose price inputs share the same feeds and so fail together, or accept that they spread failure to each other. The Stable Spoke on chain A should list USDC/USDT and DAI/USDC only if a DAI feed outage taking USDC/USDT collateral is acceptable. The deficit breaker and the SettlementBudget windows act per Spoke, so a Spoke is also the unit that stops borrowing after a deficit.
2. **Expired collateral inside a cross-collateral account.** Under `SPEC-ORC-017` and `REQ-ORACLE-085`, an Expired market counts at 1 and the account's fresh markets are seized. In the 8-hour DAI outage that liquidated up to 28 accounts that were healthy at every real price. The options at review time were: keep the rule (it is conservative for the Hub); value an Expired market at its last accepted price × a haircut for a bounded time before it drops to 1; or hold liquidation of an account whose only reason for HF < 1 is an Expired market until the market recovers or a longer timer runs out. Decision: each market has its own Aave account, one PositionProxy per (CDP Spoke, market), so nothing is cross-collateralized and an Expired market never seizes another market's collateral (`Q-280`).
3. **Deficit breaker scope.** A deficit on one market stopped borrowing for every account on the Spoke in this model. Decision: the deficit breaker is keyed per (CDP Spoke, debt reserve) and stops new borrowing of that debt reserve (`Q-399`).
4. **T3 (cross-Hub credit line).** Safe only with a USDC draw cap no larger than a funded USDC First-Loss Reserve on the Stable Hub (the tail term of `SPEC-CAP-007`); the cross-Hub lines must stay within the funded balance of the funding Hub's Coverage Spoke (`REQ-FLR-043`). A Volatile Hub that funds its own USDC carries none of this risk for Stable Hub suppliers.

## Limits of the model

- **People are behaviour models.** A T1 person's accounts act separately, each with its share of the person's cash, which slightly understates how a careful person would move funds between their own accounts. People react on their check rhythm, so the tail results depend on keeper scan frequency (every 10 minutes) as much as on topology.
- **Capacity numbers are not tuned.** Caps, CFs, pool depths, demand weights and draw-cap splits are assumptions sized like the base run, and the debt-to-capacity ratio carries ±3 points of seed noise.
- **Keeper load is an upper bound.** Every liquidation of one keeper scan is counted in one block.
- **Cross-chain operation is not modelled.** The chain-B Spoke draws on the same Hub reserve in the model. In practice it has its own Hub, and GHO reaches it through a cross-chain path.
- **Dust fix.** The engine now skips a liquidation whose repay or seizure is below 10⁻⁶ USD. Before this, an account left with dust collateral and debt was "liquidated" for zero every scan and its debt was never written off. The base runs never reach this path; their fingerprint is unchanged.

## Reproduce

```
docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --topology --seeds 5 --jobs 8
```

Output: `docs/audit/user-simulation/results/topology/summary-<topology>-<scenario>-<seed>.json`, `aggregate.md` (every metric, every scenario) and `aggregate.json`.
