# Economic stress simulations (SIM)

Python stress simulations of Avana at launch: the Stable LP Hub with full-range Uniswap v3 stable pools (USDC/USDT, USDC/GHO, USDT/GHO, DAI/USDC), GHO debt (and USDC debt through a DebtOracle where a scenario adds it) and the 2M GHO credit line. Each scenario drives prices, Chainlink feeds, keepers and borrowers through the final liquidation, oracle and emergency rules (decisions `Q-001` to `Q-278`, parameters in [1.5](../../01-architecture/05-parameters.md)) and measures bad debt, liquidation liveness, keeper cost and the time the protocol spends in each oracle state. The Z3 and SymPy models prove the formulas; these simulations measure what the formulas do over whole incidents.

Standard library only (Python 3.9); `requirements.txt` is unchanged. Every script is seeded (seeds 11/22/33 unless stated) and reproducible (`SIM-00B`).

## Run

```bash
cd spec/05-verification
.venv/bin/python simulation/sim01_depeg.py      # any single scenario
./run_all.sh                                     # runs every *.py here (about 6 minutes for this folder)
```

Each script prints its result tables, then one line per property: `Holds` or `Counterexample`, the result recorded in this README, and `ok` / `UNEXPECTED`, followed by its Holds and Counterexample counts. A script exits 0 only when every result matches this README and 1 otherwise, so a recorded counterexample does not fail the run and any change in a result does.

| File | Scenario |
|---|---|
| `_simcore.py` | Engine; self-tests `SIM-00A/B` |
| `sim01_depeg.py` | (1) USDC 0.87 (March 2023 path), USDT 0.95, GHO 0.97 / 0.90; GSM freeze and backup routes; agreement tolerance |
| `sim02_oracle_outage.py` | (2) Provider-wide outages 1h to 72h (fail and silent), Cached window, grace, tail-term reserve, token-specific stall, wrong primary and standby switch, DebtOracle stress valuation |
| `sim03_correlated_drop.py` | (3) Both legs fall together; USD band; stale-price borrowing during a silent stall |
| `sim04_keeper_outage.py` | (4) Primaries down 48h; standby keeper delay; permissionless fallback; pause reasons and breakers during an incident |
| `sim05_gas_dust.py` | (5) Gas 0.2/20/100 gwei vs small and dust loans; target health factor; SettlementBudget sub-cap |
| `sim06_route_stress.py` | (6) Frozen GSM, drained, dislocated or reverting backup route; shortfall top-up; automatic and manual in-kind; pool skew |
| `sim07_interest_accrual.py` | (7) Interest pushing idle accounts across HF 1 |
| `sim08_recommendations.py` | Launch values against the engine: insolvency thresholds, cap-sizing terms, floor and slippage grid, keeper break-even |

## What is modelled

