# Avana user simulation: 1,000 users over 90 days

We simulated 1,000 users and bots, each following one LP's journey through Avana for 90 days: pledge, borrow, repay, collect fees, withdraw, get liquidated and exit. The protocol is modelled at the level of the spec's rules, and the 90 days include calm periods and six stress episodes.

**Main findings**

- **No unexpected losses.** No LP lost funds through unexpected protocol behaviour. All 440,947 invariant checks of the base run passed (every other seed and variant also had 0 violations), there was no bad debt, and every exit a user wanted finished, including exits during Paused, Cached and Expired.
- **Losses users did take.** The only losses were Aave's liquidation bonus ($310 in total in the base run) and gas. Gas is the larger cost by far.
- **Twelve rule-level problems.** We found twelve spec gaps, listed in priority order in section 4. The three most serious:
  - The borrow price-age limit equals the feed heartbeat.
  - The fixed 1-GHO recovery-floor allowance pushes keepers into thousands of dollars of gas for tiny liquidations.
  - The pool-share cap refuses rescue top-ups exactly when a depeg empties concentrated liquidity.
- **Current base run (`SIM-R12`, 2026-11-10).** After the parameter decisions `Q-395`…`Q-401` (no SettlementBudget, no in-kind settlement, no on-chain health floors, the redesigned breakers, `keeperFloor` 1): 572,608 invariant checks, 0 violations, 98 liquidation calls on 84 accounts, $0 bad debt and $0 supplier loss, $557 of liquidation bonus; the keeper paid every rounding gap through its shortfall top-up (55 calls, $319). Section 7.9.
- **Previous base run (`SIM-R11`, 2026-11-10).** With one account per wallet and market, liquidations flash-funded through the Aave V3 Pool (5 bps premium) and paid out in the debt asset, no minimum debt (`Q-381`), and gas at current mainnet prices (0.1–1.2 gwei calm, 5–10 gwei on shock days, 30 gwei on the worst crash day, ETH $2,080, from the Etherscan gas tracker of 2026-11-10): 546,706 invariant checks, 0 violations, 99 liquidation calls on 86 accounts, $0 bad debt and $0 supplier loss, $689 of liquidation bonus. 485 people borrow. Avana's own keepers spend $9,552 of gas, $96 per liquidation; $3,869 of it (40.5%) goes to the 40 dust-attack liquidations. Keeper loss after keeper reward is $9,762 (was $116,799 at the old 14–250 gwei path in `SIM-R10`). Sections 7.7 and 7.8.
- **What users dislike most is product shape, not bugs.** The top complaints are full-range-only positions, an effective LTV near 28%, full markets and gas.

## 1. How to run

From the repository root (Python 3.9, standard library only, no numpy):

```
docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py                 # base + 2 variants, ~70 s
docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --extra-seeds 4  # + 4 more base seeds, ~2.5 min
docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --only base      # base only, ~25 s
```

- **Seed.** The default seed is `20261109`. The same seed and variant always produce the same output.
- **Fingerprint.** The runner prints a sha256 of each summary. The current base run (`SIM-R12`, written to `results/final-spec/`) prints `eb8721c3196683b3` (`SIM-R11` printed `751619709834af63`); the run of 2026-11-09 described in sections 2 to 6 printed `202f9f8bb7795922`.
- **Outputs.** Results go to `docs/audit/user-simulation/results/`:
  - `summary-<variant>-<seed>.json` holds every number.
  - `tables-<variant>-<seed>.md` holds every table in this report.

| Variant | What changes |
|---|---|
| `base` | Every primary Chainlink leg has a 1-hour heartbeat, as REQ-ORACLE-054 requires for listing. The app quotes repay-all at the deadline. |
| `mainnet-feeds` | USDC, USDT, GHO and USDe primaries have a 24-hour heartbeat. Several mainnet stablecoin/USD feeds publish that heartbeat at the time of writing; confirm at listing. |
| `literal-repay-quote` | The app approves exactly the quoted debt and uses it as the repay-all cap, which is the literal reading of `webapp/README.md`. |

Code: `avana_sim/params.py` (spec values and assumptions), `world.py` (prices, Chainlink rounds, pools, LPOracle states), `protocol.py` (pledge, borrow, repay, withdraw, collect and liquidation gates), `engine.py` (agents, keepers, governance, probes), `metrics.py` (frustration catalogue), `report.py` (tables).

## 2. Method and assumptions

### 2.1 What is modelled

The simulation is event-driven and runs on a one-minute world grid. The event types are:

- user check-ins;
- transaction inclusions;
- keeper scans every 10 minutes;
- a third-party repay service every 30 minutes;
- governance actions;
- daily invariant checks;
- rule probes.

Each user action is checked twice:

1. **At preparation**, by the app's pre-check. A refusal here costs no gas.
2. **At the block it lands in**, on-chain. A failure here costs 45% of the gas.

Between preparation and landing, the user's signing delay and network delay elapse. Prices, caps, the pause state, nonces and debt can all change in that time.

The rules are taken from the spec:

- **Pledge (3.1).**
  - The pledge is refused under `Paused`. Under `Frozen` it is refused unless the account already has debt.
  - The position must be full range.
  - The price state must suit the account: a new account needs Live, or Drifting caused only by a USD-band breach; a top-up also accepts any Drifting.
  - The value must be at least `minPledgeUsd` ($10).
  - The cap charge is the larger of the oracle price and the $1 stress floor. The market regular budget, the top-up slice (only while HF < 1.10, and only up to the restore amount), the token and depositor caps, and the pool-share cap on time-weighted in-range liquidity all apply.
- **Borrow (3.2).**
  - The pause state must be `None`.
  - The borrow nonce must match.
  - Every collateral market must be Live, and every input must be within `borrowPriceMaxAge` (1 hour). The USDC debt feed must also be within 1 hour.
  - The draw must fit the drawCap / credit line.
  - HF after the borrow must be at least 1.10.
- **Repay (3.3).** Any payer can repay. Repay reads no pause or price state. Repay-all requires the live debt to be at most the cap and covered by the allowance and the balance.
- **Withdraw (3.4).**
  - The whole NFT is withdrawn, and the units must equal the credited units.
  - Debt-free withdrawal reads no state.
  - Withdraw-with-debt applies the RiskModule gates, refuses `Paused`, and requires HF ≥ 1.10 after.
  - `repayAllAndWithdraw` also reads no state.
- **Collect fees (3.7).** The depositor can always collect.
- **Liquidation (3.5).**
  - Aave V4 sizing is used: target HF 1.10; bonus 2% at HF just below 1, rising to 5% at HF 0.90; the $1,000 dust rule with `MustNotLeaveDust`.
  - Collateral is seized largest record first.
  - Gates: no market of the account Cached or Expired; feed-disagreement pause and its expiry; the debt feed within heartbeat + 600 s; recovery grace (HF < 0.95 only for 30 minutes after an Expired outage).
  - The recovery floor is oracle value × (1 − 1%) − 1 GHO. The waterfall is funding → 20% Avana fee → keeper.
  - SettlementBudget caps are 25 per call and 500 per 24 hours.
  - When the floor fails, keepers retry at ½, ¼ and ⅛ size, as `services/README.md` instructs. If routes keep failing, governance schedules `enableInKind`, which takes effect after the 12-hour short delay.
  - Searchers use `liquidatePermissionless`, which has no budget and no in-kind settlement.
- **LPOracle (2.10).**
  - Each token has a primary and an alternate route. A route is fresh while its age is at most its heartbeat + 600 s.
  - Cached begins at the first failure and lasts 1 hour; Expired follows.
  - A disagreement beyond deviation(primary) + deviation(alternate) + 50 bps pauses liquidation for 1 hour, after which the market is treated as Expired.
  - The USD band is 0.90 to 1.02 on uncapped prices.
  - The TWAP guard is 30 minutes and 50 ticks.
  - The price is `2·√(min(q0,1)·min(q1,1))` per whole vault token.

**Accounts.** There is one PositionProxy per wallet; every market and every debt asset share one health factor. Interest accrues every second.

**LP fees.** Fees accrue to each NFT whether it is in the wallet or in the vault. Liquidation never takes fees.

### 2.2 Scenario (the same path for every run; noise depends on the seed)

| Days | Episode |
|---|---|
| 0–8 | Calm |
| 8–10 | GHO trades at $1.047, a premium |
| 18.5–19.6 | Both USDT Chainlink routes stop for 26 h. USDT drifts to $0.985. |
| 30–36 | **USDT depeg:** $1.00 → $0.92 in 6 h, held for 18 h, back to $0.995 by day 36. Gas reaches 80 gwei. The USDT alternate route lags for 72 min. |
| 45–47 | **Liquidity drain:** 85% of the other LPs leave the GHO/USDC pool, and GHO softens to $0.985. On day 47 an attacker holds the pool 0.7% off price for 2.4 h. |
| 60–70 | **50% shock:** USDe goes from $1.00 to $0.50 in 8 h, then $0.70 by day 70. Gas is 250 gwei for 12 h. USDe settlement routes run 3–6% below the oracle for 2.5 days. The USDe routes disagree for 72 min. |
| 75–77.25 | **Governance pause:** Frozen at day 75.0, then Paused from 75.25 to 77.25. During the pause USDe slides from $0.70 to $0.45 and USDT dips 1.5%. |
| 85 | The USDC/USD primary feed stops for 4 h. The alternate route stays fresh. |

### 2.3 Population (985 users, 3 approved keepers, 10 searchers, 2 attackers)

| Persona | Users | Size | Borrows | Behaviour |
|---|---|---|---|---|
| Passive stable LP | 270 | median $8k | 50% | Checks every 1–4 days; collects fees monthly; target HF 1.6–3.0 |
| Active LP | 120 | median $15k | 50% | 70% start with concentrated positions; adds or removes liquidity every 7–15 days |
| Leveraged borrower | 100 | median $20k | all | Target HF 1.11–1.18; 30% press "max"; loops 0–2 times; checks every 1–6 h |
| Small user | 120 | $4–$300 | 60% | 40% on mobile |
| Whale | 20 | $150k–$1.2M | 80% | Arrives early; splits across wallets at the depositor cap |
| Multi-market user | 85 | median $20k | 90% | 2–3 markets in one account |
| Mobile / slow network | 110 | median $5k | 80% | 1–10 min to sign; 12% of transactions take 5–30 min; 3% are dropped |
| Forgets positions | 90 | median $8k | 90% | Stops checking two days after arriving |
| USDC borrower | 70 | median $15k | all, in USDC | Another ~20% of the other borrowers also choose USDC |

The bots are:

- **Keepers** scan every 10 minutes and must liquidate every account below HF 1, reimbursed when they make a loss.
- **Searchers** win about 25% of profitable liquidations through the permissionless path.
- **Attacker 1** fills cap room with debt-free wallets and re-levers through the top-up slice.
- **Attacker 2** tries a flash-loan pledge, a direct `liquidationCall`, pledging into a manipulated pool, a liquidity donation, TWAP griefing, and opening 40 dust accounts.
- A **third-party repay service** covers about 5% of borrowers.

### 2.4 Key assumptions

Protocol values come from 1.5 and the flow pages. Everything below is an assumption.

| Assumption | Value | Why it matters |
|---|---|---|
| Collateral factors | 31.2% (USDC/USDT), 30% (GHO/USDC, DAI/USDC), 25.2% (USDe/USDT) | Taken from the worked examples. They drive the LTV complaint. |
| Market caps | $8M / $5M / $4M / $3M, $20M per token, $1M per depositor | About $20M of capacity against roughly $30M of demand. This drives the "market full" count. |
| Credit lines | GHO 2,000,000 (spec); USDC 1,000,000 | GHO ran out in 2 of 5 seeds |
| Gas | 14–22 gwei normally, spikes listed above, ETH $3,000. First pledge 0.9M gas, borrow 0.33M, liquidation 0.95M. | Drives small-user losses and keeper reimbursement |
| Fee APRs for full range | 1.5% / 4% / 1% / 6%; concentrated earns 6–12× more | Drives the concentrated-range complaint |
| Borrow APR | GHO 7.5%, USDC 6.5% (11% on days 60–70) | Interest only |
| Feed delays | 12–75 s normally; 30–420 s when congested | Drives the stale-price windows |
| Other LPs' liquidity per pool | Full range plus ±0.05% to ±5% concentrated buckets | Drives pool-share refusals in depegs |
| App deadline | 15 minutes | Drives `DeadlineExpired` |

### 2.5 Limits

- **Rule level, not code.** This tests how the spec's rules compose along user journeys, not the Solidity code. A pass here does not replace the formal and fork tests.
- **Assumption-driven counts.** Persona mixes, caps and appetite (for example how many LPs hold concentrated ranges, or what LTV users want) drive several counts. Rankings are more reliable than absolute numbers, and the seed ranges in section 5 show the spread.
- **Approximate liquidation sizing.** Aave sizing uses floating-point formulas that match the integer reference in `docs/audit/formal-verification/liquidation/aave_ref.py`, without share rounding.
- **Not modelled:** Aave-side reserve pauses and freezes, Hub halts, unsettled seizures (`pending`), and a faulty LPVaultSwap.

## 3. Outcomes (base, seed 20261109)

### 3.1 Journeys and losses by persona

| Persona | Onboarded / users | Borrowed | Liquidated | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done |
|---|---|---|---|---|---|---|---|---|---|---|
| Passive LP | 174 / 270 | 89 | 0 | $46 | $2 | $83 | $0 | 1.11% | 70% | 38 / 38 |
| Active LP | 65 / 120 | 34 | 2 | $44 | $8 | $282 | $6 | 2.06% | 91% | 23 / 23 |
| Leveraged | 71 / 100 | 70 | 5 | $170 | $49 | $339 | $26 | 1.93% | 77% | 34 / 34 |
| Small | 51 / 120 | 24 | 1 | $1 | $0 | $81 | $0 | **46.4%** | 100% | 13 / 13 |
| Whale | 18 / 20 | 15 | 0 | $2,700 | $867 | $250 | $0 | 0.05% | 0% | 3 / 3 |
| Multi-market | 80 / 85 | 67 | 2 | $81 | $21 | $133 | $24 | 0.82% | 75% | 19 / 19 |
| Mobile | 67 / 110 | 44 | 3 | $33 | $8 | $96 | $27 | 1.50% | 81% | 17 / 17 |
| Forgets | 57 / 90 | 52 | 14 | $55 | $28 | $66 | $220 | 0.84% | 58% | – |
| USDC borrower | 48 / 70 | 48 | 1 | $87 | $34 | $124 | $5 | 0.98% | 73% | 20 / 20 |

- **Onboarding.** 631 of 985 users onboarded. The other 354 gave up, mainly because their market was full (294 users met a full market at least once) or because they would not convert a concentrated position (40% of the 377 who held one).
- **Exits.** All 167 exits users wanted finished:
  - 117 by `repayAllAndWithdraw`;
  - 189 debt-free withdrawals;
  - 26 users first had to find outside funds to repay.

  The other four seeds also had no stuck exits (152/154, 162/162, 155/157 and 161/160 done/wanted).
- **Losses.**
  - "Avana cost > LP fees" means the user spent more on Avana gas than the position earned in Uniswap fees over the 90 days. LP fees are earned anyway; Avana neither adds to them nor takes them.
  - Gas is the main cost, not liquidation. The liquidation bonus across all users totalled $310 ($45–$780 over 5 seeds).
  - There was no bad debt in any run.
  - The **unexpected protocol loss is $0**. Per NFT, live liquidity = initial + donated − seized, and fees accrued = collected + owed. Per account, debt = borrowed + interest − repaid − liquidated − written off. All three held at every daily check.

### 3.2 Liquidations

| Measure | Base | 5 seeds |
|---|---|---|
| Liquidation calls / accounts | 151 / 68 | 33–151 / 31–68 |
| Debt repaid | $12,842 | $1,620–$18,099 |
| Bonus paid by borrowers | $310 | $45–$780 |
| Calls repaying under $100 | 135 | 31–135 |
| Keeper gas reimbursed | $104,733 | $24,576–$104,733 |
| Deficit (bad debt) | $0 | $0 |
| Liquidation blocked: RecoveryBelowFloor | 81 account-hours, 13 accounts | 21–81 h |
| Liquidation blocked: disagreement pause / expiry | 3.5 h / 1.0 h | |

- **When.** 143 calls happened in the USDe crash and 8 during the pause, all eight against forgetful users' accounts. USDT depeg: 0 liquidations. USDT outage: 0.
- **Who.** Approved keepers made every call. The permissionless path was never profitable after gas: searchers made $0 and extracted no sandwich value.
- **In-kind.** In-kind settlement took 8 liquidations after governance enabled it on day 60.76, 12 hours after scheduling.

### 3.3 Failed transactions

On-chain failures (gas paid):

| Action | Error | Count | Users |
|---|---|---|---|
| borrow | `HealthFactorTooLow` (HF fell below 1.10 between preview and inclusion) | 36 | 18 |
| borrow | `PriceTooOld` (landed in a stale-feed window) | 17 | 16 |
| borrow / pledge / repay / withdraw / collect | `DeadlineExpired` | 30 | 28 |
| any | dropped (never mined) | 16 | 16 |
| borrow | `BadNonce` (second tab or device) | 4 | 4 |
| pledge | `CapExceeded`, `SliceNotAvailable` (cap filled meanwhile) | 3 | 3 |