| Mechanism | Rule modelled | Decisions |
|---|---|---|
| Collateral value | Full range: value per par unit = √(v0·v1), par unit = $1 of LP at peg; every stable leg valued at min(quote, $1); GHO debt at Aave's fixed $1 | `Q-028`, `Q-100`, `Q-177` |
| Collateral factor | `floor_bps(min(CF0, CF1) × poolRiskFactor)`, poolRiskFactor ≤ 0.40; HF = Σ collateral value × CF / Σ debt value | `Q-020`, `Q-186` |
| Aave V4 liquidation | `calculateLiquidationBonus`, `_calculateDebtToTargetHealthFactor` over every reserve of the account, $1,000 dust rule on the repaid debt reserve and the seized collateral reserve, deficit when the last collateral is emptied (LiquidationLogic.sol @ a3ef63e); float sizing checked against the integer reference `z3/aave-risk/_v4ref.py` (`SIM-00A`) | `Q-072`, `Q-179`, `Q-185` |
| Accounts | Open at HF ≥ 1.10; 20% hold two markets; optional USDC debt; no minimum debt; any partial repay; rescue top-ups restore HF 1.10 when only rescue pledges are allowed | `Q-018`, `Q-153`, `Q-169`, `Q-252`, `Q-277` |
| Feeds and routes | Primary route per token with heartbeat 3,600 s; alternate route TOKEN/X × X/USD (X = ETH for USDC, BTC for USDT and DAI, LINK for GHO, so the two tokens of a pool share no intermediate); standby route a guardian switches in with `useStandbyRoute` | `Q-079`, `Q-130`, `Q-176`, `Q-248`, `Q-274` |
| Freshness | `feedMaxAge` = `liquidationPriceMaxAge` = heartbeat + 600 s; `borrowPriceMaxAge` = min(heartbeat + 600, 4,200) s; a serving alternate held to its borrow age for seizure (`ALTERNATE_PAST_BORROW_AGE`) | `Q-182`, `Q-274` |
| Price states | Live; Drifting on disagreement, TWAP deviation (1,800 s, 50 ticks) or USD band (0.90 on uncapped quotes, 1.02 on capped prices); Cached from the first failed read for `cachedWindow` 3,600 s; Expired after it; disagreement pause `disagreementPauseMax` 3,600 s from the first stored observation, then seizure blocked until the routes agree; tolerance = primary + alternate deviation thresholds + 50 bps | `Q-162`, `Q-183`, `Q-184`, `Q-199`, `Q-208`, `Q-275` |
| Served price | Live fresh; Drifting min(fresh, accepted); disagreement min(lower routes, accepted); Cached accepted; Expired 1 (worthless). DebtOracle: Live quote; disagreement max(p, b, accepted); Cached accepted; Expired accepted × (1 + `debtStressRiseBps`), 500 bps for USDC | `Q-247`, `Q-248` |
| Grace | `recoveredAt` from source-timestamp evidence of an outage that reached Expired, else the newest input of the fresh price; 1,800 s below HF 0.95 for every account holding the market or the debt | `Q-088`, `Q-129`, `Q-154`, `Q-264` |
| Liquidation gates | Seizure needs the seized market not Cached, Expired, disagreeing or past the alternate borrow age; repayment needs the repaid debt reserve Live within its age (GHO always passes); the account's other reserves count at their served prices | `Q-128`, `Q-247` |
| LPVaultSwap | Effective slippage `min(slippageAllowanceBps, ⌊10⁴(bNet·10⁴ − (10⁴+costs)(10⁴+cBuy))/(bNet·10⁴)⌋)`; recovery floor `V(1 − s) − U − 1 GHO`; per-leg minimum `Vleg(1 − sLeg) − Uleg − 1 GHO/n`, primary then backup; caller shortfall top-up `sLeg = s + min(maxShortfallBps, maxShortfallGho/V)` with `R + shortfall ≥ minGho`; Avana fee `A = min(⌊max(0, V − Gcov − φD) × 20%⌋, S)`; budget draw `max(0, Gcov + φD − R' − K)`; zero end balance asserted; buy leg for USDC debt within `bound = D × Pdebt × (1 + buySlippageAllowanceBps)` | `Q-159`, `Q-198`, `Q-235`, `Q-250`, `Q-251`, `Q-256`, `Q-261` |
| Routes | USDC, USDT → GSM (fee 0% or 0.10%, freezes outside 0.99–1.01, unfreezes inside 0.995–1.005, outside arbitrage fills headroom below 1 − fee); DAI → LitePSM → USDC GSM; GHO needs none; backup = DEX outside the market's own pool and outside every GSM or PSM of the market's tokens, linear impact | `Q-062`, `Q-084`, `Q-187`, `Q-273` |
| SettlementBudget | 20,000 GHO; 25 GHO per call; 500 GHO per rolling 24h per (Spoke, debt reserve); per-market sub-cap max(100, ⌊500 / 4 markets⌋) = 125 GHO; never a shortfall, never permissionless; a refused draw is covered by the caller's own GHO | `Q-167`, `Q-236`, `Q-267` |
| In-kind | Approved keeper's own GHO; tokens at oracle value capped at D × (1 + bonus), remainder to the borrower; opened automatically after `inKindAutoDelay` 6h of shortfall reports with no gap over 1h on a market whose trigger is approved, or by governance at the 12h short delay; each opening lasts `inKindExpiry` 24h | `Q-133`, `Q-228`, `Q-251` |
| Keepers | Approved keepers act every step and repay the to-target amount (never less than min(debt, $500), never halving); a floor failure is answered with a top-up of up to 10% of V, else a shortfall report; primaries can stall, the standby acts after a delay; `obliged` (keeper agreement, reimbursed) or `rational`; the permissionless fallback acts only when the routed call pays | `Q-082`, `Q-098`, `Q-147`, `Q-213`, `Q-251` |
| Breakers and pause | Price-drop (300 bps below the hourly checkpoint), route-failure (3 per hour, 6h latch), seizure-surge (20% per hour, 6h latch), deficit (> 1,000 GHO) and manual trips; `Paused(General)` and `Paused(MintPathSuspect)`; all of them stop only new borrowing and non-rescue top-ups, never liquidation or repay | `Q-227`, `Q-241`, `Q-252` |
| Deficits | Recorded deficit drawn from the First-Loss Reserve of its asset up to its balance; the remainder is uncovered | `Q-101`, `Q-236` |

Outside the engine: Hub share/asset drift, risk-premium refresh (`Q-145`), the pool-share and issuer-action breakers (no pool-liquidity or issuer model), address freezes, keeper GHO price impact when buying GHO, gas-limit competition and the timelock's own operations other than in-kind enabling.

## Assumptions (all scenarios)