App pre-check refusals (no gas):

| Action | Reason | Count | Users |
|---|---|---|---|
| pledge | `CapExceeded(market)` | 1,001 | 272 |
| pledge | `NotFullRange` | 385 | 377 |
| borrow | `PriceNotLive(Drifting: USD band)` | 2,295 | 23 |
| pledge | `PoolShareExceeded` | 116 | 69 |
| pledge | `PriceNotAccepted(Cached/Expired)` | 111 | 21 |
| pledge | `SliceNotAvailable` (indebted, HF ≥ 1.10, market full) | 90 | 21 |
| borrow | `DrawCapExceeded` | 89 | 46 |
| withdraw (part of a rebalance) | `HealthFactorTooLow` | 71 | 28 |
| borrow | `ApplicationPaused` / `ApplicationFrozen` | 66 | 32 |
| borrow | `PriceTooOld` | 33 | 33 |
| top-up | `PoolShareExceeded` / `SliceNotAvailable` / `ApplicationPaused` | 10 | 9 |

In the `literal-repay-quote` variant, repay-all fails **226 times out of 226 first attempts** with `RepayAllAboveCap`, across 113 users. The `mainnet-feeds` variant refuses 75,746 borrow attempts from 455 users with `PriceTooOld`.

### 3.4 Borrow availability (share of time the price gates pass)

| Market | base | mainnet-feeds |
|---|---|---|
| USDC/USDT | 94.4% (4.6% blocked by price age) | **0.1%** |
| GHO/USDC | 94.0% (2.0% blocked by band) | **0.05%** |
| DAI/USDC | 95.6% | 4.0% |
| USDe/USDT | 62.7% (USD band breached for 30 days after the crash) | 0.1% |
| USDC debt feed | 97.7% | 4.1% |

### 3.5 Every path in every state: probes against the 3.6 emergency matrix

Each probe ran at the given time against a probe account with USDC debt and two NFTs, plus a debt-free account. Every state gate matched the matrix. The only differences were refusals by caps: the matrix opens the path, but a cap closes it.

| State (market, day) | New pledge | Top-up | Borrow | Repay | Collect | Withdraw, no debt | Withdraw with debt | Repay-all + withdraw | Liquidation |
|---|---|---|---|---|---|---|---|---|---|
| Live (USDC/USDT, 5.0) | Y | Y | Y | Y | Y | Y | Y | Y | Y |
| USD band breach (GHO/USDC, 9.0) | *pool share* | *pool share* | N | Y | Y | Y | N | Y | Y |
| Frozen alternate, Drifting by TWAP (USDC/USDT, 18.75) | N | Y | N | Y | Y | Y | N | Y | **Y, at a frozen price** |
| Cached (USDC/USDT, 18.9) | N | N | N | Y | Y | Y | N | Y | N |
| Expired (USDC/USDT, 19.2) | N | N | N | Y | Y | Y | N | Y | N |
| Grace (USDC/USDT, 19.61) | Y | Y | Y | Y | Y | Y | Y | Y | N (HF ≥ 0.95) |
| Feed disagreement (USDe/USDT, 60.21) | N | *pool share* | N | Y | Y | Y | N | Y | N |
| Disagreement past 1 h (USDe/USDT, 60.25) | N | *pool share* | N | Y | Y | Y | N | Y | N |
| USD band breach (USDe/USDT, 66) | *pool share* | *pool share* | N | Y | Y | Y | N | Y | Y |
| Frozen (USDC/USDT, 75.1) | N | *slice* | N | Y | Y | Y | Y | Y | Y |
| Paused (USDC/USDT, 76.0) | N | N | N | Y | Y | Y | N | Y | Y |
| USDC debt feed stale (USDC/USDT, 85.1) | *cap* | *slice* | N (alternate too old) | Y | Y | Y | N | Y | N (`DebtPriceStale`) |

### 3.6 Invariants

**440,947 checks in the base run, 0 violations.** Every other seed and variant runs its own count of checks, also with 0 violations (see `results/summary-*.json`). The invariants checked:

- backing: supply = credited + pending;
- credited = sum of records;
- each record's live liquidity ≥ credited units;
- custody if and only if a record is open;
- liquidity conservation per NFT;
- fee conservation per NFT;
- debt conservation per account;
- Hub drawn = sum of debts;
- regular and slice counters within their caps;
- GHO conservation in every liquidation;
- HF ≥ 1.10 after every borrow and every withdraw-with-debt;
- the probe matrix in section 3.5.

### 3.7 Stuck or idle funds at day 90

| Kind | USD | Users |
|---|---|---|
| Liquidity added to pledged NFTs that is never credited. It returns with the NFT; nothing is lost. | $45,052 | 11 |
| Uncollected fees in the vault. Claimable at any time. | $21,670 | 455 |
| Forgetful users still open with debt. Idle, not stuck. | – | 47 |
| Collateral of users unable to exit at the end | $0 | 0 |
| NFTs with zero credit never released | $0 | 0 (no record was fully seized) |

### 3.8 Attacks

| Attack | Result |
|---|---|
| Flash-mint LP → pledge → borrow max → withdraw in one transaction | The transaction fails: withdraw-with-debt needs HF ≥ 1.10 after, and a borrow of at most ~28% cannot repay the flash loan. No loss. |
| Direct `Spoke.liquidationCall` | `Unauthorized()`, as stated in LIQ-055 |
| Pledge while the pool is pushed 2% off peg | Refused with `PriceNotAccepted(Drifting)`. Credit is liquidity valued from Chainlink, so manipulation adds no value. |
| Donating liquidity to a victim's pledged NFT | No effect on credit, HF or withdrawal. The liquidity goes to the victim. |
| TWAP griefing in the drained GHO/USDC pool (0.7% for 2.4 h) | Borrow and withdraw-with-debt are blocked for the market's holders; liquidation is unaffected. Estimated cost about $0.7M, so it is uneconomic at the simulated depth. |
| Cap squatting with debt-free filler wallets | Took every reopening of USDC/USDT regular room: 77 times, $0.98M in total. The cost is gas only, and the squatter keeps earning LP fees. |
| Slice re-leverage: top up from the slice on dips, then borrow back to 1.10 | $35k–$42k of slice used for growth across 5 seeds (gap 8) |
| 40 dust accounts of $10.60 at HF 1.10 | The attacker spent $2,750 in gas. Liquidating them at 250 gwei cost keepers **$31,050** to repay $98 (gap 10). |

## 4. Bugs and spec gaps (by priority)

### 1. High — the borrow price-age limit equals the heartbeat

**Rule.** `borrowPriceMaxAge` = 3,600 s (1.5). REQ-ORACLE-054 allows a primary heartbeat up to `borrowPriceMaxAge`. BOR-006 and WDR-007 refuse any input older than that.

**What happened.**

- A heartbeat round lands 12–75 s after the previous one turns 3,600 s old, and up to 7 minutes later in congestion. Every hour, each leg is therefore stale for a short gap.
- With two legs per market, borrow and withdraw-with-debt were refused 4.0–4.6% of the time.
- 33 users were refused in the app. 16 users signed a valid borrow that reverted on-chain because it landed in a gap.
- If the listed feeds have 24-hour heartbeats (`mainnet-feeds`), borrowing works 0.05–4% of the time and borrowers fall from 443 to 117.

**Recommended spec change.**

- Require `heartbeat ≤ borrowPriceMaxAge − 600 s` for every primary leg (or set `borrowPriceMaxAge = heartbeat + 600`), the same margin `liquidationPriceMaxAge` already has.
- Record each leg's published heartbeat in the listing payload.
- State in 3.8 that a market whose USD feeds publish 24-hour heartbeats cannot be listed until a faster route exists.

### 2. High — the fixed 1-GHO floor allowance turns stressed liquidations into gas burn

**Rule.** The recovery floor is `V(1−s) − U − floorRoundingAllowanceGho`, with s ≤ 1% and a fixed allowance of 1 GHO (LIQ-030, 1.5). `services/README.md` tells keepers to "retry with a smaller size". In-kind settlement needs `enableInKind`, a 12-hour short-delay operation.

**What happened.**

- During the USDe crash the routes ran 3–6% below the oracle, so every full-size call failed `RecoveryBelowFloor`.
- Chunks of roughly $50–$200 pass, depending on the discount, because the fixed $1 covers the extra loss.
- Keepers made 135 calls under $100 (median repay $45, up to 17 calls on one account). They spent $104,733 of reimbursed gas to repay $12,842 ($24.6k–$104.7k across seeds).
- 13 accounts still waited 81 account-hours until in-kind settlement opened.
- The borrower's loss is fixed by Aave's bonus whatever the conversion, so the floor protects only the keeper's surplus, the Avana fee and the SettlementBudget.