| Input | Value | Basis |
|---|---|---|
| Token Core Hub CF | 0.78 for USDC, USDT, DAI and GHO | Aave V3 stable liquidation threshold; results scale with the effective CF printed in every table |
| Pool risk factor | 0.20, 0.30, 0.40 (0.10 to 0.50 in sim08) | 0.40 is the launch ceiling (`Q-186`) |
| Bonus curve | maximum bonus 5%, minimum bonus 2% (`minLiquidationBonus` 200 bps), hfForMaxBonus 0.90, target HF 1.10 | `Q-179`, `Q-185`; the 5% maximum and 0.90 are curve inputs |
| Slippage and costs | `slippageAllowanceBps` 100, `maxFlashFeeBps` 0, `buySlippageAllowanceBps` 30 for USDC debt, `floorRoundingAllowanceGho` 1 GHO, `maxShortfallBps` 1,000 | `Q-196`, `Q-198`, `Q-251`; 30 bps is the USDC listing value used |
| Primary feeds | USDC/USD, USDT/USD, DAI/USD 0.25% / 3,600 s; GHO/USD 1% / 3,600 s | Heartbeat ≤ 3,600 s required for listing (`Q-274`) |
| Alternate routes | TOKEN/X leg 1% / 86,400 s; X/USD leg 0.5% / 3,600 s (ETH, BTC), 1% / 3,600 s (LINK); X price a random walk with daily volatility 3% (ETH), 2.5% (BTC), 5% (LINK) | Chainlink cross-rate feeds |
| Standby routes | One 0.5% / 3,600 s route per token | `Q-248` |
| Agreement tolerance | 2.25% for USDC, USDT, DAI; 3.5% for GHO (the on-chain lower bound) | `Q-184` |
| GSM | headroom USDC $20M, USDT $24M (cap $50M); outside arbitrage $10M/h; buy fee 0.20% | Live GSM settings |
| Backup DEX depth | $5M (USDC), $3M (USDT, DAI) for 1% impact; ×0.25 while the token is > 1% off peg; 0.05% fee | Pools outside the market's own pool |
| FlashMinter | 2M GHO per transaction, fee 0 | `Q-135` |
| Gas | 650k base + 250k per GSM leg (+120k PSM) or 180k per DEX leg, 220k buy leg, 40k top-up, 600k in kind; ETH $3,000 | Fork-test estimates |
| Reserves | First-Loss Reserve 400,000 per debt asset (`coverageRatioBps` 2,000 × the 2M drawCap, `DEF-019`); SettlementBudget 20,000 GHO | `Q-101`, `Q-167`, `Q-196`, `Q-236` |
| Population | 200 accounts, 2M GHO drawn (60% in sim03); 25% small accounts 100–1,500 GHO (log-uniform), rest log-normal median 6,000 capped at 7.5% of total; 20% hold two markets; opening HF: 10% already drifted to 1.02–1.10, 30% 1.10–1.15, 30% 1.15–1.35, 30% 1.35–2.5; markets USDC/USDT 40%, USDC/GHO 25%, USDT/GHO 15%, DAI/USDC 20% | Representative book |
| Borrowers | 30% react to HF < 1.03 at last accepted prices (what the Lens shows) after 1–12h, half by repaying to HF 1.25 and half by adding collateral; 70% idle | Representative behaviour |
| GHO rate | 8% APR (6/9/12% in sim07) | `Q-096` |
| Time step | 5 min (sim01), 10 min (sim02–06, 08), 12 h (sim07) | — |

Price paths (seeded multiplicative noise, standard deviation 0.02% + 2% × distance from peg per step; 1% for the correlated paths):

| Path | Shape |
|---|---|
| USDC March 2023 | 1.0 → 0.97 (6h) → 0.87 (16h) → 0.89–0.92 (20–36h) → 0.97 (50h) → 0.998 (72h); DAI = 1 − 0.77·(1 − USDC); USDT, GHO at peg |
| USDT 0.95 | to 0.95 over 12h, hold to 36h, 0.99 at 60h, 1.0 at 72h |
| GHO 0.97 / 0.90 | to 0.97 in 6h / to 0.90 in 12h, hold |
| Tail | USDT 1.0 → 0.90 (6h) → 0.40 (24h) → 0.02 (48h), no recovery: one pool token going to zero, the case the tail term of `Q-249` sizes for |
| Collapse | USDT 1.0 → 0.02 over 24h (sim02 token stall, sim06) |
| USDT 0.80 | USDT to 0.80 over 12h, hold (sim06) |
| Correlated | USDC, USDT, DAI together to 0.95 / 0.90 / 0.80 / 0.60 / 0.45 over 6h, hold 24h, back to 1.0 by 48h |
| Stress (sim05) | USDC, USDT, DAI together to 0.93 |

## Output columns

`bad_debt` mean recorded deficit plus unrecorded shortfall (debt − market value of collateral) of open accounts at the end, GHO; `bad_max` worst seed; `deficit` Aave deficits recorded; `reserve` First-Loss draws; `budget` SettlementBudget draws; `liq` successful liquidation calls; `inkind` in-kind calls; `perm` permissionless calls; `blk_accts` distinct accounts with HF < 1 at served prices that could not be liquidated at least once, by reason (`stale` seized market Cached or Expired, `disagree`, `alt_age` serving alternate past its borrow age, `debt_stale`, `grace`, `keeper_down`, `route`, `floor`, `buy`, `flash`, `unprofitable`, `keeper_gho`; an Expired market serves price 1, so every account in it reports HF < 1 and is counted); `borr_loss` market value of seized collateral − debt repaid (USD); `keeper_pnl` caller payout − shortfall paid − gas (USD); `reimb` Avana reimbursement of approved keepers' loss-making calls (USD). Means over seeds.

## Properties