**Recommended spec change.**

- **(a)** Let the caller cover a route shortfall with its own GHO, testing the floor on `R + K` instead of `R`.
- **(b)** Add a minimum-size or gas rule to the keeper agreement instead of open-ended halving.
- **(c)** Let a pre-approved trigger enable in-kind settlement for a market after RecoveryBelowFloor has persisted for N hours, instead of a fresh 12-hour timelock operation.

### 3. High — the pool-share cap refuses rescue top-ups in depegs

**Rule.** REQ-RISK-023 / SPEC-CAP-005 apply to every pledge, including top-ups. SPEC-CAP-002 promises that "a full market cannot stop an indebted borrower from adding collateral".

**What happened.**

- When USDT depegged (days 30–33), GHO traded at a premium (days 8–9) and USDe crashed and then stayed outside the USD band (days 60–89), the other LPs' concentrated ranges left the price. In-range liquidity collapsed and Avana's full-range share passed 10%.
- 69 users' pledges were refused with `PoolShareExceeded`, including 7 rescue top-ups (1–7 across seeds).
- The probes show top-ups refused in the band-breach and disagreement states, which the 3.6 matrix lists as open.

**Recommended spec change.** Exempt eligible top-ups from SPEC-CAP-005, up to the SPEC-CAP-003 restore amount. Eligible means the account has debt and HF < `minOpeningHealthFactor`. The slice is already exempt from the token and depositor caps in the same way. Alternatively, measure pool share against liquidity in a fixed band around peg instead of in-range liquidity.

### 4. Medium — repay-all sizing and the approval rule are undefined, and the literal reading always fails

**Rule.**

- REP-005: repay-all reverts if the live debt at inclusion exceeds `maxRepaySpend`.
- `webapp/README.md`: the app approves "exactly the repay amount".
- INV-022: no standing approval larger than needed.

**What happened.** Debt accrues every second. With the cap and the approval equal to the quoted debt, 100% of first repay-all attempts revert (226 reverts across 113 users, $3,764 of gas) until users add a buffer by hand. Quoting the debt at the deadline (the base run) gives zero failures.

**Recommended spec change.**

- 3.3 and the app plan state that the quote is `debt × (1 + rate × (deadline − now))` plus a small margin, used for both `maxRepaySpend` and the approval.
- The Adapter pulls `maxRepaySpend` and refunds the unused part (as REP-009 already does for the partial case), so the allowance ends at 0 and INV-022 holds.

### 5. Medium — a joint stall of both routes is seen only after the slow route's heartbeat

**Rule.** `feedMaxAge` = `liquidationPriceMaxAge` = heartbeat + 600 s for each feed (1.5). REQ-ORACLE-054 allows a 24-hour alternate.

**What happened.**

- Both USDT routes stopped. The alternate had last updated 15 hours earlier, so it counted as fresh for another 9.2 hours.
- During those 9.2 hours the market was Live and then Drifting (TWAP) on a frozen price: USDT traded at $0.985, but the oracle served $1.00.
- Liquidation stayed allowed at that price. Cached began only at +9.2 h and Expired at +10.2 h.

**Recommended spec change.** Hold alternate legs to `heartbeat ≤ borrowPriceMaxAge` as well. Alternatively, treat "primary stale and alternate older than `borrowPriceMaxAge`" as Cached for liquidation.

### 6. Medium — debt prices have a single source and no failover

**Rule.** Q-238 gives each debt reserve one Aave oracle source. EMG-020 stops borrowing and liquidation when it is stale.

**What happened.**

- The USDC/USD primary stopped for 4 hours. USDC collateral legs failed over to the alternate and stayed Live.
- 126 accounts with USDC debt could not be liquidated for 2.9 hours, and could not borrow or withdraw-with-debt for 3.1 hours.
- GHO borrowers were unaffected.

**Recommended spec change.** Give each non-GHO debt reserve the same primary/alternate route model as collateral legs, or an Aave fallback source recorded at listing. Add debt-feed stalls to the Q-192 cap-sizing window.

### 7. Medium — the USD band's upper bound blocks GHO markets when GHO trades at a premium

**Rule.** SPEC-ORC-011 tests the band on uncapped prices, with `usdBandHigh` = 1.02. REQ-ORACLE-009 states that "GHO markets stay Live above peg".

**What happened.** GHO at $1.047 makes √(q0·q1) = 1.023. GHO/USDC was Drifting(USD_BAND) for 41.3 hours, so borrowing and withdraw-with-debt were blocked for every holder, exactly when GHO demand is high.

**Recommended spec change.** Test `usdBandHigh` on the capped values, or only when both legs are above peg. Keep `usdBandLow` on uncapped prices.

### 8. Medium — a slice top-up followed by a borrow turns the rescue budget into growth

**Rule.** SPEC-CAP-003 and Q-157 cap slice use at the amount that restores HF 1.10. BOR-007 does not look at slice use. Exits release slice first (SPEC-CAP-004).

**What happened.**

- An account in a full market (USDC/USDT) topped up from the slice on every dip below 1.10, then borrowed back to 1.10. It consumed $35k–$42k of slice in 90 days, and that would grow with volatility.
- Separately, debt-free filler wallets took every reopening of regular room (77 times, $0.98M). They paid gas only and kept earning fees.

**Recommended spec change.** Book the slice part per record. Exclude slice-booked collateral from the borrow-side HF check, or refuse new borrows while the account holds slice-booked units. Decide whether cap squatting needs a response, such as a per-wallet share of newly opened room or an app queue.

### 9. Medium — Paused refuses top-ups while liquidation runs

**Rule.** Q-227, EMG-018, LIQ-002.

**What happened.** In the pause with the USDe aftershock, 8 accounts were liquidated, all held by users who never checked. One attentive user's top-up was refused (0–3 across seeds). Incidence here is low, but the rule removes the cheapest rescue path during exactly the incidents in which liquidations happen.

**Recommended spec change.** Split Paused into two reasons: mint path suspect, which refuses top-ups as now, and anything else, which allows top-ups of indebted accounts. Either way, the app should direct users to repay and to third-party repay, which stay open.

### 10. Low–medium — $10 dust accounts are cheap to open and costly to liquidate

**Rule.** Q-230 sets `minPledgeUsd` = $10. Q-169 sets no minimum debt. Q-098 reimburses keepers.

**What happened.** 40 accounts cost the attacker $2,750 in gas at ~18 gwei. At 250 gwei they cost keepers $31,050 to liquidate, for $98 of debt, all of it reimbursed.

**Recommended spec change.** Make `minPledgeUsd` gas-aware (for example $500–1,000 on mainnet) or add a minimum debt. Alternatively, let keepers defer accounts below a debt threshold and settle them in batches.

### 11. Low — liquidity added to a pledged NFT is never credited

**Rule.** DEP-009 credits liquidity only at pledge (Q-134). Anyone can call `NFPM.increaseLiquidity` on any tokenId.

**What happened.** 25 users (13–25) added liquidity this way, expecting more collateral. Their HF did not change. $45k sat uncredited at day 90; it is not lost.

**Recommended spec change.** Add a re-credit path that tops up an existing record by the new liquidity under the same checks as a top-up, or document it and have the app and integrations warn.

### 12. Low — "max" borrow at exactly HF 1.10 always fails

**Rule.** BOR-011 checks HF after the Spoke call, and interest accrues between preview and inclusion.

**What happened.** 18 users made 36 reverted borrows (5–18 users across seeds).

**Recommended spec change.** 2.17 (Lens) and the app plan size "max" with a stated margin, for example HF 1.10 × (1 + rate × deadline), or +0.5%.

### Also observed

**One account per wallet spreads one market's state to every market.** After the crash the USD band on USDe/USDT stayed breached for 718 hours. The 16 multi-market accounts holding USDe/USDT could not borrow or withdraw-with-debt in any market for 30 days. This is by design (Q-234). Allowing several accounts per wallet (a proxy index) would let users isolate markets.

## 5. User frustrations (ranked by users affected)

The base count comes first, then the range over 5 seeds.