| ID | Statement | Measured | Backs | Bounds | Result |
|---|---|---|---|---|---|
| SIM-00A | The simulator's liquidation sizing matches Aave V4 | \|repay − ref\|/debt and \|seized − ref\|/debt < 0.05% vs `_v4ref.liquidation_amounts` | `Q-072`, `Q-152`, `Q-179`, `Q-185` | 600 random cases, prf 0.10–0.40, minimum bonus 0–3%, maximum 3–8%, target 1.05–1.20 | Holds (4.6e-5; normal, collateral-cap and debt-dust branches) |
| SIM-00B | Same seed, same results | two runs equal | `Q-152` | 60 accounts, 24h, USDC debt | Holds |
| SIM-01A | Brief depegs create no bad debt | bad debt = 0 | `Q-020`, `Q-072`, `Q-177`, `Q-186` | 4 paths × prf 0.20–0.40 × GSM fee 0/0.10% | Holds |
| SIM-01B | No liquidation is left unsettled by the floor, a leg minimum or a route in brief depegs | blocked(floor, route) = 0 | `Q-085`, `Q-159`, `Q-198`, `Q-250`, `Q-251` | as SIM-01A | Holds (no top-up needed) |
| SIM-01C | With the USDC GSM frozen, every USDC and DAI leg settles on its independent backup | backup legs > 0, unsettled = 0 | `Q-062`, `Q-084`, `Q-187`, `Q-273` | USDC path | Holds (105 backup legs) |
| SIM-01D | GHO below peg liquidates no account solvent in GHO terms | liquidations = 0 | `Q-100`, `Q-177` | GHO 0.90, prf 0.40 | Counterexample |
| SIM-01E | At the tolerance lower bound the disagreement pause blocks no liquidation in the USDC depeg | blocked(disagree) = 0 | `Q-162`, `Q-184`, `Q-199` | 2.25%, compared with 0.25–1% | Holds |
| SIM-02A | Brief path during a provider-wide outage of up to 72h creates no bad debt | bad debt = 0 | `Q-079`, `Q-128`, `Q-183`, `Q-247` | fail mode 1–72h, prf 0.20–0.40 | Holds |
| SIM-02B | Tail path during a 48h outage stays within a reserve sized by the tail term | worst bad debt ≤ max token exposure × CF/1.10 | `Q-101`, `Q-192`, `Q-249` | 2M book, prf 0.20–0.40 | Holds (374k ≤ 2.24M at 0.40) |
| SIM-02C | A silent stall of every feed stops seizure and borrowing within `borrowPriceMaxAge` | latest stop ≤ 4,200 s + one step | `Q-182`, `Q-274` | 40 random phases and start times, fail and silent | Holds (78 min silent, 10 min fail) |
| SIM-02D | Every failure spends the Cached window in Cached | straight-to-Expired = 0, shortest spell ≥ 3,600 s − one step | `Q-079`, `Q-183`, `Q-154` | 320 spells | Holds (shortest 60 min) |
| SIM-02E | Grace of 0–2h at HF 0.90–0.95 adds no bad debt, and every outage that reached Expired starts one | bad debt = 0, windows = 5 per run | `Q-088`, `Q-129`, `Q-154`, `Q-264` | 24h outage, brief and tail | Holds |
| SIM-02F | A token-specific silent stall adds no bad debt over a reverting outage of the same feeds | bad debt(silent) ≤ bad debt(fail) | `Q-247`, `Q-274` | USDT collapse, 60% two-market accounts | Holds |
| SIM-02G | A standby switch within 1h ends a wrong-primary incident with no bad debt | bad debt = 0, blocked account-hours bounded | `Q-208`, `Q-248` | USDC primary stuck at $1, delay 15m–4h, never | Holds |
| SIM-02H | Stress valuation liquidates no account healthy at market prices | forced liquidations ≤ no-outage run | `Q-247`, `Q-248` | USDC routes fail 24h, no standby | Counterexample |
| SIM-02I | A standby switch within 30 minutes ends the USDC outage before any stress-valuation liquidation | forced liquidations ≤ no-outage run, bad debt = 0 | `Q-130`, `Q-248` | as SIM-02H | Holds |
| SIM-03A | Borrowing is closed while a correlated drop takes the LP more than 1% below the 0.90 band | borrowable hours below the band = 0 | `Q-176`, `Q-195`, `Q-275` | depths 0.95–0.45, fresh feeds | Holds |
| SIM-03B | Correlated drop to 0.80 with fresh feeds creates no bad debt | bad debt = 0 | `Q-020`, `Q-112`, `Q-186` | prf 0.20–0.40 | Holds |
| SIM-03C | During a silent stall, borrowing on a served price > 1% above market lasts at most `borrowPriceMaxAge` | hours ≤ 4,200 s + one step | `Q-182`, `Q-241`, `Q-274` | silent 12h stall, depths 0.95–0.45 | Holds (1.0h) |
| SIM-03D | Stale-price borrowing during a stall is unprofitable to default on | attacker borrow − LP cost ≤ 0 | `Q-020`, `Q-182`, `Q-274` | drop to 0.45, $5M attacker | Holds (no borrow possible) |
| SIM-04A | Primaries down 48h give no bad debt on the brief path, with or without a standby or permissionless liquidator | bad debt = 0 | `Q-082`, `Q-147` | prf 0.20/0.40 | Holds |
| SIM-04B | A standby keeper acting within 24h keeps tail bad debt at 0 | bad debt = 0 | `Q-082`, `Q-098`, `Q-147` | delays 0–24h | Holds |
| SIM-04C | The permissionless fallback alone keeps tail bad debt at the standby level | bad debt ≤ standby at once | `Q-082`, `Q-213` | no approved keeper for 48h, prf 0.40 | Counterexample |
| SIM-04D | `Paused(General)` with every breaker tripped blocks no liquidation and no rescue top-up | same bad debt, refused top-ups = 0 | `Q-227`, `Q-241`, `Q-252` | tail incident 48h | Holds |
| SIM-05A | A minimum bonus ≤ 5% covers a 1,000 GHO liquidation at 0.2/20/100 gwei | break-even minimum bonus ≤ 5% | `Q-098`, `Q-169`, `Q-179`, `Q-256` | GSM route, 1.15M gas | Counterexample |
| SIM-05B | With obliged keepers, dust loans add no bad debt | bad debt = 0 | `Q-098`, `Q-169`, `Q-277` | stress and tail, 0.2–100 gwei | Holds |
| SIM-05C | If approved keepers skip loss-making calls, dust loans add no bad debt | bad debt = 0 | `Q-098`, `Q-101`, `Q-169`, `Q-213` | tail, 100 gwei | Counterexample |
| SIM-05D | A higher target HF reduces reimbursement in a slow collapse | monotone decreasing | `Q-072`, `Q-098`, `Q-185` | target 1.02–1.20, 20 gwei | Holds |
| SIM-05E | In a dust wave needing top-ups, every market stays within its 24h sub-cap and no liquidation is lost to the budget | rolling market draw ≤ 125 GHO, blocked = 0 | `Q-251`, `Q-267` | dust-heavy tail, backup 6% below market | Holds |
| SIM-06A | Frozen GSM, backup drained to 1% or 3–8% below market: no liquidation unsettled | blocked(route, floor) = 0 | `Q-084`, `Q-085`, `Q-250`, `Q-251`, `Q-273` | s 0.5–2%, both paths | Holds (1,683 top-up calls) |
| SIM-06B | With both USDT routes reverting, in-kind at the 12h short delay keeps bad debt at the routes-working level | bad debt ≤ baseline | `Q-084`, `Q-133`, `Q-228`, `Q-251` | collapse path | Holds |
| SIM-06C | Pool skew up to ±20% never pushes recovery below the floor or a leg below its minimum | R/floor ≥ 1 and every leg settles | `Q-085`, `Q-131`, `Q-250` | USDC 0.87, $50k seize | Holds (R/floor ≥ 1.0093) |
| SIM-06D | Routes below the top-up range open in-kind automatically within 6h + 1h of the first failure, with bad debt no higher than manual opening | first opening ≤ failure + 7h | `Q-251` | collapse, backup 15% below market | Holds (9.2h vs 15.2h manual) |
| SIM-06E | The shortfall top-up keeps liquidations at full size with the backup 8% below market | blocked = 0 with, > 0 without | `Q-251` | collapse path | Holds |
| SIM-07A | Accounts opened at HF ≥ 1.10 are not liquidated by interest within 6 months at ≤ 12% APR | first liquidation ≥ day 182 | `Q-018`, `Q-096`, `Q-145` | 2 years, prf 0.20–0.40 | Holds (day 290) |
| SIM-07B | Interest-driven liquidations create no bad debt | bad debt = 0 | `Q-096`, `Q-098`, `Q-101` | as SIM-07A | Holds |
| SIM-07C | Every interest-driven liquidation is keeper-profitable at 20 gwei with a 2% minimum bonus | min call P&L ≥ 0 | `Q-098`, `Q-169`, `Q-179` | APR 12%, prf 0.40 | Counterexample |
| SIM-08A | At prf ≤ 0.40 one token must fall below 0.10 before an account opened at 1.10 is insolvent | (CF/1.10)² < 0.10 | `Q-020`, `Q-072`, `Q-186` | CF token 0.78 | Holds (0.0804 at 0.40) |
| SIM-08B | A minimum bonus ≥ 1% with s ≥ 0.5% leaves no floor-blocked liquidation on the USDC path | blocked(floor) = 0 | `Q-085`, `Q-159`, `Q-179`, `Q-198` | prf 0.40, no top-up, no in-kind | Holds |
| SIM-08C | The tail factor CF bounds the measured loss per $ of token exposure when a token goes to 0.02 | loss/exposure ≤ CF | `Q-186`, `Q-249` | prf 0.20–0.40, with and without a 48h outage | Holds (0.081 ≤ 0.312 at 0.40) |
| SIM-08D | For stable pools the incident term is zero, so the tail term binds | incident loss factor = 0 | `Q-192`, `Q-249` | LP drops 6.7–40%, prf ≤ 0.40 | Holds |

Totals: 41 properties; 35 Holds, 6 Counterexample, every one as recorded.

### Counterexamples

Each is a consequence of a rule the spec states and accepts; the measurement gives its size.

- **SIM-01D** With GHO at 0.90, the GHO leg follows Chainlink below $1 (`Q-177`) while GHO debt stays at Aave's fixed $1 (`Q-100`), so drifted accounts in GHO pools are liquidated although they are solvent in GHO terms: 3.0 liquidations and $163 of borrower loss at prf 0.40 on the 2M book. The cost is the bonus on what is seized.
- **SIM-02H** When both USDC routes fail for 24h with no standby switch, USDC markets count as worthless and USDC debt at its accepted price plus 5% (`Q-247`). Accounts that also hold a fresh market or GHO debt are liquidated there: 24.7 liquidations of accounts healthy at market prices (0.3 without the outage) and $9,592 of borrower loss, with no bad debt and no USDC repaid at a stress price. A standby switch within 30 minutes removes all of it (`SIM-02I`).
- **SIM-04C** With no approved keeper for 48h on the tail path, the permissionless fallback (`Q-213`) liquidates only where the call pays: 312 calls, 114 accounts left, 9,874 GHO of bad debt (worst seed 12,109), against 351,280 with nobody and 0 with the standby keeper. The standby keeper and its agreement carry the duty to clear unprofitable accounts.
- **SIM-05A** Break-even minimum bonus for a 1,000 GHO dust-rule liquidation after gas, the GSM fee and Avana's fee: 0.00% at 0.2 gwei, 8.76% at 20 gwei, 43.3% at 100 gwei (100 GHO: 0.78% / 86.5% / over 600%). No bonus within the curve makes small liquidations profitable in a gas spike; reimbursement covers them (`Q-098`, `Q-277`).
- **SIM-05C** If approved keepers skip loss-making calls, a dust-heavy book on the tail path at 100 gwei leaves 351 accounts unliquidated and 72,062 GHO of bad debt. The reimbursement commitment is what turns dust into keeper cost instead of bad debt.
- **SIM-07C** Interest-driven liquidations happen just below HF 1 at the minimum bonus; at 20 gwei and 12% APR the worst call loses $89 and reimbursement totals $5,132 over two years at prf 0.40; at 0.2 gwei none loses money.