| # | What users would say | Users | Cause in the spec | Fix | Where |
|---|---|---|---|---|---|
| 1 | "My concentrated position was rejected; full range earns far less." | 377 (370–386) | Full range only (Q-017, `NotFullRange`) | Explain before the NFT approval, show the fee difference, offer one-click conversion. Concentrated ranges later. | App now; contracts later |
| 2 | "I can only borrow about $28 per $100 of LP." | 310 (252–310) | CF = min(CF0, CF1) × poolRiskFactor ≈ 25–31%, then HF 1.10 on top | Show the effective limit before pledging. Review poolRiskFactor after a track record. | App, risk |
| 3 | "The market is full." | 294 (294–376) | `marketUsdCap`; debt-free squatters hold room for free | Show cap room, a waitlist or notify-on-room, cap-raise plans | App, governance |
| 4 | "I collect fees and then repay by hand." | 141 (86–141) | Fees go only to the depositor (Q-105) | Batch collect → swap → repay (EIP-5792), or an Adapter helper | App (contracts optional) |
| 5 | "Gas cost more than my position earns." | 81 (76–88) | $10 minimum against $68 of approve + first pledge + borrow at 18 gwei | Show break-even; raise `minPledgeUsd` | App, parameter |
| 6 | "To take out some liquidity I must repay and withdraw the whole NFT." | 63 (52–63) | Whole-NFT withdrawal, units = credited (WDR-014) | A partial-decrease path under the same HF checks | Contracts |
| 7 | "Borrow is blocked though prices look normal." | 61 (41–61) | Gap 1; Drifting(band/TWAP); Cached | Gap 1 fix; the app explains the state and when it clears | Spec, app |
| 8 | "No more GHO to borrow." | 46 (0–93) | 2M GHO credit line (Q-006) | Show the remaining line, suggest USDC, raise with demand | App, Aave governance |
| 9 | "I was liquidated." | 29 (8–29) | HF < 1 | Alerts, liquidation-price preview, rescue paths | App |
| 10 | "I need outside funds to close; I can't repay with my collateral." | 26 (10–26) | No repay-with-collateral; withdraw-with-debt needs HF ≥ 1.10 after | A self-deleverage call (unwind part of the NFT through LPVaultSwap routes to repay, no bonus) | Contracts |
| 11 | "I added liquidity but my HF didn't change." | 25 (13–25) | Gap 11 | Re-credit path or a warning | Contracts, app |
| 12 | "DeadlineExpired." | 24 (24–38) | Deadline on every call; slow signing on mobile | Longer mobile deadlines, automatic re-prepare | App |
| 13 | "I pressed max and it failed." | 18 (5–18) | Gap 12 | Margin on "max" | App, spec note |
| 14 | "My transaction never confirmed." | 15 (10–17) | Network or fees | Fee bumping, pending status | App |
| 15 | "Nobody warned me." | 11 (4–14) | No notification service in `webapp/README.md` | Opt-in HF alerts by email, push or Telegram from the indexer | App, services |
| 16 | "One market blocked borrowing in all my markets." | 7 (1–7) | One proxy per wallet per Spoke, worst-state rule (Q-225, Q-234) | Several accounts per wallet | Contracts, app |
| 17 | "My rescue top-up was refused: pool share." | 7 (1–7) | Gap 3 | Exempt eligible top-ups | Spec |
| 18 | "BadNonce on my second borrow." | 4 (4–9) | One nonce per proxy (Q-106) | A single pending borrow across devices; a clear message | App |
| 19 | "I had to split across wallets." | 3 (1–6) | `depositorUsdCap` per wallet, easy to bypass | Document it or drop it | Governance |
| 20 | "GHO borrowing stopped when GHO was above $1." | 2 (0–2) | Gap 7 | Band on capped prices | Spec |
| 21 | "Top-up refused during the pause, then liquidated." | 1 (0–3) | Gap 9 | Allow top-ups, or direct users to repay | Spec, app |

## 6. Improvements users would ask for (ranked by users who would benefit)

| # | Improvement | Users | Contracts or app |
|---|---|---|---|
| 1 | A pledge screen that states "full range only", shows the fee-yield difference and offers one-click conversion | 377 | App now; concentrated ranges are a contracts change later |
| 2 | Borrow-limit, effective-LTV and liquidation-price preview before pledging and borrowing | 310 + all 443 borrowers | App |
| 3 | Health alerts at user-chosen HF levels, plus "your top-up is blocked; repay instead" prompts | all 443 borrowers; 11 liquidated without having checked | App / services |
| 4 | Cap room, slice room and credit-line room on each market, with notify-when-open | 294 + 46 | App; cap policy is governance |
| 5 | Collect fees and repay in one step | 141 | App (EIP-5792 batch); optional Adapter helper |
| 6 | Partial liquidity removal from a pledged NFT, and re-credit of added liquidity | 63 + 25 | Contracts |
| 7 | Gas break-even warning and a higher minimum | 81 | App, parameter |
| 8 | Repay with collateral (self-deleverage) | 26, plus every looping borrower | Contracts |
| 9 | Plain-language price-state banners (Drifting, Cached, Expired, grace) with what still works | 61 | App |
| 10 | Mobile: longer deadlines, fee bumping, pending-transaction tracking, one pending borrow across devices | 24 + 15 + 4 | App |
| 11 | "Max" with a safety margin | 18 | App (+ spec note in 2.17) |
| 12 | Several isolated accounts per wallet | 7 explicitly; 16 accounts affected for 30 days | Contracts |
| 13 | Debt-feed failover, pool-share exemption for rescues, band on capped prices, gas-aware minimum (gaps 3, 6, 7, 10) | Indirect: every borrower in those markets | Contracts / spec |
| 14 | Show which NFT gets seized first; release zero-credit NFTs automatically | Every liquidated multi-NFT user | App (contracts optional) |

## 7. Re-run against the final spec (2026-11-10)

The simulation was brought up to the final spec, decisions `Q-001`…`Q-278`, and run again with the same 985 users, bots, seeds and price paths. Sections 1 to 6 above record the run of 2026-11-09 against decisions up to `Q-240` and are kept as they were. This section compares the two runs gap by gap. The run log is `SIM-R3` in [RUNS.md](RUNS.md).

### 7.1 What the model now follows