## Results

- **Bad debt** is zero in every brief scenario (depegs, provider-wide outages up to 72h on the USDC path, correlated drops to 0.80, keeper outages, interest) at every pool risk factor 0.20–0.40. An account opened at HF 1.10 reaches HF 1 at a 9.1% value drop (one token at 0.826) and is insolvent only when one token falls below (CF/1.10)²: 0.0201 at prf 0.20, 0.0453 at 0.30, 0.0804 at 0.40.
- **Bad debt appears only when a pool token goes to zero while liquidation of its markets stops**: a 48h provider-wide outage on the tail path (21k at prf 0.20, 224k at 0.30, 374k at 0.40 on the 2M book), no keeper of any kind for 48h (351k at 0.40), routes reverting with in-kind never opened (330k on the collapse path), or approved keepers skipping dust (`SIM-05C`). With working feeds and keepers the tail path ends with no bad debt at any prf: every account is liquidated on the way down.
- **Oracle timing under the final rules**: a provider-wide failure is Cached for exactly the 1h window from the first failed read and Expired after it in all 320 measured spells (`SIM-02D`); a silent stall stops seizure and borrowing within 78 minutes of the stall at 10-minute resolution (`SIM-02C`); borrowing on a stale price lasts at most 1.0h of a 12h stall, so the stale-price attacker of `ATTACK-056` never borrows (`SIM-03C`, `SIM-03D`).
- **The alternate route under Q-274**: when only a token's primary and TOKEN/X leg freeze while X/USD keeps updating, the market stays Drifting with seizure paused until the frozen leg passes its 87,000 s `feedMaxAge`, instead of Cached then Expired; on the USDT collapse this spent 141 Expired steps where a reverting outage spent 282, and delayed the first liquidation in the accounts' fresh markets by at least 1h, with the same bad debt (`SIM-02F`).
- **Standby routes**: a wrong primary stuck at $1 during the USDC depeg blocks 18.3 accounts for 320 account-hours without a switch; a switch within 15 minutes or 1h cuts it to 0.2–0.4 account-hours, 4h to 9.3 (`SIM-02G`). A 30-minute switch also ends a USDC route outage before the 1h Cached window expires, so no stress valuation occurs (`SIM-02I`).
- **Settlement**: the effective slippage keeps the floor above the debt for every non-dust liquidation, so the SettlementBudget drew nothing in every scenario except the dust wave of `SIM-05E` (121 draws, 29.73 GHO, largest market 19.61 GHO in any 24h against its 125 GHO sub-cap). Avana's fee from oracle value is paid whenever the surplus covers it (97 GHO on the USDC path at prf 0.40).
- **Shortfall top-up and in-kind**: with the backup route 3–8% below market, callers closed 1,683 gaps with top-ups and every liquidation ran at full size (`SIM-06A`, `SIM-06E`); with it 15% below market, shortfall reports opened in-kind at 9.2h against 15.2h for governance at the short delay (`SIM-06D`). A route that reverts proves no shortfall (`REQ-SWAP-102`), so only the 12h short-delay opening applies; on the collapse path it still kept bad debt at 0 (`SIM-06B`).
- **Keeper cost, not bad debt, is the main expense**: a slow collapse makes keepers re-liquidate as each price step pushes accounts back below HF 1. On the tail path with target HF 1.10, about 950 calls and $56k of reimbursement per 2M book at 20 gwei; $324k (default book) to $375k (dust-heavy) at 100 gwei. Target 1.02 / 1.05 / 1.20 gives $225k / $107k / $28k at 20 gwei (`SIM-05D`).
- **Incident controls**: `Paused(General)` with every market breaker tripped changes no liquidation outcome (961 vs 959 calls, no bad debt) and refuses no rescue top-up; `Paused(MintPathSuspect)` refused 33 top-up attempts and raised borrower loss from $21,518 to $21,562 (`SIM-04D`).
- **Grace** (0–2h at HF 0.90–0.95) added no bad debt; every outage that reached Expired started one window per market and one for the DebtOracle, from source-timestamp evidence.

## Launch values and what the simulations show

Values fixed by the spec:

| Parameter | Spec value | What the simulations show |
|---|---|---|
| `poolRiskFactor` | ≤ 0.40 (`Q-186`); CF 0.312 at token CF 0.78 | One token must fall below 0.0804 before an account opened at 1.10 is insolvent (`SIM-08A`); no bad debt on any brief path |
| `minOpeningHealthFactor`, `aaveTargetHealthFactor` | 1.10 / 1.10 (`Q-018`, `Q-185`) | No interest-driven liquidation before day 290 at 12% APR (`SIM-07A`); target 1.10 halves reimbursement against 1.05 in a slow collapse (`SIM-05D`) |
| `minLiquidationBonus`, `slippageAllowanceBps` | ≥ 200 bps / 100 bps (`Q-179`, `Q-196`) | s_eff = 1% at the minimum bonus; no floor block on the USDC path for any minimum bonus ≥ 0.5% with s ≥ 0.25% (`SIM-08B`) |
| `maxShortfallBps`, `keeperMinRepay` | 1,000 / $500 (`Q-251`) | Routes up to 8% below market settle at full size (`SIM-06E`) |
| `inKindAutoDelay`, `inKindExpiry`, short delay | 6h / 24h / 12h (`Q-251`, `Q-196`, `Q-228`) | Automatic opening 6h after the first report; manual opening at 12h kept collapse-path bad debt at 0 at prf 0.40 (`SIM-06B`, `SIM-06D`) |
| Primary heartbeat, `borrowPriceMaxAge`, `liquidationPriceMaxAge` | ≤ 3,600 s / min(hb + 600, 4,200) / hb + 600 (`Q-274`) | Stale-price borrowing bounded to 70 minutes (`SIM-03C`) |
| `cachedWindow`, `disagreementPauseMax` | 3,600 s / 3,600 s (`Q-183`) | Every failure Cached for the full window (`SIM-02D`) |
| `feedAgreementToleranceBps` | primary + alternate deviation thresholds + 50 bps (`Q-184`) | No pause at the bound; 0.25–1% would block 2–17 accounts in the USDC depeg (`SIM-01E`) |
| `graceDuration`, `graceHealthFactor` | 1,800 s / 0.95 (`Q-196`) | No bad debt across 0–2h and 0.90–0.95 (`SIM-02E`) |
| `usdBandLow`, `usdBandHigh` | 0.90 uncapped / 1.02 capped (`Q-275`) | Borrowing closed below the band in every correlated drop (`SIM-03A`) |
| `debtStressRiseBps` (USDC) | 500 (`Q-248`) | Forced liquidations bounded by the bonus, no bad debt (`SIM-02H`) |
| SettlementBudget caps | 25 / 500 GHO, market sub-cap max(100, 500/markets) (`Q-196`, `Q-267`) | Draws only in a dust wave with top-ups, far inside every cap (`SIM-05E`) |
| `firstLossReserveMinimum` (GHO) | 400,000 (`Q-196`, `DEF-019`: 2,000 bps of the 2M GHO drawCap) | Covers a token cap of $1,282,051 less slices at prf 0.40 under the tail term |

Values the Aave DAO and its service providers set (`Q-197`, `Q-249`), with the measurements that size them:

| Value | Measurement |
|---|---|
| `tokenUsdCap` | Tail factor 0.312 at prf 0.40: the 400,000 GHO reserve covers a token cap of $1,282,051 less the token's slices. The simulated 2M book carries USDC exposure of $7.9M and USDT exposure of $4.6M at prf 0.40, which the tail term prices at a reserve of 2.46M GHO; the measured worst tail loss is 0.081 per $ of USDT exposure, against the 0.312 the guidance assumes (`SIM-02B`, `SIM-08C`). The incident term is zero for every stable-pool drop up to 40% (`SIM-08D`). |
| `keeperReimbursementBudget` | $56k per 2M GHO of debt at 20 gwei per slow-collapse event at target 1.10; $324k–$375k at 100 gwei; $5k over two years of interest-driven liquidations at 20 gwei (`SIM-05D`, `SIM-05B`, `SIM-07C`) |
| Standby route response | A guardian switch within 30 minutes ends a token's route outage inside the Cached window (`SIM-02I`); within 1h it ends a wrong-primary incident with 0.4 blocked account-hours (`SIM-02G`) |
| Standby keeper response | Up to 4h changes nothing; 12–24h raises borrower loss but not bad debt (`SIM-04B`) |

## Modelling choices

- **Cached start**: the first failed read, `min(S_ts, failedSince, now)`, with keepers poking every step; evidence of an outage for grace comes from the legs' last gaps, as in `SPEC-ORC-014`.
- **Wrong feed**: a primary that keeps publishing on its heartbeat with a stuck answer.
- **Standby switch**: the guardian replaces the slot that disagrees with the standby, or the primary when the token has no valid route or its alternate is past its borrow age, once the market's seizure has been blocked for the switch delay and the standby is valid.
- **Shortfall reports**: an approved keeper reports after its top-up attempt fails; a report counts only when every leg delivers at `minOut = 1`, so a reverting route gives no evidence.
- **Manual in-kind**: governance schedules `enableInKind` at the first observed failure; it opens 12h later for 24h.
- **In-kind**: keeper P&L at market value of the tokens it keeps; no Avana fee.
- **Keeper reimbursement**: paid in full to approved keepers; `rational` mode shows the alternative.
- **Borrowers** watch HF at last accepted prices, the value the Lens reports.