| Area | Rule modelled | Decisions |
|---|---|---|
| Feed ages | `borrowPriceMaxAge = min(heartbeat + 600, 4,200)` per leg; every primary and standby leg has a heartbeat of at most 3,600 s, and a token without such a primary is not listed; while the alternate serves, liquidation of the market needs every alternate leg within its `borrowPriceMaxAge`, else the market counts as Cached for its own seizure | `Q-274` |
| USD band | `usdBandLow` on the uncapped quotes, `usdBandHigh` on the capped prices | `Q-275` |
| Prices by state | The accepted price changes only while Live and values caps, the minimum pledge and the restore amount; Aave reads the served price: fresh when Live, `min(fresh, accepted)` when Drifting, the lower route in a disagreement, the accepted price when Cached, 1 when Expired | `Q-247` |
| Liquidation gate | Only the seized market and the repaid debt reserve must be fresh and agreeing; the account's other failing reserves count at their stress price | `Q-247` |
| Debt prices | A DebtOracle for USDC with primary and alternate routes, failover, agreement, Cached and Expired (5% stress rise), the alternate held to its borrow age | `Q-248` |
| Standby routes | A third, independent 1-hour feed per token. A guardian calls `useStandbyRoute` 45 minutes after the leg-age page once the primary is past its heartbeat, and `restorePriceRoute` runs at the normal delay once the listed route is healthy; when the standby also fails, a guardian trips the market breaker and the pause guardian resets it after one `cachedWindow` of Live | `Q-243`, `Q-248` |
| Liquidation settlement | Full Aave size only (no halving, no minimum repayment per call); per-leg minimums; the caller's shortfall top-up within `maxShortfallBps` (10%), which also pays any rounding gap `g = max(0, D + φD − Kr − R)` at final settlement; Avana's fee from oracle value; a refused payout goes to the payout escrow. There is no SettlementBudget, no shortfall report and no in-kind settlement (since `SIM-R12`; section 7.9) | `Q-250`, `Q-251`, `Q-256`, `Q-267`, `Q-395`, `Q-397`, `Q-401` |
| Rescue top-ups | Eligible below the rescue target HF 1.10 (`rescueHealthFactor`); exempt from the pool-share cap, breakers, `Paused(General)` and the address freeze, up to the amount that restores HF 1.10; rescue units booked per record and valued at zero in the health check of borrowing, withdraw-with-debt and partial removal | `Q-252`, `Q-253` |
| Repay | Repay-all pulls `Lens.quoteRepayAll` and refunds the unused part; "max" borrow is `Lens.previewBorrowMax` | `Q-268`, `Q-269` |
| New paths | Partial liquidity removal and re-credit; repay with collateral at `slippageAllowanceBps` with per-leg minimums | `Q-254`, `Q-255` |
| Circuit breakers | Oracle and stablecoin-band gate; concentration gate at `poolShareMaxBps` (10%, Avana's combined share of a pool, no peg condition); outstanding deficit above `breakerDeficitMax` (10,000 GHO); manual trip. Temporary gates clear after 30 minutes healthy; deficit and manual freezes need an authorized reset. Price drop (3% in 2 h), seizure (20% of a market in 1 h) and route failures (3 in 1 h) are alerts only, with no cooldown. They stop new pledges, borrowing and withdraw-with-debt only (since `SIM-R12`; before it: price drop, pool share 20%, seizure surge, route failures, deficit, manual) | `Q-241`, `Q-399` |
| Health gates and keepers | Borrow and withdraw-with-debt need Aave's HF ≥ 1.00 (optional per-market hard floor off); the app's max button borrows the Lens recommended amount at HF 1.10; `keeperFloor` 1, new borrowing halts only at 0 active keepers (since `SIM-R12`) | `Q-398`, `Q-400` |
| Address freeze | 40 dust wallets frozen by two guardians (20 per guardian per 24 hours); gates checked on a frozen wallet | `Q-242` |

Users act on the new paths: active LPs remove part of an NFT instead of withdrawing it, and re-credit liquidity they add to a pledged NFT; users who lack outside funds repay with collateral, to rescue or to exit; the app sizes a refused rescue to `usdToRestore`. The scenario gains one episode: from day 52.0 every DAI route, the standby included, stops for 30 hours, so the Cached, Expired and grace states and the stress valuation of `Q-247` are exercised (the standby switch now ends the USDT and USDC stalls of section 2.2 within about 1.5 hours).

The `mainnet-feeds` variant keeps 24-hour primaries on USDC, USDT, GHO and USDe. The listing check of `Q-274` refuses those tokens, so this variant measures what the listing rule prevents. In `literal-repay-quote` the app approves exactly `Lens.quoteRepayAll` and the payer holds exactly that amount, the literal reading of `webapp/README.md`.

### 7.2 Runs

`docs/spec/05-verification/.venv/bin/python docs/audit/user-simulation/run_simulation.py --extra-seeds 4 --jobs 7`, results in `results/final-spec/`.

| Variant | Seed | Invariant checks | Violations | Liquidation calls | Bonus paid | Bad debt |
|---|---|---|---|---|---|---|
| `base` | 20261109 | 514,318 | 3 (`SIM-GAP-14`) | 88 | $1,043 | $0 |
| `mainnet-feeds` | 20261109 | 474,442 | 0 | 4 | $235 | $0 |
| `literal-repay-quote` | 20261109 | 515,219 | 3 (`SIM-GAP-14`) | 86 | $1,086 | $0 |
| `base` | 20261110 | 501,751 | 3 (`SIM-GAP-14`) | 87 | $3,044 | $0 |
| `base` | 20261111 | 495,259 | 3 (`SIM-GAP-14`) | 83 | $2,044 | $0 |
| `base` | 20261112 | 455,373 | 3 (`SIM-GAP-14`) | 70 | $2,269 | $0 |
| `base` | 20261113 | 449,478 | 3 (`SIM-GAP-14`) | 81 | $1,689 | $0 |

The invariant checks are now 23 kinds: the 15 of section 3.6 with the backing check in its one-sided form (`Q-257`), plus rescue units at most credited per record, the rescue-excluded health factor after every borrow, withdraw-with-debt and partial removal, the recovery floor `R + shortfall ≥ minGho` on every routed liquidation, credited equal to live liquidity after a re-credit, repay with collateral covering its flash loan, the refund of every repay-all, and the address-freeze gates of `EMG-070`. The only violations are the three probes of `SIM-GAP-14` in every run whose USDe/USDT probe account holds debt (in `mainnet-feeds` the probe accounts could not borrow, so the check did not apply); every other check passed. There was no bad debt in any run. The bonus paid is higher than on 2026-11-09 because liquidations now run at full size and because the new DAI episode liquidates multi-market accounts (11 to 22 calls per seed) on their fresh markets while DAI/USDC is Expired.

### 7.3 The twelve gaps against the final spec

Before is the run of 2026-11-09 (base seed, range over 5 seeds); after is this run.

| Gap | Measure | Before | After | Status |
|---|---|---|---|---|
| 1 Borrow age = heartbeat | Borrow refused or reverted with `PriceTooOld` | 33 users refused, 16 reverted on-chain; 4.0–4.6% of the time blocked by age | 0 users reverted in every seed; 0 refused (1 refusal in one seed); at most 0.1% of samples blocked by age in any market | Closed by `Q-274` |
| | 24-hour primaries (`mainnet-feeds`) | Borrowing possible 0.05–4% of the time; 117 borrowers | Not listable under `Q-274`; if listed anyway, borrowing is possible 0.3–4.8% of the time and 192 users borrow (438 in `base`), and a USDT market stays seizable for 709 minutes on a frozen 24-hour primary during the joint stall | Closed: the listing rule refuses the configuration |
| 2 Floor allowance and halving | Liquidations of accounts other than the 40 dust accounts: calls / calls under $100 / most calls on one account / keeper loss reimbursed | 111 / 95 / 17 / $73,683 (9–111 calls, 7–95 under $100, up to 3–17 on one account, $5,946–$73,683) | 48 / 3 / 3 / $26,798 (30–48 calls, 0–3 under $100, at most 3 on one account, $8,461–$26,798) | Closed by `Q-251` |
| | Liquidation blocked by `RecoveryBelowFloor` | 81 account-hours, 13 accounts (21.5–81.2 h) | 0 in every seed: 30 calls covered a $181 shortfall from the keeper's GHO (8–30 calls, $83–$323); no shortfall report was needed, so automatic in-kind never opened | |
| 3 Pool-share cap on rescues | Top-ups of accounts below HF 1.10 refused by the pool-share cap | 7 users (1–7) refused, counting every top-up | 0 in every seed. 2 users (1–5) were rescued through the exemption (4 top-ups; 2–15 across seeds); top-ups of accounts at HF ≥ 1.10 are still refused by the cap (3 users), as the rule intends | Closed by `Q-252` |
| 4 Repay-all quote | First repay-all attempts that revert in `literal-repay-quote` | 226 of 226, 113 users | 0 of 100 | Closed by `Q-269` |
| | First repay-all attempts that revert in `base` | 0 | 0 of 104 (97–104 across seeds) | |
| 5 Joint stall of both routes | Minutes a USDT market could be seized on a USDT price older than its borrow age during the 26-hour stall | 9.2 hours of seizure on a frozen price | 0 minutes. Seizure of the USDT markets is blocked as Cached from the moment the primary goes stale; a guardian switches the primary to the standby 38 minutes later. Without the standby switch the market would stay blocked for 9.0 hours and then go Cached and Expired, never seized on the frozen price | Closed by `Q-274` |
| 6 Single debt-price source | USDC debt: borrowing and repayment in liquidation blocked during the 4-hour USDC primary stall | 3.1 h and 2.9 h, 126 accounts | 38 minutes each (from the primary going stale to the standby switch), the same in every seed | Closed by `Q-248`. The DebtOracle's failover alone does not shorten the block when the alternate publishes daily: held to its borrow age (`Q-274`), it leaves both gates closed for 2.9 hours; the standby switch closes the gap |
| 7 USD band at a GHO premium | GHO/USDC Drifting by the USD band while GHO trades at $1.047 | 41.3 hours; 2 users (0–2) blocked | 0 hours, 0 users | Closed by `Q-275` for the band. The pool-share breaker of `Q-241` now blocks the same borrowing for 44.8 hours: new finding `SIM-GAP-13` |
| 8 Slice used for growth | Slice used by the re-leverage attacker, and debt it drew after its first slice top-up | $35.5k–$41.7k of slice turned into debt | $42.2k of slice used to stay above HF 1 ($42.1k–$42.2k), $0 of debt drawn after the first slice top-up in every seed; 1,388 borrow attempts (1,030–1,555) refused because the rescue units count at zero | Closed by `Q-253` |
| 9 Top-ups refused in Paused | Top-ups of accounts below HF 1.10 refused during `Paused` | 1 user (0–3), then liquidated | 0 in every seed; the probe at day 76.0 admits a rescue top-up in `Paused(General)` and refuses one above HF 1.10 (`NotRescueTopUp`) | Closed by `Q-252` |
| 10 Dust accounts | Keeper cost of liquidating the 40 dust accounts at 250 gwei | $31,050 for $98 of debt | $32,975 ($31,050–$33,379); the attacker still pays about $2,750 to open them | Accepted risk (`Q-277`), unchanged |
| 11 Added liquidity never credited | Liquidity added to pledged NFTs | Never creditable: $45,052 (11 users) uncredited at day 90; 25 users (13–25) frustrated | Re-credited by `recredit` 18 times (14–24 across seeds). What stays uncredited at day 90 ($188,833, 11 users; $8,868–$188,833 across seeds) was refused by the caps that bind any top-up (`CapExceeded`, `SliceNotAvailable`, `PoolShareExceeded`) and can be re-credited when room opens | Closed by `Q-254` |
| 12 "Max" at exactly 1.10 | "Max" borrows that revert | 36 reverts, 18 users (5–18) | 0 in every seed | Closed by `Q-268` |

The other user-facing effects of the final rules, base seed:

- **Partial removal** replaced the whole-NFT round trip for 57 users (138 removals). Before, 63 users had to repay and withdraw a whole NFT to take liquidity out.
- **Repay with collateral** repaid $139,401 of debt in 26 calls by 23 users, at $77 of conversion loss. 20 users closed their loan this way; 2 users (0–2 across seeds) still needed outside funds, against 26 (10–26) before. It was refused while the USDe routes ran 3–6% below the oracle (`MinOutNotMet`, 73 times) and during the DAI stall (`StalePrice`, 107 times), as `Q-255` requires.
- **Circuit breakers.** The pool-share breaker blocked borrowing in USDC/USDT and USDe/USDT for 72 hours of the USDT depeg, its intended case. The DAI stall latched a manual breaker for 30 hours. No seizure-surge or route-failure latch fired.
- **Address freeze.** The two guardians froze the 40 dust wallets; a 21st freeze by one guardian within 24 hours was refused. On a frozen wallet a new account, a non-rescue top-up, borrowing, partial removal with debt and repay with collateral were refused; repay, a rescue top-up and liquidation of its positions stayed open (`EMG-070`).
- **The DAI stall (Q-247).** While DAI/USDC was Expired its collateral counted as worthless, so 11 calls (11–22 across seeds) liquidated multi-market accounts on their fresh markets; their DAI was worth $0.994. Accounts holding only DAI/USDC were not seized during the outage, and after recovery the grace window protected those above HF 0.95. The 983 account-hours the run lists as `StalePrice(Cached/Expired)` are these accounts, whose health factor read below 1 only because of the stress valuation.
- **Cap squatting** by debt-free filler wallets is unchanged: no decision addresses it.

### 7.4 New findings

#### SIM-GAP-13 Medium — the pool-share breaker blocks borrowing in GHO markets while GHO trades at a premium

**Rule.** `SPEC-BRK-002` trips the market breaker while Avana's supply is above `breakerPoolShareBps` (20%) of the pool's time-weighted in-range liquidity; a tripped breaker refuses borrowing and withdraw-with-debt for every account holding the market (`REQ-RISK-065`, `EMG-068`).

**Counterexample.** Day 9.0, base seed: GHO at $1.046, USDC at $1.000. GHO/USDC is Live and its band is clear (`Q-275`); the served price is $2.00 per whole vault token, capped. The other LPs' concentrated ranges (±0.2% and ±2%) are out of range, so in-range liquidity is their full-range liquidity alone, 3.0 million units, against Avana's 2.12 million: a share of 41.4%. The breaker trips and every GHO/USDC holder cannot borrow or withdraw with debt for 44.8 hours (44.2–45.0 across seeds), against 41.3 hours of the USD-band block that `Q-275` removed. At day 7.0, with GHO at peg, the share is 0.02%.

**Why it matters.** A premium cannot inflate collateral that is valued at the $1 ceiling, which is the reason `Q-275` gives for testing the band's upper bound on capped prices. Liquidation does not trade through the market's own pool (`Q-273`). Blocking borrowing while GHO trades at a premium controls no risk, and it falls exactly when GHO demand is high.

**Recommended spec change.** In `SPEC-BRK-002`, trip POOL_SHARE only while the LP's USD level on the uncapped quotes is at or below its peg level, `q0 · q1 ≤ 10^16` (the quotes `SPEC-ORC-011` already reads for `usdBandLow`). Add the same sentence to `Q-241` and to `EMG-068`. The USDT depeg, the case the breaker exists for, still trips it.

#### SIM-GAP-14 Low — the restore amount is booked at the accepted price, so a rescue top-up restores only part of the gap after a fall

**Rule.** `SPEC-CAP-003` books the restore amount as `restoreBooked = usdToRestore × max(price8, stressFloorUsd) / price8` with `price8` the accepted price (`REQ-RISK-026`), and a top-up that needs an exemption must keep its charge `usdCharge = L × max(price8, stressFloorUsd)` at most `restoreBooked` (`REQ-RISK-066`). `REQ-RISK-026` states that the accepted price equals the served price while the market is Live or Drifting outside a disagreement. `SPEC-ORC-017` serves `min(fresh, accepted)` while Drifting, and `REQ-ORACLE-029` updates the accepted price only while Live, so after a fall into Drifting the served price is lower.

**Counterexample.** USDe/USDT at day 60.25, base seed: accepted $1.9895, served $1.5480 per whole vault token (Drifting by disagreement, then by the USD band for 30 days). A probe account at HF 1.05 needs `usdToRestore` of collateral at Aave's price to reach 1.10. A top-up worth 99% of that at the served price carries a charge of `0.99 × usdToRestore × 1.9895 / 1.5480 = 1.27 × usdToRestore > restoreBooked` and is refused (`NotRescueTopUp`, reported as `PoolShareExceeded`). The largest admitted rescue is worth `1.5480 / 1.9895 = 77.8%` of the gap and lifts the account to HF 1.089, not 1.10. The run's check "rescue top-up sized to restore `minOpeningHealthFactor` at the served price is admitted" fails at the three USDe/USDT probes in every run; users in the app needed 4 top-ups (2–14 across seeds) sized below the full restore for this reason.

**Recommended spec change.** In `SPEC-CAP-003`, compute `restoreBooked = mulDiv(usdToRestore, max(price8, stressFloorUsd[m]), served8, Ceil)` with `served8 = LPOracle.latestAnswer()` read in the same call: the collateral that restores the health factor at the price Aave values it at, booked at the accepted price. Correct `REQ-RISK-026` to say that the accepted and served prices are equal only while the market is Live.

### 7.5 Limits of this run

- The standby route is modelled as an independent feed that keeps publishing through the USDT and USDC stalls, and the guardian's reaction (45 minutes after the page) is an assumption; gaps 5 and 6 close to that reaction time, and without a switch to the reaction of governance.
- The keeper reimbursement budget is assumed large enough for every shortfall top-up; it paid $181 of shortfalls in the base run.
- Every other limit of section 2.5 still applies.

### 7.6 Re-run with per-market accounts, the flash source and the minimum debt (2026-11-10, `SIM-R9`)

The `base` variant now follows the decided design in four places:

- **One account per wallet and market.** Each of the 85 `multi_market` people (2 or 3 markets) holds one PositionProxy per market, so each account has one collateral market and its own health factor; the person's size, cash, spare funds and guardian funds are split across the accounts in proportion to the markets (the split the topology runs use). Persona tables count people, not accounts.
- **Flash source.** Every routed liquidation flash-borrows the repaid debt asset through `IFlashSource` at the Aave V3 premium of 5 bps (`maxFlashFeeBps` = 10); a repay above the Pool's idle balance takes the caller-funded path. The premium enters the effective slippage (`costsBps`) and the debt cost `D + φD`. Repay with collateral sizes `x = Vnet / (1 + maxFlashFeeBps)` and repays the loan with its premium.
- **Payout in the debt asset.** The seized legs are converted into the debt asset (a leg in that asset needs no swap); there is no GHO buy leg. The waterfall is `Y = max(0, R' − D − φD)`, `A = min(20% × max(0, V − D − φD), Y)`, `Kr = min(Y − A, max(0, V − D − φD) − A)`, `B = Y − A − Kr`. Liquidation gas is the 1,550,000 of a one-record flash liquidation (`SPEC-CHAIN-001`) plus 290,000 per further record.
- **Minimum debt.** A borrow that leaves the account's debt below $2,000 is refused (`BelowMinDebt`); the app shows the minimum and the person stays debt-free.

| Measure | Before (`SIM-R5`/`SIM-R8`) | `SIM-R9` |
|---|---|---|
| Summary sha256 (first 16) | `b32c4c5cdc21307b` | `cd79a767842cfe9a` |
| Invariant checks (kinds) / violations | 514,318 (23) / 0 | 501,748 (27) / 0 |
| Liquidation calls / accounts | 88 / 77 | 18 / 10 |
| Of which: dust-attack calls; calls on accounts with several markets | 40; 11 on a market other than the failed one | 0 (no dust account could borrow); 0 |
| Liquidations by market | USDe/USDT 80, GHO/USDC 5, USDC/USDT 3 | USDe/USDT 18 |
| Debt repaid / bonus paid by borrowers | $29,781 / $1,043 | $8,670 / $184 |
| Avana fee / keeper reward / borrower surplus | $205 / – / – | $36 / $44 / $0 |
| Flash-funded calls / flash premium | – | 18 / $4.34 |
| Caller shortfall top-ups | 30 calls, $181 | 16 calls, $94 |
| Keeper loss reimbursed | $57,848 | $20,535 |
| Bad debt; settlement-budget draws; supplier loss | $0; $0.69; $0 | $0; $0; $0 |
| People who borrow / people liquidated | 438 / 37 | 201 / 10 |
| People refused by the minimum debt | – | 233; no `small` person borrows (23 before) |

The six new invariant kinds are debt-asset conservation (`SPEC-LIQ-010`), the recovery floor against `minOut`, `A + Kr + B = Y` with each part non-negative, no borrower surplus when a shortfall or budget draw was paid (`LIQ-POST-016`), and the flash premium within `maxFlashFeeBps` on liquidation and on repay with collateral; they replace the GHO conservation and `minGho` floor checks. Every keeper call still lost money after gas: the largest single call cost $1,598 of gas during the USDe crash, against $44 of keeper reward over all 18 calls, so the keeper agreement's reimbursement carries liquidation in this scenario. The variants `mainnet-feeds` and `literal-repay-quote`, the extra seeds and the topology grid were not re-run; they would print new fingerprints with the current code.

### 7.7 Re-run with no minimum debt (2026-11-10, `SIM-R10`)

Avana has no minimum debt on any chain (`Q-381`): a borrower may borrow any amount, and Avana's own keepers liquidate every account and pay the gas. The model drops the `BelowMinDebt` refusal and prices liquidation gas with the `SPEC-CHAIN-001` gas units model `G(n) = 1,310,000 + 240,000 × n` for `n` records.

| Measure | `SIM-R9` | `SIM-R10` |
|---|---|---|
| Summary sha256 (first 16) | `cd79a767842cfe9a` | `b42224e0f720442e` |
| Invariant checks (kinds) / violations | 501,748 (27) / 0 | 559,561 (27) / 0 |
| People who borrow | 201 | 483 |
| Liquidation calls / accounts | 18 / 10 | 101 / 86 |
| Of which dust-attack calls | 0 | 40 |
| Debt repaid / bonus paid by borrowers | $8,670 / $184 | $31,985 / $684 |
| Avana fee / keeper reward / borrower surplus | $36 / $44 / $0 | $133 / $156 / $0 |
| Flash-funded calls / flash premium | 18 / $4.34 | 101 / $16 |
| Caller shortfall top-ups | 16 calls, $94 | 57 calls, $412 |
| Keeper loss after gas (Avana's own keeper cost) | $20,535 | $116,799, of which $47,662 on dust-attack calls |
| Bad debt; settlement-budget draws; supplier loss | $0; $0; $0 | $0; $0.18; $0 |

Solvency holds without the minimum: every account, dust accounts included, was liquidated with no bad debt and no supplier loss. The cost moves to Avana's keeper gas budget, which the gas units model sizes per liquidation (`G(16) = 5,150,000` gas units at most). The other variants and seeds were not re-run.

### 7.8 Re-run at current mainnet gas prices (2026-11-10, `SIM-R11`)

The gas path is the parameter `GAS_PRICE` in `avana_sim/params.py`, set from the Etherscan gas tracker at 2026-11-10 16:19 UTC (base fee 0.939 gwei, Rapid 1.139 gwei, ETH about $2,080). The calm price swings between 0.1 and 1.2 gwei through the day (same sine shape and log-normal noise as before). Stress floors are 5 gwei on the USDT depeg, 30 gwei on the worst USDe crash half-day, 10 gwei on the next half-day and 4 gwei on day 75. A minute is congested above 4 × 1.2 = 4.8 gwei, so the slower Chainlink rounds and inclusion apply on days 30.0–30.5 and 60.0–61.0 only, as with the old fixed 70 gwei threshold. Sections 2 to 6 still describe the 14–22 gwei path of 2026-11-09.

| Measure | `SIM-R10` | `SIM-R11` |
|---|---|---|
| Summary sha256 (first 16) | `b42224e0f720442e` | `751619709834af63` |
| Gas path; ETH | 14–22 gwei, spikes 60–250 gwei; $3,000 | 0.1–1.2 gwei, spikes 4–30 gwei; $2,080 |
| Invariant checks (kinds) / violations | 559,561 (27) / 0 | 546,706 (27) / 0 |
| People who borrow | 483 | 485 |
| Liquidation calls / accounts; of which dust-attack calls | 101 / 86; 40 | 99 / 86; 40 |
| Avana keeper gas: total / per liquidation / largest call | – / – / $1,703 | $9,552 / $96 / $127 |
| Of which dust-attack calls | – | $3,869 (40.5%), $97 per call |
| Keeper loss after gas (Avana's own keeper cost) | $116,799 | $9,762 |
| Bonus paid by borrowers / Avana fee / keeper reward | $684 / $133 / $156 | $689 / $135 / $181 |
| Bad debt; settlement-budget draws; supplier loss | $0; $0.18; $0 | $0; $0.48; $0 |
| Users with gas above what they can borrow | – | 3 |

At current prices a liquidation costs Avana about $96 of gas, nearly all of it at the 30 gwei crash peak. The 40 dust accounts cost Avana $3,869 to liquidate; the attacker paid $14 of gas to open all 40 at calm prices. The other variants and seeds were not re-run.

### 7.9 Re-run after the parameter decisions (2026-11-10, `SIM-R12`)

The model now follows the parameter decisions `Q-395`…`Q-401`. Sections 2 to 6 and 7.1 to 7.8 describe earlier models that still had the items below; their numbers are kept as recorded.

- **SettlementBudget removed (`Q-397`).** Earlier runs let a liquidation draw a few cents to a few dollars from a per-chain budget (25 per call, 500 per 24 hours) to close the rounding gap between the flash repayment and the recovered value. The budget is gone with all of its caps and windows. Aave V4's dust rule can raise the repayment needed to finish a liquidation, so the keeper sizes `debtToCover` and its funding for that amount up front, with the exact flash principal and premium, and pays any rounding gap `g = max(0, D + φD − Kr − R)` at final settlement through its shortfall top-up. The reason: the gap is a few units of the debt asset, bounded by the floor's rounding terms, and the keeper already holds debt-asset inventory and controls the sizing that produces it ([2.11](../../spec/02-contracts/11-lpvaultswap.md) `REQ-SWAP-029`). In this run the top-ups that now include those gaps were 55 calls for $319, against 53 calls for $391 plus $0.48 of budget draws in `SIM-R11`.
- **In-kind settlement removed (`Q-401`).** No governance or automatic in-kind opening, no `inKindAutoDelay` or expiry and no in-kind liquidation mode. When every approved route of a token fails, keepers fund the debt themselves and use the shortfall top-up, a guardian can freeze new borrowing, and governance restores or replaces routes; in the model a failed attempt only counts toward the route-failure alert. The escrow contract remains for refused payouts only.
- **Breakers redesigned (`Q-399`).** Price drop, seizure and route failures are monitoring alerts that block nothing, and no cooldown exists. The concentration gate trips when Avana's combined share of a pool exceeds `poolShareMaxBps` (10%), with no peg condition, and the deficit freeze trips above 10,000 GHO. No alert fired in this run. The concentration gate blocked borrowing for 72.7 h on USDC/USDT and 72.3 h on USDe/USDT during the USDT depeg, 45.0 h on GHO/USDC during the GHO premium and 3.5 h on DAI/USDC.
- **No on-chain health floors (`Q-398`), keepers (`Q-395`, `Q-400`).** Borrow and withdraw-with-debt test Aave's 1.00; the max button borrows the Lens recommended amount at HF 1.10; a rescue top-up restores HF 1.10. `keeperMinRepay` is gone and `keeperFloor` is 1.

| Measure | `SIM-R11` | `SIM-R12` |
|---|---|---|
| Summary sha256 (first 16) | `751619709834af63` | `eb8721c3196683b3` |
| Invariant checks (kinds) / violations | 546,706 (27) / 0 | 572,608 (27) / 0 |
| Liquidation calls / accounts; of which dust-attack calls | 99 / 86; 40 | 98 / 84; 40 |
| Bonus paid by borrowers / Avana fee / keeper reward | $689 / $135 / $181 | $557 / $108 / $129 |
| Caller shortfall top-ups | 53 calls, $391 | 55 calls, $319 (rounding gaps included) |
| Settlement-budget draws | $0.48 | none (no budget) |
| Keeper loss after gas | $9,762 | $9,498 |
| Bad debt; supplier loss | $0; $0 | $0; $0 |

The fingerprint changed because the max-button borrowers now borrow the recommended amount, the health gates test 1.00 instead of 1.10, the concentration gate trips on share alone and no settlement draws on a budget; each changes which actions pass, so later random draws move. The run log is `SIM-R12` in [RUNS.md](RUNS.md). The other variants and seeds were not re-run.