## Traceability rows

| Requirement | Statement (short) | Simulation IDs | Status |
|---|---|---|---|
| `Q-020`, `Q-186` | CF = min(CF0, CF1) × poolRiskFactor, factor ≤ 0.40 | SIM-01A, SIM-03B, SIM-08A, SIM-08C | Holds |
| `Q-062`, `Q-084`, `Q-187`, `Q-273` | Fixed primary and independent backup routes, never the market's own pool | SIM-01B, SIM-01C, SIM-06A | Holds |
| `Q-072`, `Q-179`, `Q-185` | Aave V4 bonus curve, minimum bonus, target HF | SIM-00A, SIM-05A, SIM-05D, SIM-07C, SIM-08B | Holds; SIM-05A, SIM-07C Counterexample (gas) |
| `Q-079`, `Q-128`, `Q-183` | Chainlink routes, Cached window from the first failed read | SIM-02A, SIM-02D | Holds |
| `Q-082`, `Q-147`, `Q-213` | Standby keeper, permissionless fallback | SIM-04A, SIM-04B, SIM-04C | Holds; SIM-04C Counterexample (fallback only when paid) |
| `Q-085`, `Q-159`, `Q-198`, `Q-250` | Recovery floor, effective slippage, per-leg minimum | SIM-01B, SIM-06A, SIM-06C, SIM-08B | Holds |
| `Q-088`, `Q-129`, `Q-154`, `Q-264` | Grace after Expired | SIM-02E | Holds |
| `Q-096`, `Q-145` | GHO rate, idle accounts | SIM-07A, SIM-07B | Holds |
| `Q-098`, `Q-169`, `Q-277` | Keeper reimbursement, no minimum debt, $10 minimum pledge | SIM-05A, SIM-05B, SIM-05C, SIM-07C | Holds; SIM-05A, SIM-05C, SIM-07C Counterexample (accepted cost) |
| `Q-100`, `Q-177` | GHO debt at $1, stable legs capped at $1 | SIM-01D | Counterexample (design consequence) |
| `Q-101`, `Q-192`, `Q-249` | First-Loss Reserve, incident and tail terms | SIM-02B, SIM-08C, SIM-08D | Holds |
| `Q-133`, `Q-228`, `Q-251` | In-kind settlement, shortfall top-up, automatic opening | SIM-06B, SIM-06D, SIM-06E | Holds |
| `Q-162`, `Q-184`, `Q-199`, `Q-208` | Agreement tolerance, disagreement pause and expiry | SIM-01E, SIM-02G | Holds |
| `Q-176`, `Q-195`, `Q-275` | USD band on uncapped low, capped high | SIM-03A | Holds |
| `Q-182`, `Q-274` | Hourly primaries, borrow and liquidation ages, alternate held to its borrow age | SIM-02C, SIM-02F, SIM-03C, SIM-03D | Holds |
| `Q-227`, `Q-241`, `Q-252` | Pause reasons, breakers, rescue top-ups | SIM-04D | Holds |
| `Q-247`, `Q-248` | Per-reserve gates, stress valuation, DebtOracle, standby switch | SIM-02F, SIM-02G, SIM-02H, SIM-02I | Holds; SIM-02H Counterexample (bounded by the bonus) |
| `Q-256` | Avana fee from oracle value | SIM-05A | Modelled |
| `Q-267` | SettlementBudget per-market sub-cap | SIM-05E | Holds |
| `Q-152` | Verification stack | SIM-00A, SIM-00B | Holds |

Related Z3 IDs: the floor-covers-flash algebra is MATH-ST-01/02 (`z3/settlement`); HF and the opening floor MATH-AR-01..05 (`z3/aave-risk`). These simulations do not re-prove them; they measure liveness and losses around them.

## Run log

### 2026-11-10

- Command: `cd spec/05-verification && for f in $(find simulation -name '*.py' | sort); do .venv/bin/python "$f"; echo "exit=$?"; done` (the simulation part of `run_all.sh`).
- Python 3.9.6, standard library only.
- Seeds 11/22/33 (sim05 Part B and D, sim07: 11/22; sim02 timeline: seeds 0–39; `SIM-00A`: `random.Random(5)`, 600 cases). Bounds: prf 0.20–0.40 (0.10–0.50 in sim08), outages 1–72h, horizons 74–122h (two years in sim07), 200 accounts (600 in the dust-heavy book).
- Wall time 360 s on a shared machine.

| Script | Holds | Counterexample | Exit code |
|---|---|---|---|
| `_simcore.py` | 2 | 0 | 0 |
| `sim01_depeg.py` | 4 | 1 | 0 |
| `sim02_oracle_outage.py` | 8 | 1 | 0 |
| `sim03_correlated_drop.py` | 4 | 0 | 0 |
| `sim04_keeper_outage.py` | 3 | 1 | 0 |
| `sim05_gas_dust.py` | 3 | 2 | 0 |
| `sim06_route_stress.py` | 5 | 0 | 0 |
| `sim07_interest_accrual.py` | 2 | 1 | 0 |
| `sim08_recommendations.py` | 4 | 0 | 0 |
| **Total** | **35** | **6** | **0** |
