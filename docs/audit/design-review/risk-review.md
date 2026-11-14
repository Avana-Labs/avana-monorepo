# Avana design risk review

Date: 2026-11-09. Scope: the protocol design as written in `docs/spec/` (rewritten for decisions `Q-223`…`Q-240`), the parameter registry (`docs/spec/01-architecture/05-parameters.md`, cited as 1.5), the decisions table (`docs/spec/04-security/04-design-decisions.md`), the interface tree under `contracts/src` (interfaces and types only; no implementation exists yet) and these user decisions of 2026-11-09:

- U1: liquidation, repay and debt-free withdraw are never paused.
- U2: circuit breakers trip automatically and block NEW activity only.
- U3: the 3-of-5 Emergency Guardian can pause immediately.
- U4: an address freeze blocks new activity only; the frozen address's own repay and the liquidation of its positions still work; unfreeze goes through the timelock.

Stance: correctness before gas before UX; explicit invariants; fail closed; adversarial and MEV-aware. Where the spec is silent, the assumption is stated in the text as **Assumption**.

Reference numbers used throughout (from 1.5 and the decisions):

| Symbol | Value | Source |
|---|---|---|
| `CF_LP` | 3,120 bps (0.78 × 0.40) | `Q-186`, `SPEC-CF-001`, `SPEC-HUB-005` example |
| `minOpeningHealthFactor` | 1.10 | 1.5 |
| `PROXY_HEALTH_FACTOR_FLOOR` | 1.05 | 1.5 |
| Max loan-to-value at opening | 0.312 / 1.10 = 28.36 % | derived |
| `maxLiquidationBonus` / min bonus | 10,500 / 10,200 bps; `healthFactorForMaxBonus` 0.90 | `SPEC-HUB-005` example |
| `aaveTargetHealthFactor` | 1.10 | 1.5 |
| `slippageAllowanceBps` | 100 | 1.5 |
| `buySlippageAllowanceBps` | 1–300, set per debt reserve | 1.5 |
| `floorRoundingAllowanceGho` | 1 GHO | 1.5 |
| `maxFlashFeeBps` | 0 | 1.5 |
| `avanaFeeShareBps` | 2,000 | 1.5 |
| SettlementBudget | 25 GHO per call, 500 GHO per 24 h (GHO reserve); maxima 1,000 / 20,000 | 1.5 |
| `creditLineGho` | 2,000,000 GHO | 1.5 |
| `firstLossReserveMinimum[GHO]` | 100,000 GHO | 1.5 |
| `minPledgeUsd` | $10 per market | 1.5, user override |
| `poolShareMaxBps` | 1,000 | 1.5 |
| `usdBandLow` / `usdBandHigh` | 0.90 / 1.02 | 1.5 |
| `twapWindow`, `twapToleranceTicks` | 1,800 s, 50 ticks | 1.5 |
| `cachedWindow`, `disagreementPauseMax` | 3,600 s, 3,600 s | 1.5 |
| `graceDuration`, `graceHealthFactor` | 1,800 s, 0.95 | 1.5 |
| `borrowPriceMaxAge`, `liquidationPriceMaxAge` | 3,600 s; heartbeat + 600 s | 1.5 |
| `SHORT_DELAY`, `normalDelay`, `GRACE_PERIOD` | 12 h, 5 d, 14 d | 1.5 |
| `keeperFloor` | 3 | 1.5 |

Reference account used in the worked examples: one USDC/USDT full-range position worth C0 = $100,000 (50,000 whole vault tokens at $2), GHO debt opened at HF 1.10, so D = 100,000 × 0.312 / 1.10 = 28,364 GHO.

---

## 1. Invariants that must hold

The spec has 73 invariants (`INV-001`…`INV-073`, `docs/spec/04-security/01-global-invariants.md`). They cover unit backing, custody, access, per-call conservation and per-action bounds well. They do not state the system-level economic invariants below. Each one is written so it can be asserted after every step of a stateful test. "Present" names the closest existing rule; "Missing" means no INV, PROP or TEST states it.

### 1.1 Solvency per debt asset (Missing)

For every debt asset `a` (GHO at launch) and every Borrow Spoke on the Avana Stable LP Hub, at the end of every transaction:

```
Assets_a  = Σ_accounts min(Debt_{acct,a}, RealizableShare_{acct,a})        (collateral that can pay that debt)
          + PendingValue_a                                                   (Collateralization pending units at oracle value × (1 − slippageAllowanceBps))
          + CoverageFunded_a                                                 (Coverage Spoke funded balance of a)
          + BudgetBalance_a                                                  (SettlementBudget GHO, for a = GHO)
Liabilities_a = Σ_accounts Debt_{acct,a} (drawn + premium) + HubDeficit_a
INVARIANT: Assets_a ≥ Liabilities_a
```

`RealizableShare` is the account's collateral at the stressed realizable value of §1.2, allocated to debt assets in proportion to debt value. Because one account has one health factor over all its reserves (`INV-072`), allocation per asset is a reporting convention; the binding form is the per-account form `RealizableValue_acct ≥ Σ_a DebtValue_{acct,a}` summed over accounts that are not in surplus, plus the reserve.

Present: `INV-057` is Hub bookkeeping ("liquidity + drawn + deficit = added + accrued"), which holds even when every loan is worthless. `TEST-127` checks losses against the reserve in one fork scenario. Neither is a solvency invariant.

### 1.2 Conservative valuation ≤ realizable value (Partly present)

```
price8 ≤ 2·√(v0·v1) − 1                         (SPEC-ORC-008: fair value at capped Chainlink prices)
UnwoundValueAtOracle(spot) ≥ price8 × units     (SPEC-ORC-007: any pool spot; full range)
Realizable(units, size) = Σ_legs route_out(leg, size) ≥ V × (1 − s) − U − floorRoundingAllowanceGho   (SPEC-LIQ-005, enforced by revert)
```

The first two hold by proof (MATH-UO, SYM-22/23/26). The third is not an invariant: it is a revert condition. When the routes realize less than the floor, the liquidation reverts and the loss moves into the account's future. The missing invariant is the stressed one:

```
For every market m, at the market's debt cap and the listing stress case:
  route_out(m, debtCap_m × LB / CF_LP-scaled size) ≥ V × (1 − slippageAllowanceBps)
```

Today this is an off-chain listing obligation (`REQ-ROUTE-006`, test list line 431 "Off-chain obligations without an automated test"). Recommendation: state it as an invariant of the listing payload and re-measure it on a schedule (§9).

### 1.3 No profitable zero-risk loop (Holds by construction, not stated)

1. Self-liquidation through `liquidatePermissionless`: the borrower repays `D` and receives its own collateral `D × LB` minus Avana's 20 % of surplus and conversion loss. Net for the borrower: −0.2 × S − slippage − gas < 0. Example: `D = 1,950`, `S = 90.3` (`SPEC-LIQ-008` example): borrower-liquidator loses 18.06 GHO plus gas.
2. Self-liquidation through an affiliated approved keeper: a draw happens only when `R < Gcov + φD − K`, and then `keeperOut = 0` (`SPEC-LIQ-010`). The draw is bounded by `U + floorRoundingAllowanceGho` ≈ 1 GHO per call (`INV-038`). Gain ≤ 1 GHO per call against ≥ $30 of gas. Not profitable.
3. Pledge, borrow, flash-repay loops: `CF_LP` 31.2 % and a 1.10 opening floor mean each loop iteration adds at most 28.4 % of its collateral as debt; no step creates value. `Q-031` excludes Multiply.

Invariant to state: "for any sequence of calls by one actor (any set of wallets) that starts and ends with that actor holding no debt, the actor's GHO-equivalent holdings at oracle prices do not increase by more than `n × (U + floorRoundingAllowanceGho)` where `n` is the number of budget-drawing liquidations in the sequence."

### 1.4 Liquidation never amplifies insolvency (False below collateral = debt × LB; not stated)

For one liquidation repaying `x` and seizing `x × LB`:

```
deficit_before = max(0, Debt − Coll),  deficit_after = max(0, (Debt − x) − (Coll − x·LB))
deficit_after − deficit_before = x·(LB − 1)   whenever Coll < Debt·LB
```

So once an account holds less collateral than `Debt × LB`, every liquidation moves `x·(LB − 1)` (up to 5 %) of value from the reserve to the liquidator. `MATH-AR-11b` and `SYM-13a` record the same fact (HF falls below `LB × CF`). This is Aave V4 behaviour that Avana cannot change. The invariant that must hold instead:

```
deficit_after ≤ deficit_before + seizedOracleValue × (1 − 1/LB)
HF_after ≥ HF_before                  whenever HF_before ≥ LB × CF_LP (= 1.05 × 0.312 = 0.3276)
```

The reserve must be sized for the first line (§3, DR-15).

### 1.5 No cross-market contagion (Violated today; see DR-02)

```
A failure confined to market m (price state not Live, route failure, Aave freeze of m's reserve)
  must not block liquidation of any account's collateral in a market m' ≠ m,
  and must not block repay or debt-free withdraw anywhere.
```

Shared resources that legitimately couple markets: the GHO credit line, the GHO Coverage Spoke, the SettlementBudget per `(spoke, GHO)` caps, the FlashMinter bucket, GSM capacity. Each needs its own capacity invariant (§9).

### 1.6 Backing and conservation (Present)

- Units: `totalSupply == Σcredited + pending.units` (`INV-001`, `INV-066`); NFPM liquidity ≥ credited (`INV-002`); share drop == supply drop == debit (`INV-014`).
- Per call GHO conservation in LPVaultSwap: `K + F + R + g' + Bd = G + (F + φ) + A + keeperOut` (`INV-035`, `SPEC-LIQ-010`); debt-asset change 0.
- No residual balances or allowances (`INV-021`).
- Missing at system level: "GHO entering Avana contracts over a whole sequence equals GHO leaving plus GHO held by the Coverage Spoke and the SettlementBudget". The per-call identity does not catch a path that leaves GHO in a route or the Adapter across calls.

---

## 2. Failure modes

### 2.1 50 % price shock

**A. One pool token −50 % (USDT to $0.50) in a USDC/USDT market.**

1. LP value: `2·√(1 × 0.5) = 1.414` per whole token, a 29.3 % drop. C = $70,711. HF = 70,711 × 0.312 / 28,364 = 0.778.
2. LPOracle: `√(q0·q1) = 0.707 < usdBandLow 0.90` → Drifting (`SPEC-ORC-011`). TWAP vs Chainlink tick gap > 50 ticks during the move → Drifting. Effect: borrow and withdraw-with-debt blocked, new-account pledges blocked, top-ups allowed (`EMG-003`, `EMG-004`).
3. Liquidation: allowed only while both Chainlink routes of each token are fresh and agree (`EMG-004`). HF 0.778 < 0.90 → bonus 5 %. Aave sizes to target HF 1.10: repay `x = (1.1·D − 0.312·C)/(1.1 − 0.312·1.05) = 11,831` GHO, seize $12,423. Account after: C = $58,288, D = 16,533, HF 1.10.
4. Settlement: the seized liquidity unwinds to equal value in each token: $6,211 USDC and 12,423 USDT ($6,211). `V = 12,422.6` GHO; `s = min(100, 476) = 100` bps; `minGho ≈ 12,297` GHO. USDC → GSM → GHO works. The USDT GSM freezes outside its price band (`4.3` GSM row: "the GSM freezes when the underlying leaves its price band"), so USDT goes to the backup DEX route. The USDT leg must return ≥ 6,086 GHO, i.e. a realized USDT price ≥ $0.490 against an oracle of $0.500.
5. If the DEX realizes $0.48 (Chainlink lagging a falling market, or depth drained): R = 6,211 + 5,963 = 12,174 < 12,297 → `RecoveryBelowFloor`. Every routed liquidation of the market reverts. Permissionless callers revert the same way. In-kind needs `enableInKind` (short delay 12 h, cancellable) and a keeper willing to take USDT at the oracle price, which is above market: no rational keeper does.
6. Defenses that trigger: Drifting (new risk blocked), recovery floor (protects lenders per call), USD band, `EMG-047` (any liquidation halt blocks borrow for affected accounts).
7. Residual loss: zero for lenders as long as liquidation eventually completes before LP value < debt. Bad debt for a max-LTV account starts at `√p < 0.2836`, i.e. USDT < **$0.080**; bonus-funded loss (§1.4) starts at USDT < **$0.089**. Borrower loss: 5 % bonus on $12,423 = $592 plus the 1 % slippage room.

**B. Both pool tokens −50 % (common-mode USD stable failure).**

1. C = $50,000, HF 0.55. Band breach → Drifting. Repay 20,197, seize $21,207, after: C = $28,793, D = 8,167, HF 1.10.
2. GHO is fixed at $1 as debt and as `Pgho` (`Q-100`). If GHO trades with its backing (also ≈ $0.50), DEX routes return about 2 GHO per $1 of oracle value: `R` far above the floor. Liquidations are profitable; lenders are repaid in GHO that is worth $0.50. The real loss is outside Avana (GHO peg).
3. If GHO holds $1 while USDC and USDT fall: GSM routes freeze for both tokens; DEX routes into GHO are the only path; depth of GHO pairs is the binding constraint. Floors revert as in A.5.
4. Insolvency threshold: both tokens < **$0.284** (collateral = debt) for max-LTV accounts.

**C. Debt asset rises 50 % (WETH debt reserve, future listing).**

1. Debt 28,364 → 42,545 GHO value; HF 0.733; bonus 5 %.
2. Stale debt feed check: the WETH feed must be within `liquidationPriceMaxAge`, else the whole account is shielded (`DebtPriceStale`, `INV-072`).
3. Two-leg settlement: buy WETH with GHO, bounded by `bound = ⌈X·Pdebt/Pgho·(1 + cBuy)⌉` (`SPEC-LIQ-015`); `s` shrinks to cover `cBuy` (`SPEC-LIQ-016`). With `bNet = 10,500`, `cBuy = 30`: s = 100 bps. Repay 20,197 GHO-value of WETH, seize $21,207.
4. Correlated: every stable-LP account with WETH debt drops together (`ATTACK-128`); all keepers buy WETH and sell stables at the same time. Binding constraints: buy-route depth (`buyRouteDepthThresholdGho`), FlashMinter capacity (2M GHO per transaction, assumed), budget 500 GHO/24 h for rounding.
5. Insolvency threshold: WETH rise > 3.53× (+253 %); bonus-funded loss from +236 %.
6. At the minimum bonus (HF just below 1), `bNet = 10,200`: with `cBuy ≥ 200`, `s = 0` and every routed liquidation must convert at zero loss (DR-06).

### 2.2 Sudden liquidity withdrawal

**A. Uniswap pool depth drains (non-Avana LPs leave, or liquidity migrates to another pool or version).**

1. `poolShareMaxBps` (10 %) is tested only at pledge (`SPEC-CAP-005`). If 80 % of other liquidity leaves, Avana's share rises from 10 % to 35.7 % with no on-chain reaction.
2. TWAP manipulation cost falls with liquidity: moving the 30-minute mean by 50 ticks needs the pool held 0.5 % off for 30 minutes, or a one-block move of 50 × 150 = 7,500 ticks (×2.1 price). Cost scales with in-range liquidity. Effect of a successful move: Drifting (borrow DoS) only; served prices come from Chainlink, so no overvaluation.
3. If a conversion route goes through this pool (Assumption: a backup DEX route may use the same pool; `Q-187` forbids only GSM/PSM overlap), each seizure removes Avana liquidity from the pool and the next conversion sees less depth: liquidations become reflexive. Floors revert.
4. Defenses: none on-chain beyond the pledge-time share test. Residual: liquidation halt in that market until depth returns or in-kind is enabled.

**B. Hub GHO liquidity drained (borrowers at `drawCap`, or the DAO removes unused GHO from the Lend Spoke).**

1. Borrowing reverts on Aave liquidity. Repay adds liquidity. Liquidation brings its own GHO (flash mint) and repays into the Hub. Debt-free withdraw touches the vault-token reserve, which is non-borrowable (`INV-073`), so its liquidity is always there.
2. Residual: the DAO cannot withdraw lent GHO until borrowers repay. Lender liquidity risk, accepted by `Q-168`. No Avana loss.

**C. Lend Spoke withdrawals for later supply assets (USDC lenders).** Same as B per asset. A run raises utilization to 100 % and rates to the slope maximum; Avana borrowers' HF decays faster (interest), which pulls accounts toward liquidation. No path in Avana depends on Lend Spoke liquidity for liquidation (the buy leg buys from venues, not the Hub).

**D. Withdrawal cascade.**

1. Debt-free withdrawals reduce Avana exposure; they cannot hurt solvency.
2. Withdraw-with-debt re-checks HF ≥ 1.10 after every call (`INV-025`). Cascade is bounded per account.
3. The harmful cascade is seizure-driven (A.3): each liquidation unwinds Avana liquidity from the pool that also prices TWAP and may carry the backup route.
4. Coverage cascade: one market's deficit consumes the single GHO Coverage Spoke for every market (`R-23`).

### 2.3 Oracle lag and manipulation

| Case | Step by step | Defenses | Residual |
|---|---|---|---|
| Spot vs TWAP lag | Pool spot moves in seconds; 30-minute TWAP and Chainlink lag. Gap > 50 ticks → Drifting. | Borrow and withdraw-with-debt blocked (`EMG-003`); served price is Chainlink, never spot (`SPEC-ORC-007`). | Borrow DoS during fast moves. Liquidation continues at Chainlink prices. |
| Chainlink lag within deviation | A feed can be off by deviation threshold + one-heartbeat drift. Listing margin requires `10⁴ − CF_LP > dev + drift` (`SPEC-CF-004`): 6,880 bps margin vs 50–350 bps error. | `borrowPriceMaxAge` 3,600 s blocks borrow on old prices. | Borrow at a price up to ~3.5 % high (alternate route); covered by the 68.8 % CF margin. SIM-03D shows the stale-price borrow still exists. Floors revert when Chainlink is above market by more than ~1 % (liveness). |
| Chainlink staleness (one route) | Failover to alternate; alert only (`TB-022`). | Agreement check needs both fresh; with one stale, no agreement test. | One feed operator becomes the only source; alternate route's 24 h heartbeat (USDT/ETH example) widens error. |
| Staleness (both routes) | Cached for `cachedWindow` 3,600 s from first failed read, then Expired (`SPEC-ORC-013`). Liquidation halted in Cached and Expired for every account holding the market (`EMG-006`/`007`). | Borrow blocked. | Halt lasts until a feed returns or a new price source executes: `setPriceSource` is normal delay, **5 days**, cancellable by any single canceller. Caps are sized for 48 h (`Q-192`). DR-03. |
| Zero or negative answer | `answer > minAnswer` required; normalised 0 is a failure (`REQ-ORACLE-002`). Leg invalid → failover → Cached → Expired. | Never served as a price. | Same halt as staleness. A non-GHO debt feed returning ≤ 0 makes AaveOracle revert (4.3 line 37): liquidation of every account holding that debt is blocked; no test covers it. |
| Extreme high answer | `answer < maxAnswer`; stable legs capped at $1 (`SPEC-ORC-004`); `MAX_ROUTE_ANSWER` $10,000. | Stable ceiling makes an upward glitch harmless for collateral. | Debt side: a WETH feed spiking up triggers liquidations of solvent accounts at 5 % bonus. Bounded to bonus loss per account; no Avana-side check of debt price sanity. |
| Feed disagreement | `|p − b|·10⁴ > T·min(p,b)` with `T ≥ dev_p + dev_b + 50`; e.g. USDC 25 + 150 + 50 = 225 bps. Liquidation paused for `disagreementPauseMax` 3,600 s, then "treated as Expired" until routes agree or a timelock fix (`EMG-005`, `SPEC-ORC-016`). | Borrow blocked. | In a fast depeg the alternate (higher deviation threshold, gas-congested updates) lags; a disagreement over 2.25 % lasting > 1 h stops liquidation of the market and, through the account-wide gate, of every account holding it (DR-02, DR-03). |
| Common-mode error (both routes wrong the same way) | Agreement passes; USD band catches only absolute level outside 0.90–1.02; TWAP check catches ratio error > 50 ticks. | Band, TWAP. | Both tokens of a pool mispriced equally within the band are not detected; bounded by the band (10 % low, 2 % high) and CF margin. |
| Chainlink round-ID phase change | Recovery evidence reads `getRoundData(roundId − 1)` (`SPEC-ORC-014`); at the first round of a new aggregator phase, `roundId − 1` is not a valid round. | "Unusable lookup gives no evidence". | Grace latch does not engage after an outage that spanned an aggregator upgrade; accounts with HF 0.95–1.0 are liquidated without grace. Not reachable at a pinned fork block. DR-11. |

---

## 3. Headline answers

### 3.1 Most likely insolvency scenario

A listed non-GHO stablecoin depegs fast and keeps falling. Sequence:

1. Hour 0: the token loses 10–30 %. USD band and TWAP checks mark the market Drifting: no new borrowing (correct).
2. The GSM for that token freezes (price band). Conversion moves to the backup DEX route. DEX depth for the failing token collapses as every holder sells; Chainlink lags the DEX price by more than 1 %.
3. Routed liquidations revert on `RecoveryBelowFloor` (floor = oracle value × 0.99 − 1 GHO). The permissionless path reverts the same way. The SettlementBudget covers only rounding (25 GHO per call).
4. Primary and alternate Chainlink routes diverge by more than `feedAgreementToleranceBps` (≈ 225 bps) during the slide; after 1 h the market is "treated as Expired" for liquidation (`EMG-005`).
5. Through the account-wide gate (`LIQ-006`, `INV-072`), every account that also holds $10 or more in this market cannot be liquidated in any market (DR-02).
6. Remedies need the timelock: `enableInKind` at 12 h, `setPriceSource` at 5 days, each cancellable by any one of four cancellers. In-kind at oracle prices above market attracts no keeper.
7. The token passes $0.08: every account opened at the maximum loan-to-value is insolvent (collateral < debt). Loss = debt of every account exposed to the token minus residual LP value.

Size: debt exposed to one token is bounded only by `0.2836 × (tokenUsdCap[t] + Σ slices)`. The reserve that covers it is 100,000 GHO. The cap-sizing rule `SPEC-CAP-007` does not bind: with `h0 = 0.95`, `CF = 0.312`, `LB = 1.05`, `λ = max(0, (1+g)(1+δ) − 0.95(1 − dLP)/0.3276)` is **0 for every LP drop `dLP` ≤ 65.5 %** (and every historic stable-pool drop is far below that), so the rule permits any debt cap. The 100,000 GHO reserve is 5 % of the 2,000,000 GHO credit line and is not linked to tail size.

Likelihood: low per token per year for USDC/USDT; higher for smaller stables a later listing may add. Impact: up to the full debt of the affected markets. This is the dominant insolvency path; nothing else in the design reaches lender loss without a key compromise.

### 3.2 Fastest way TVL could go to zero

- **Market path (hours, no key needed):** one pool token goes to ~0. A full-range position's value is `2·√(p0·p1)·L`, which goes to 0 with either price; arbitrage leaves the pool holding only the dead token. Every position in every market containing that token is worth ~0 within hours, faster than any timelock remedy. With liquidations reverting (3.1 steps 3–5), lenders absorb all debt in those markets.
- **Code path (5 days minimum):** a hostile or faulty AaveAdapter or PositionProxy beacon implementation (`ATTACK-122`, `ATTACK-123`), proposed by the 4-of-7 and not cancelled by any of four cancellers for 5 days. It can mint unbacked vault tokens to a proxy (bounded by Hub `addCap` headroom), borrow every debt reserve against every proxy up to each `drawCap` (2,000,000 GHO), and burn any holder's vault tokens. It cannot move an NFT to anyone but its depositor (LPVault immutable), so LP principal survives; lenders' GHO does not. A bug (not malice) passing review is the realistic version.

### 3.3 The one parameter change

**Set `tokenUsdCap[t]` for every non-GHO pool token to at most `firstLossReserveMinimum[GHO] × minOpeningHealthFactor / CF_LP = 100,000 × 1.10 / 0.312 = $352,564`** (or, holding the business caps fixed, raise `firstLossReserveMinimum[GHO]` to `0.2836 × max_t (tokenUsdCap[t] + Σ_{m∋t} topUpSliceUsd[m])`).

Reason: `tokenUsdCap` is the only parameter that bounds, across every market and Borrow Spoke, the collateral exposed to one token (each pledge charges full LP value to both tokens' counters, `SPEC-CAP-002`). Debt against that collateral is at most 28.36 % of it at opening. Tying it to the reserve makes the single-token default of §3.1, the dominant tail, fully covered. No other single value changes the tail: `poolRiskFactor` and `minOpeningHealthFactor` already put the default threshold at a 92 % token drop, so tightening them moves the threshold by a few percent while leaving the loss size unbounded. The registry today leaves `tokenUsdCap` "set per token in the listing payload" with no relation to the reserve.

---

## 4. Transition analysis (steps 1–3)

Step 1 enumerates every state-changing external function in `contracts/src` interfaces plus inherited OpenZeppelin functions (`upgradeToAndCall`, `grantRole`/`revokeRole`/`renounceRole`, timelock `schedule`/`execute`/`cancel`, ERC-20 `transfer`/`approve`). Step 2 states what can go wrong. Step 3 states what must be atomic. The last column answers question 10's "which invariants each function touches"; a function with none states why it exists. Views are excluded except where they write (`poke`) or gate.

Atomic groups (must be one transaction, all-or-nothing):

- **T-PLEDGE:** Adapter `pledge` → (proxy deploy) → `addValidProxy` → Collateralization `pledge` → RiskModule `checkPledge` → LPVault `receiveNft` → record write → `mint(P, credited)` → proxy `supplyCollateral` → supply and backing checks.
- **T-WITHDRAW:** Adapter `withdraw` → proxy `withdrawCollateral` → (post HF) → `burn(P)` → Collateralization `release` (reconcile first) → LPVault `returnNft` → backing check.
- **T-LIQ:** flash mint → (buy leg) → `beginSeizure` → Spoke `liquidationCall` → (sell-back) → `burnSeized` → `settleSeizure` → `removeLiquidity` → conversions → floor → waterfall → (budget draw) → flash repay → payout.
- **T-PENDING:** `settlePending` → `burnSeized` → Collateralization `settlePending` → `removeLiquidity` → conversions → floor → Coverage `fund`.
- **T-LIST:** one `scheduleBatch`: `deployVaultToken` + `registerMarket` + initial caps + `minPledgeUsd` + routes + thresholds (+ Spoke and GHO reserve on first listing).
- **Ordered, not atomic (cross-system):** Aave listing payload after T-LIST; `activateMarket` after the payload (re-checks); Coverage Spoke funded before `drawCap > 0`; Avana `tightenPoolRiskFactor` before an Aave CF cut is mirrored (see DR-05); keeper rotation `addKeeper` (5 d) before `removeKeeper` (12 h); route replacement `setRoute` before `disableRoute` of the old one.

| Contract.function | Caller | What can go wrong | Atomic group | Invariants touched |
|---|---|---|---|---|
| AaveAdapter.initialize | deployer, in proxy deploy tx | front-run if not in deploy tx (`REQ-ACCESS-150` requires same tx) | deploy | INV-018, INV-065 |
| AaveAdapter.pledge | wallet | price state, caps, `minPledgeUsd` evaluated on a just-poked oracle; Frozen allows indebted top-ups; NFT approval to LPVault can be front-run by owner transfer (reverts) | T-PLEDGE | INV-001, 005, 009, 011, 012, 026, 027, 028, 064, 066, 069 |
| AaveAdapter.borrow | wallet | stale or failed price in any market (account-wide gate); nonce/deadline; receiver rule; HF floors; drift not covering CF (DR-05) | single tx with proxy borrow and post-check | INV-019, 020, 023, 024, 025, 029, 060, 072 |
| AaveAdapter.repay | anyone | fee-on-transfer debt asset (USDT fee switch) makes proxy receive less than `x` → revert (DR-10); Aave reserve pause blocks; front-running a liquidation with dust repay changes Aave sizing | single tx | INV-043, 021 |
| AaveAdapter.withdraw | wallet | debt-free path must read no gate (`PROP-032`); with-debt path gates; reconcile-on-exit | T-WITHDRAW | INV-001, 006, 007, 008, 045, 058, 066 |
| AaveAdapter.repayAllAndWithdraw | wallet | one reserve repay failing (paused debt reserve) blocks the whole exit; lengths | T-REPAY + T-WITHDRAW | INV-043, 045, 072 |
| AaveAdapter.burnSeized | LPVaultSwap (lock held) | burning more than received; called outside T-LIQ/T-PENDING | T-LIQ, T-PENDING | INV-010, 014, 066 |
| AaveAdapter / ProxyManager / RiskModule / MarketRegistry / ParameterStore / LPOracle / LPVaultSwap `.upgradeToAndCall` | timelock, normal delay | hostile or faulty implementation; storage layout collision; initializer re-run | timelock op | INV-018, 052, 065 |
| `grantRole` / `revokeRole` on each upgradeable contract | timelock (role-change op) | a role granted to a non-timelock address; cancel only by `DAO_CANCELLER_ROLE` | timelock op | INV-047, 051, 068 |
| `renounceRole` (OZ) on each contract and timelock | role holder | governance multisig renounces `PROPOSER_ROLE` → no proposer ever (exits continue; no repair possible) | — | INV-051 (none checks proposer liveness) |
| PositionProxy.initialize | ProxyManager in deploy tx | none if CREATE2 + init in one tx | proxy deploy | INV-064 |
| PositionProxy.supplyCollateral | Adapter | collateral not enabled; residual balance | T-PLEDGE | INV-008, 021, 063 |
| PositionProxy.borrow | Adapter | delta measurement; receiver | borrow tx | INV-020, 063 |
| PositionProxy.repay | Adapter | refund of unconsumed asset; fee-on-transfer | repay tx | INV-021, 043 |
| PositionProxy.withdrawCollateral | Adapter | delta ≠ units; disable collateral with debt | T-WITHDRAW | INV-008, 013 |
| ProxyManager.deployProxy | Adapter | address squatting at predicted address (`ATTACK-134`), `ProxyExists` | T-PLEDGE | INV-064 |
| ProxyManager.setProxyImplementation | timelock, normal | changes every proxy at once (`ATTACK-123`) | timelock op | INV-016, 063, 065 |
| VaultToken.mint | Adapter | unbacked mint by hostile Adapter (bounded by Hub `addCap`) | T-PLEDGE | INV-001, 009, 066 |
| VaultToken.burn | Adapter | burn from Hub or victim (hostile Adapter, `ATTACK-124`) | T-WITHDRAW, T-LIQ, T-PENDING | INV-010, 014 |
| VaultToken.addValidProxy | Adapter | rogue registration (`ATTACK-125`); append-only | T-PLEDGE | INV-012 |
| VaultToken.transfer / transferFrom / approve | holders | recipient rule; LPVaultSwap supplying seized tokens as collateral (`ATTACK-137`) | — | INV-003, 011 |
| VaultTokenFactory.deployVaultToken | TIMELOCK | wrong immutables; second token per pool reverts | T-LIST | INV-017, 052 |
| LPVault.receiveNft | Collateralization | owner change between approval and pull | T-PLEDGE | INV-005, 007 |
| LPVault.returnNft | Collateralization | must go only to depositor of record | T-WITHDRAW | INV-007, 045 |
| LPVault.removeLiquidity | Collateralization | `amount0Min = amount1Min = 0` (`REQ-VAULT-149`): safe because unwind value at any spot ≥ oracle value (`SPEC-ORC-007`); fee-on-transfer pool token breaks `c0 = a0` (DR-10); pool `collect` reverting (`EMG-026`) | T-LIQ, T-PENDING, reconcile | INV-002, 014, 033 |
| LPVault.collectFees | depositor | never touches principal (`INV-033`, `REQ-VAULT-067`); open in every state | single tx | INV-033, 044 |
| LPVault.returnStrayNft | TIMELOCK, normal | only uncredited NFTs | timelock op | INV-007 |
| LPVault.onERC721Received | NFPM | stray NFTs uncredited | — | INV-005 (exists to accept `safeTransferFrom` pushes without loss) |
| Collateralization.pledge / release | Adapter | counters, largest-first order, reconcile | T-PLEDGE, T-WITHDRAW | INV-001, 006, 015, 027, 058 |
| Collateralization.beginSeizure / settleSeizure | LPVaultSwap | snapshot mismatch; debit > credit | T-LIQ | INV-014, 015 |
| Collateralization.settlePending | LPVaultSwap | supply equality before debit | T-PENDING | INV-001, 058 |
| Collateralization.releaseZeroCredit | depositor | none (credited = 0) | single tx | INV-007 (exists to return NFTs whose credit was fully seized) |
| RiskModule.initialize | deployer | as Adapter | deploy | INV-065 |
| RiskModule.preBorrowCheck / preWithdrawCheck | Adapter | pokes oracles (state write); faulty RiskModule approves below floors (bounded by Aave HF ≥ 1) | borrow / withdraw tx | INV-023, 024, 029, 060, 072 |
| RiskModule.checkPledge / postHealthCheck / checkAaveConfig | Collateralization / Adapter / MarketRegistry | views that gate; CF drift not checked (DR-05) | inside T-PLEDGE, borrow | INV-025, 026, 028, 069 |
| MarketRegistry.initialize | deployer | as Adapter | deploy | INV-065 |
| MarketRegistry.approveSpoke / approveDebtReserve / removeDebtReserve | timelock, normal | debt set ≠ Spoke bitmap (`DebtReserveSet` drift); removal with open debt reverts | timelock op | INV-073, 029 |
| MarketRegistry.listToken / setPriceSource | timelock, normal | wrong feed; `setPriceSource` is the only fix for persistent disagreement and takes 5 days (DR-03) | timelock op | INV-055, 056 |
| MarketRegistry.registerMarket | timelock, normal | listing checks on-chain subset | T-LIST | INV-017, 028 |
| MarketRegistry.activateMarket / cancelRegistration | timelock, short | activation must re-run every match check | timelock op | INV-029, 073 |
| MarketRegistry.setMarketOffboarding | timelock, short | irreversible; can offboard every market in one 12 h batch (no selector returns to Active) | timelock op | INV-024 |
| MarketRegistry.setRoute / setBuyRoute / setSellBackRoute | timelock, normal | hostile route; route through the market's own pool | timelock op | INV-034, 040, 070 |
| MarketRegistry.disableRoute / disableBuyRoute | timelock, short | disabling every route halts liquidation (`ATTACK-100`) | timelock op | INV-046 |
| MarketRegistry.restoreRoute / restoreBuyRoute | timelock, short | cancellable by any canceller | timelock op | INV-046 |
| MarketRegistry.enableInKind / disableInKind | timelock, short | 12 h delay during a crisis; cancellable | timelock op | INV-039, 046 |
| MarketRegistry.freeze / pause | guardian or timelock | guardian pauses indefinitely (accepted, `ATTACK-101`); timelock path is 5 days (DR-16) | immediate | INV-049, 050, 067 |
| MarketRegistry.unfreeze / unpause | pause guardian or timelock | ping-pong between guardians | immediate | INV-049, 050 |
| ParameterStore.initialize | deployer | as Adapter | deploy | INV-065 |
| ParameterStore.setInitialMarketParams / setInitialMarketCaps / setInitialTokenCap / setFeed / setBuySlippageAllowanceBps / setInKindExpiry | timelock, normal | values unrelated to reserve (DR-01); `cBuy` vs min bonus (DR-06) | T-LIST | INV-028, 047, 069, 070 |
| ParameterStore structural setters: setBorrowPriceMaxAge, setTwapToleranceTicks, setFeedAgreementToleranceBps, setPoolRiskFactor, setAvanaFeeShareBps, setFeeRecipient, setMaxFlashFeeBps, setCachedWindow, setDisagreementPauseMax, setTwapWindow, setUsdBand, setLiquidationPriceMaxAge, setFeedMaxAge, setGraceDuration, setGraceHealthFactor, setFeedAgreementMarginBps, setSlippageAllowanceMinBps, setTokenCollateralFactorBps, setStressFloorUsd | timelock, normal | no step limit; `setPoolRiskFactor` has no live effect after activation (DR-05); `setTwapWindow` beyond pool cardinality makes `observe()` fail → Drifting | timelock op | INV-031, 047, 055 |
| ParameterStore tighten* (16 setters) | timelock, short | no step limit: `tightenMinPledgeUsd` to $100,000 blocks rescue top-ups (DR-09) | timelock op | INV-047, PROP-042 |
| ParameterStore loosen* (11 setters) | timelock, normal | gradual drift by repeated 5-day loosenings (§5) | timelock op | INV-028, 047 |
| LPOracle.initialize | deployer in deploy tx | seed price must be Live | deploy | INV-055 |
| LPOracle.poke | anyone | gas-starved poke reverts the caller (≥ `pokeMinGas`); writes disagreement start and grace latch; timing of the first observation chosen by the first caller | inside borrow, pledge, liquidation, or alone | INV-031, 055, 056, 059 |
| LPOracle.setPokeMinGas | timelock, normal | too high blocks callers | timelock op | INV-055 |
| LPVaultSwap.initialize | deployer | keeper list ≥ floor | deploy | INV-048 |
| LPVaultSwap.liquidate | approved keeper | sandwich up to floor; budget draw ≤ U + 1 GHO; in-kind payout ≤ cap | T-LIQ | INV-030, 032, 034–039, 046, 062, 070 |
| LPVaultSwap.liquidatePermissionless | anyone | same; no budget, no in-kind | T-LIQ | INV-030, 032, 034, 035, 062 |
| LPVaultSwap.settlePending | anyone | MEV bait: caller's only reward is sandwich extraction up to 1 % + U + 1 GHO of `V_P` | T-PENDING | INV-058, PROP-051 |
| LPVaultSwap.onFlashLoan | FlashMinter | initiator and lock checks | T-LIQ | INV-040 |
| LPVaultSwap.addKeeper / removeKeeper | timelock, normal / short | below floor reverts | timelock op | INV-048 |
| SettlementRoute.convert, DebtBuyRoute.buyExactOut, `uniswapV3SwapCallback` | LPVaultSwap / pool | per-leg minimum 0 (DR-07); callback auth; fee-on-transfer `TransferMismatch` | T-LIQ, T-PENDING | INV-034, 040, 070 |
| SettlementBudget.draw | LPVaultSwap | caps per `(spoke, reserve)` shared by all markets | T-LIQ | INV-037, 038, 062 |
| SettlementBudget.topUp | anyone | none | — | none (exists to refill the rounding budget) |
| SettlementBudget.tightenCaps / loosenCaps / withdraw | TIMELOCK | withdraw empties the budget → dust liquidations revert | timelock op | INV-037 |
| PayoutEscrow.deposit / claim | LPVaultSwap / borrower | conservation | T-LIQ / single | INV-061 |
| Lock.acquire / release | four members | a member that never releases (revert path) — release in every exit path | every outer call | INV-054 |
| AvanaTimelock.schedule / scheduleBatch | proposer | delay ≥ `requiredDelay`; a batch with one loosening call is normal | — | INV-051, 068 |
| AvanaTimelock.execute / executeBatch | anyone (public) | executes within `GRACE_PERIOD`; anyone chooses timing (front-runs a market event) | — | INV-068 |
| AvanaTimelock.cancel | four cancellers | cancels repairs (DR-08) | — | INV-047, 068 |
| AvanaTimelock.setNormalDelay | self, normal | can be set to 12 h (bound `[SHORT_DELAY, MAX_DELAY]`), breaking the exit argument (DR-18) | self op | INV-051 |
| AvanaTimelock.setShortDelaySelector | self, normal | can put `upgradeToAndCall` on the 12 h list (DR-18) | self op | INV-051 |
| AvanaTimelock.togglePublicExecution | self, normal | off: only the multisig executes | self op | INV-068 |
| AvanaTimelock.cleanupExpiredOperation | anyone | none | — | none (exists to clear expired ids) |
| AvanaTimelock.updateDelay | — | reverts | — | none (disabled OZ function) |
| Coverage Spoke.fund / coverDeficit (Aave) | anyone / `COVERAGE_ROLE` | manual coverage within 72 h; one GHO instance for all markets | — | INV-041, 042, 071 |

---

## 5. Risk accumulation over time and parameter drift

How risk grows without any single event:

1. **Interest decay.** GHO borrow rate plus risk premium lowers every HF continuously. LP trading fees do not offset it: fees are collected separately (`collectFees`) and never count as collateral. A max-LTV account at 8 % APR reaches HF 1.0 from 1.10 in about 1.2 years with no price move.
2. **Clustering at the opening floor.** Rational borrowers draw to HF ≈ 1.10. The distribution of HF concentrates at the floor, so a small correlated move liquidates a large share of accounts at once (keeper throughput, GSM capacity, FlashMinter bucket, budget window).
3. **Pool liquidity migration.** Uniswap v3 liquidity moving to other pools or versions lowers depth and TWAP manipulation cost month by month. `poolShareMaxBps` is checked only at pledge; Avana's share can grow far above 10 % with no on-chain signal (DR-12).
4. **Shared external capacity consumed by others.** GSM exposure caps and FlashMinter capacity are shared with every GHO user. The listing assumed GSM headroom of $20M USDC / $24M USDT (`simulation/README.md:57`, "ASSUMED"). Capacity can fall below the market's stress liquidation size with no Avana change.
5. **Reserve erosion.** Small deficits (dust accounts not worth liquidating, bonus-funded loss of §1.4) are covered from the GHO Coverage Spoke. There is no automatic reaction to the reserve falling below 100,000 GHO (`Q-102`).
6. **Keeper reimbursement depletion.** Off-chain budget, sized at about $60k per 2M GHO at 20 gwei (`Q-185`); with `minPledgeUsd = $10` most small accounts are guaranteed losses for keepers (DR-14).

Parameter drift failure modes:

| Drift | Mechanism | Effect | Detection today |
|---|---|---|---|
| Caps creep | Repeated 5-day `loosen*` operations, each reviewed alone; no step limit, no cooldown | Debt exposure grows past what the reserve covers | None on-chain; `SPEC-CAP-007` binds nothing (λ = 0) |
| Aave CF raised after activation | AIP raises CF above `CF_LP` or makes `maxLB × CF ≥ 1` | Accounts open with less margin than Avana assumes; full seizure may not cover debt | Not in `DriftReason` (DR-05) |
| Core Hub token CF lowered | `tokenCollateralFactorBps` recorded at listing only | `CF_LP` stale-high | None |
| Chainlink feed parameters changed | Heartbeat or deviation threshold changed by Chainlink; `feedAgreementToleranceBps` lower bound stale | Spurious disagreement halts, or a tolerance looser than intended | Listing-time only |
| `buySlippageAllowanceBps` raised | Normal delay, up to 300 bps | `s = 0` at min bonus (DR-06) | None |
| `normalDelay` lowered | Self-call, bound 12 h | Exit window too short (DR-18) | Event only |
| Short-delay list extended | `setShortDelaySelector` | Upgrades at 12 h (DR-18) | Event only |
| Tolerances loosened | `twapToleranceTicks`, `feedAgreementToleranceBps` raised (normal) | Weaker manipulation checks | None |
| Liquidation bonus lowered by Aave | AIP changes bonus factor | Bonus below conversion cost; floors revert | Activation-time only (`REQ-CONFIG-045`) |

**One slow-burn bug that tests would not show:** Chainlink aggregator phase rollover. `SPEC-ORC-014` derives recovery evidence from `getRoundData(roundId − 1)`. Proxy round IDs are `(phaseId << 64) | aggregatorRoundId`; on the first round after Chainlink upgrades an aggregator, `roundId − 1` points to aggregator round 0 of the new phase, which does not exist, so the lookup reverts or returns `updatedAt = 0`. The spec treats this as "no evidence", so an outage that ended with or across an aggregator upgrade never opens the grace window: accounts at HF 0.95–1.0 are liquidated the moment the feed returns, at the post-outage price, while the grace design (`EMG-008`) promised them 30 minutes. Tests run on a fork at a pinned block (`TEST-003`) and Chainlink upgrades are rare (months apart), so no test reaches it; it surfaces only in production, during an outage. Fix in DR-11.

---

## 6. MEV

### 6.1 Liquidation conversion legs

- **minOut per leg: 0, by design.** `REQ-ROUTE-009`: "Every leg of a settlement or sell-back route MUST run with a zero per-leg minimum (`min_dy = 0`, extreme Uniswap price limit, GSM and PSM at their posted price)". `REQ-VAULT-149`: `decreaseLiquidity` with `amount0Min = amount1Min = 0`. `REQ-SWAP-025`: "no standalone spot-price check and no per-token minimum anywhere in the liquidation path". So the requirement "every swap's minOut derived from the oracle price and slippage tolerance, never 0" is **not met per swap**. It is met for the whole conversion as one aggregate check:
  - Recovery floor, `SPEC-LIQ-005` (2.11): `minGho = max(0, ⌈V × (10⁴ − s)/10⁴⌉ − U − floorRoundingAllowanceGho)`, with `V = mulDiv(c × Pc, 10¹⁸, 10^dv × Pgho)` at the price Aave used (`SPEC-LIQ-004`) and `s = min(slippageAllowanceBps, ⌊10⁴ × (bNet×10⁴ − (10⁴+costsBps)(10⁴+cBuy))/(bNet×10⁴)⌋)` (`SPEC-LIQ-016`). The call reverts `RecoveryBelowFloor` if `R < minGho`.
  - Pending-settlement floor, `SPEC-LIQ-014`: `minPending = max(0, ⌈V_P × (10⁴ − slippageAllowanceBps)/10⁴⌉ − U − floorRoundingAllowanceGho)`.
  - Buy leg, `SPEC-LIQ-015`: `maxGhoIn = min(maxGhoSpend, ⌈X × Pdebt × (10⁴ + cBuy)/(Pgho × 10⁴)⌉)` (decimals normalised); `GhoSpendTooHigh` otherwise. This is the only per-swap oracle-derived limit.
- **The floor saturates to 0.** For `V × (1 − s) ≤ U + 1 GHO` (oracle value below about 1.01 GHO) `minGho = 0`. Dust only; impact negligible.
- **Who pays a sandwich.** Floor ≥ `Gcov − U − 1 GHO` by construction (`(1+bNet)(1−s) ≥ (1+fee)(1+cBuy)`), so lenders are protected. A sandwich extracts up to `R_honest − minGho` ≈ `s × V` + rounding from the caller's payout and Avana's 20 % fee. Example: V = 2,047.5 GHO, s = 100 bps → up to 20.5 GHO per liquidation. An approved keeper that sandwiches its own liquidation (private bundle) converts Avana's 18.06 GHO fee (`SPEC-LIQ-009` example) into its own revenue and can push `R` 1 GHO below the floor gap the budget fills.
- **Unwind at a moved spot** is safe: holdings removed at any pool price are worth at least the oracle value (`SPEC-ORC-007`); a price push before the unwind transfers value to Avana, not from it.

### 6.2 Settlement of pending balances

`settlePending` is permissionless and pays the caller nothing (`REQ-SWAP-043`: proceeds to the Coverage Spoke, residue to `feeRecipient`). The only reason to call it is to sandwich it: up to 1 % of `V_P` + U + 1 GHO from the reserve per call. Pending balances arise only after an unsettled seizure (faulty LPVaultSwap), so volume is small. Recommendation in DR-07.

### 6.3 Buy leg (non-GHO debt)

Bounded per swap by `maxGhoIn` (above). A sandwich takes up to `cBuy` (≤ 300 bps) of the debt notional; `s` shrinks to keep the floor covering it, so the extraction comes out of the keeper's bonus margin, not the reserve. With `cBuy = 300` and min bonus 2 %, nothing is left (DR-06).

### 6.4 Keeper front-running

- Permissionless callers can front-run profitable keeper liquidations; keepers then keep only the loss-making ones, which the reimbursement budget pays (adverse selection, DR-13).
- A borrower can front-run its own liquidation with a dust repay or a top-up; Aave re-sizes; GHO-debt keepers lose only gas; non-GHO keepers pay the sell-back round trip (`SPEC-LIQ-017`). Lens returns `minPayout = 0` (`R-28`), so keepers that forward Lens values unchanged accept any payout.
- Mitigation for keepers: private order flow, `minPayout = expectedPayout × (1 − tolerance)`, deadline one block.

### 6.5 Toxic order flow against LP collateral

The custodied positions are ordinary full-range liquidity in the public pool. Informed traders arbitrage them during a depeg exactly as they do any LP; the loss shows up as LP value decline, which the oracle prices correctly (fair value at Chainlink prices). Avana adds no extra exposure except the concentration in §2.2.A. Oracle-based valuation cannot be inflated by pool trades (`SPEC-ORC-007`). Pool-spot TWAP manipulation can only cause Drifting (borrow DoS).

---

## 7. Token handling

| Case | Spec position | Assessment |
|---|---|---|
| Fee-on-transfer | Excluded by listing (`REQ-CONFIG-018`); USDT accepted with "a check that USDT's fee rate is 0" at listing | USDT's `basisPointsRate` can be switched on by Tether at any time. Then: `removeLiquidity` principal-capped collect expects `c0 = a0` (`SPEC-BACK-008`), routes check `TransferMismatch`, Adapter repay pulls `x` but the proxy holds `x(1−fee)`. Result: every liquidation of every USDT market and every repay of a USDT debt reverts. DR-10. |
| No return value (USDT `transfer`) | OZ `SafeERC20` pinned (4.3 line 227) | Fine if every ERC-20 call uses `SafeERC20` (including inside routes); the in-kind remainder delivery explicitly accepts empty return data (`REQ-SWAP-076`). Add a test (§11). |
| Token that fails a zero-amount transfer | `INV-021` (no zero-amount transfers), `TEST-177` | Covered. |
| Blocklists (USDC, USDT) | Accepted named exception with monitoring (EXT-017) | If the issuer blocklists LPVaultSwap, `collect` to LPVaultSwap reverts: liquidation of every USDC market halts. LPVaultSwap's address is immutable in the Spoke (`LIQUIDATION_MANAGER`) and every vault token; a UUPS upgrade keeps the address. Recovery needs a new Spoke and new vault tokens (migration). Blocklisting a borrower's wallet: in-kind remainders go to escrow (covered); NFT return is ERC-721 (unaffected). |
| Issuer pause (USDC `pause`) | Not addressed | All transfers revert: liquidations of USDC markets halt; USDC debt repay halts. Should trip a breaker for new activity (§9). |
| Decimals 6–18 | Vault decimals `d = (d0+d1)/2`, 6 ≤ d ≤ 18 (`SPEC-ORC-005`); debt decimals 6 and 18 in `SPEC-LIQ-015` | Covered by math rules and `TEST-071/072/075/198`. |
| Rebasing (stETH-style, aUSDC) | Excluded by listing | Correct to exclude; a rebasing pool token would break `c0 = a0` and backing. |
| Upgradeable tokens | USDC, USDT, GHO, WETH monitored (TB-028) | Monitoring only. |
| Reentrancy in NFPM `collect` / `decreaseLiquidity` | NFPM transfers pool tokens from the pool to the recipient; global Lock held (`INV-054`); `collectFees` and `removeLiquidity` both run under the lock, so fees cannot absorb principal (`REQ-VAULT-067`) | Safe for standard ERC-20. A token with transfer hooks (ERC-777) could reenter a non-Avana contract; Avana entry points revert `LockHeld`. NFT return uses `transferFrom`, not `safeTransferFrom` (`REQ-VAULT-147/148`), so no receiver hook runs. Read-only reentrancy: no Avana view is consumed by third parties mid-call except LPOracle, whose price does not depend on Avana state. |

---

## 8. OpSec, key management and the risk-parameter process

### 8.1 What the spec has and lacks

Has: 4-of-7 governance Safe (sole proposer, canceller), 3-of-5 Emergency Guardian (pause, freeze, unpause, unfreeze, cancel), disjoint signer sets (`REQ-ACCESS-104`), alerts on Safe owner/threshold changes, quarterly guardian fork rehearsals (`REQ-ROLE-077`), keeper keys in HSM/KMS with add-before-remove rotation (`REQ-ROLE-082`), compromise response "cancel, pause, revoke by role-change op" (`REQ-ROLE-086`).

Lacks: hardware-signer requirement, signer distribution, signing procedure, rotation cadence, quorum-health checks for the governance Safe, response-time targets, Safe guard or module policy. Safe owner and threshold changes are instant and outside the timelock (1.5). The governance Safe is the only proposer, so a lost or compromised quorum cannot be replaced through Avana (`REQ-ACCESS-107`).

### 8.2 Required controls

1. **Hardware signers.** Every Safe signer key on a dedicated hardware wallet with on-device EIP-712 display; no hot keys, no browser-extension keys, no shared devices. Keepers: HSM/KMS per operator (already required).
2. **Distribution.** Governance 4-of-7: at most 3 Avana Labs signers, so Avana Labs alone cannot reach quorum; at least 3 independent organizations; at least 3 jurisdictions. Emergency Guardian 3-of-5: 5 different people, ≥ 3 time zones so a quorum is reachable 24/7; no person holds seats in two Safes (already required).
3. **Signing procedure.** Every signer independently: (a) decodes calldata from the raw transaction, not from the proposer's description; (b) recomputes the Safe transaction hash and compares it with the device; (c) runs a fork simulation of the operation (timelock `schedule` and, for the executing step, the resulting state diff); (d) checks `requiredDelay` matches the intended class. Two signers verify the target address list against the deployment manifest.
4. **Quorum health.** Monthly signed liveness message from every signer of both Safes; alert if fewer than threshold + 1 respond within 72 h. Quarterly drills: guardian pause/unpause on a fork (exists) and a governance `schedule`/`cancel` drill (missing).
5. **Rotation.** Replace a signer within 72 h of departure or suspected compromise; full key rotation every 24 months. Safe owner changes announced in advance.
6. **Safe guard.** Install a Safe guard on the governance Safe that only allows calls to the AvanaTimelock and to the Safe itself, and makes owner/threshold changes wait 48 h (a delay module). Without it, 4 compromised signers can replace the other 3 instantly.
7. **Backup proposer.** Grant `PROPOSER_ROLE` also to the Aave governance executor (normal-delay role change), so the DAO can replace a lost governance quorum (DR-17).
8. **Compromised-signer playbook.**
   - One signer suspected: remaining signers swap the owner (Safe tx); no Avana action needed below threshold.
   - Governance quorum compromised: Emergency Guardian or Aave Protocol Guardian cancels every queued operation it did not expect (cancel window = whole delay); guardian pauses if a malicious operation is near its ready time; Aave executor (backup proposer) schedules revocation of the compromised Safe's roles (normal delay; only `DAO_CANCELLER_ROLE` can cancel role changes).
   - Emergency Guardian compromised: worst case is indefinite pause (exits and liquidation stay open per U1) and cancellation of repairs (DR-08); Aave Protocol Guardian unpauses; governance schedules revocation (5 days).
   - Keeper key compromised: `removeKeeper` at 12 h; damage bounded by Aave eligibility, floor and 25 GHO per call.

### 8.3 Governance process for a risk parameter change

Avana-side parameters (ParameterStore, SettlementBudget, MarketRegistry):

1. Risk service providers publish the change with the `SPEC-CAP-007` sizing and (after DR-01) the tail test.
2. Governance Safe builds the batch; each signer runs §8.2 step 3.
3. `schedule`/`scheduleBatch` with `delay ≥ requiredDelay`: **12 h** if every call is a tightening on the short list (raise `minOpeningHealthFactor`, lower caps, raise `minPledgeUsd`, lower slippage), otherwise **5 days**. One loosening call makes the whole batch 5 days.
4. Monitoring alerts on `CallScheduled`; any of the four cancellers may cancel during the whole delay.
5. From ready time to ready + **14 days**, anyone executes (public execution). The tighten predicate (`NotStricter`, `OutOfBounds`, `LivenessBound`) is evaluated at execution; a failing call reverts the batch.
6. Post-execution: live-config check; Lens cap headroom.

Example: `minOpeningHealthFactor` 1.10 → 1.15: tighten, 12 h. 1.10 → 1.05: loosen, 5 days.

Aave-side parameters (collateral factor, liquidation bonus curve, target HF, Hub `addCap`, `drawCap`, credit line, reserve minimum): Aave governance (forum proposal, Snapshot, on-chain AIP vote, payload execution delay). There is no separate "liquidation threshold" in Aave V4; the CF and the bonus curve play that role.

Ordering for a CF cut (must be followed because the two sides are not atomic): (1) Avana `tightenPoolRiskFactor` at 12 h so `expectedCollateralFactorBps` reflects the target; (2) with DR-05 in place, borrowing against the market stops automatically while Aave's CF exceeds the new `CF_LP`; (3) Aave AIP lowers CF on every dynamic key; (4) borrowing resumes. For a CF raise the order reverses: Aave first is blocked by drift, so Avana `setPoolRiskFactor` (5 days) executes first.

Missing today: no step limit on any change. Add (DR-09): per operation, loosening of `minOpeningHealthFactor` ≤ 0.03, of any USD cap ≤ ×1.5, of `slippageAllowanceBps`/`buySlippageAllowanceBps` ≤ +25 bps; at most one loosening per parameter per `normalDelay`.

---

## 9. Circuit breakers, monitoring and alerting

### 9.1 What trips automatically today

Per-market, per-read gates in LPOracle and RiskModule: Drifting (TWAP > 50 ticks, USD band 0.90–1.02, `observe()` failure, disagreement), Cached/Expired (both routes stale), grace (HF < 0.95 for 30 min after recovery), stale debt price, Aave config drift, Hub shares ≠ assets, no usable route, zero keepers (`EMG-047`). These block borrow (and some block liquidation). There is **no application-level automatic breaker**; `Q-102` and `REQ-FLR-014` explicitly reject one. There is **no per-address freeze** (`EMG-045`, `REQ-ACCESS-078`). Both user decisions U2 and U4 are therefore absent from the spec (DR-04).

### 9.2 Breakers to add (new activity only; never repay, debt-free withdraw, fee collection or liquidation)

Each is evaluated inside `RiskModule.preBorrowCheck`/`checkPledge` from on-chain state, resets when the condition clears, and emits an event when first observed.

| ID | Trigger (on-chain) | Blocks | Why it is hard to grief |
|---|---|---|---|
| CB-1 | Coverage Spoke of debt asset `a`: `isBelowMinimum()` (funded < 100,000 GHO) | borrow of `a` | Lowering the reserve needs a real deficit |
| CB-2 | Hub `getSpokeDeficitRay(asset a, spoke) > 0` | borrow of `a` on that Spoke | Needs a real deficit |
| CB-3 | SettlementBudget GHO balance < `per24hCap` (500 GHO) | borrow of GHO | Draws need real liquidations |
| CB-4 | Live pool share `(vaultToken.totalSupply × 10⁴) > 2 × poolShareMaxBps × liqHM` | pledge and borrow against market `m` | Raising Avana's share needs others' liquidity to leave or a pledge that the pledge test already caps |
| CB-5 | Collateralization hourly checkpoint: credited units of `m` seized in the last 3,600 s > 20 % of credited units at the window start | borrow against `m` for 6 h | An attacker can self-liquidate to trip it (cost: 5 % bonus + 20 % fee on its own collateral); effect is only a 6 h borrow stop, acceptable |
| CB-6 | Aave CF of the vault reserve > `CF_LP`, or `maxLB × CF ≥ 10⁴`, or target HF changed (DR-05) | pledge and borrow | Aave governance only |
| CB-7 | Debt or pool token reports `paused()` (USDC, USDT) or USDT `basisPointsRate() > 0` | pledge, borrow in markets and debt reserves using that token | Issuer only |
| CB-8 | Caught primary-route failures (`RouteFailed`) for market `m`: ≥ 3 within 3,600 s (state counter in LPVaultSwap; full reverts cannot be counted on-chain) | borrow against `m` for 6 h | Needs real route failures |

### 9.3 Address freeze (U4), recommended rules

- `MarketRegistry.freezeAccount(wallet)`: `APPLICATION_FREEZE_GUARDIAN` (Emergency Guardian, Aave Protocol Guardian), immediate. `unfreezeAccount(wallet)`: `APPLICATION_ADMIN` through the timelock at the short delay (12 h).
- Blocks for that wallet and every proxy with `walletOf(proxy) == wallet`: new-account pledge, top-up (**Assumption**: top-ups count as new activity; see DR-04 for the cost), borrow, withdraw-with-debt, use as `receiver`, use as caller of `liquidate`/`liquidatePermissionless`.
- Never blocks: its own `repay` and third parties' repay of its debt, debt-free withdraw (U1), `collectFees` (the immutable LPVault cannot read it anyway), `releaseZeroCredit`, liquidation of its positions, `PayoutEscrow.claim`.
- Limits: at most 20 freezes per rolling 24 h per guardian (bounds a compromised guardian); `AccountFrozen`/`AccountUnfrozen` events; alert on every freeze.
- Known weakness: a frozen actor uses a new wallet. The freeze is useful against a known exploit contract mid-incident, not as a sanctions tool.

### 9.4 Monitoring and alert thresholds

| Signal | Warn | Page | Responder |
|---|---|---|---|
| Account HF < 1 not liquidated | 5 blocks | 25 blocks; 300 blocks → Emergency Guardian decision | standby keeper, then guardians |
| `RecoveryBelowFloor` / `NoRouteAvailable` / `NoBuyRouteAvailable` reverts in mempool or simulations | 1 per market per hour | 3 per market per hour | governance (route change, in-kind) |
| LPOracle Cached | on entry | Expired (60 min) | operators; governance (`setPriceSource`) |
| Disagreement start | on entry | 30 min before `disagreementPauseMax` ends | operators |
| Any Chainlink leg age | > 50 % of `feedMaxAge` | > 90 % | operators |
| Debt feed age | > `borrowPriceMaxAge` | > 90 % of `liquidationPriceMaxAge` | operators, Aave |
| USD band distance | √(q0q1) < 0.95 | < 0.90 (trips Drifting) | guardians |
| Collateral TVL (oracle value) per market | −10 % in 1 h | −25 % in 1 h | guardians |
| Coverage Spoke funded | < 150,000 GHO | < 100,000 GHO | Avana Labs top-up; CB-1 trips |
| Hub deficit | any | uncovered after 24 h (window 72 h) | `COVERAGE_ROLE` |
| SettlementBudget | `remainingToday < 100` GHO or balance < 1,000 GHO | balance < 500 GHO | Avana Labs top-up |
| Keeper reimbursement budget | < 50 % | < 25 % | Avana Labs |
| `drawn / drawCap` | 80 % | 90 % | risk providers |
| Avana pool share (live) | > 15 % | > 20 % | risk providers; CB-4 trips at 20 % |
| Measured route depth vs `routeDepthThresholdGho` (daily fork simulation at stress size) | < 120 % | < 100 % | governance `disableRoute`/offboarding |
| GSM exposure headroom per token | < 2× market stress size | < 1× | risk providers |
| Aave config (CF, bonus, target HF, caps) vs recorded | any change | — | Emergency Guardian |
| Timelock `CallScheduled` | every | role change, upgrade, `setShortDelaySelector`, `setNormalDelay` | all cancellers |
| Safe owner/threshold change | every | every | all |
| Pause/freeze state change, address freeze | every | — | all |
| `CounterSaturated`, `BackingMismatch` simulation failure | — | every | engineering |

---

## 10. Test coverage critique

Status: every Foundry test is "Not written" (`01-test-requirements.md:5`); every PROP is "Not run" (`02-formal-properties.md:106`). Spec-stage models (Z3, SymPy, Quint, Hypothesis, simulation) ran, but Quint and Hypothesis predate `Q-223`…`Q-240` and model GHO-only debt and the removed incident/quarantine/Recovery machinery (`02-formal-properties.md:62`, `quint/README.md:113-159`). The new pause model's evidence therefore rests on a model that does not match `Q-227`.

1. **Untested economic invariant.** System solvency per debt asset (§1.1). No INV, PROP or TEST states it; `TEST-127` is one scenario. Next: realizable ≥ floor at stress size (§1.2), deficit monotonicity across a liquidation (§1.4), no-contagion (§1.5).
2. **Attack that bypasses existing tests.** The account-wide liquidation shield (DR-02). The tests assert that liquidation reverts when any market or debt feed of the account is stale (`TEST-104`, `TEST-105`, `PROP-022`); they would pass while confirming the shield. The multi-actor handler set (`TEST-082`) has no actor who chooses which markets to hold to exploit the gate, no actor that moves pool spot or sandwiches routes, and no lender actor.
3. **Assumption that could fail in production.**
   - Route depth and GSM headroom: "listed pools meet the depth from the manipulation-cost study" (4.3:79), GSM headroom "ASSUMED" (`simulation/README.md:57`), HYP models "GSM 1:1 and DEX at Chainlink minus 0.3 %" (FP:83), SIM-06 "real route depth and MEV not modelled" (FP:100). In a depeg, the GSM freezes and DEX output is well below Chainlink: every conclusion about liquidation liveness depends on this.
   - Keepers "act every step when up" (SIM-04, FP:98).
   - FlashMinter fee 0 and 2M GHO capacity.
   - Chainlink round IDs contiguous within a phase (DR-11).
   - USDT fee rate stays 0 (DR-10).
4. **Inconsistency to resolve.** `TEST-073` says an unwind is never worth more than the oracle value; `TEST-116` says it returns at least the oracle value at a moved spot. `SPEC-ORC-007` supports `TEST-116` (unwind value at oracle prices ≥ oracle value). `TEST-073` should state "at the oracle ratio, at most the oracle value plus one unit per leg".
5. **Per-function invariants.** See the last column of §4. Functions that touch no invariant and why they exist: `SettlementBudget.topUp` (refill), `AvanaTimelock.cleanupExpiredOperation` (housekeeping), `AvanaTimelock.updateDelay` (disabled inherited function), `LPVault.onERC721Received` (accept pushed NFTs without crediting them). `renounceRole` touches no stated invariant but can destroy governance liveness; it needs one (DR-17).

---

## Findings

Severity = impact × likelihood. Critical: loss of lender or borrower funds likely. High: large loss or long liquidation stop under plausible conditions. Medium: bounded loss or loss needing an unusual condition. Low: small loss or liveness cost. Info: consistency.

### DR-01 — High — Reserve sizing does not bind; no solvency invariant; single-token default uncovered

- Rules: `SPEC-CAP-007`, `Q-186`, `Q-192`, `INV-057`, 1.5 `tokenUsdCap`, `firstLossReserveMinimum`.
- Scenario: `λ = max(0, (1+g)(1+δ) − h0(1−dLP)/(CF·LB))` with h0 0.95, CF 0.312, LB 1.05, g ≈ 0.00055 (48 h at 10 % APR), δ = 0: λ = 0 for every dLP ≤ 65.5 % (λ = 0.13 at dLP = 70 %). Stable pools' worst historic 48 h drops are below 10 %, so the rule allows any debt cap. A token going to $0.08 makes every max-LTV account in every market with that token insolvent. With `tokenUsdCap = $3,000,000`, exposed debt ≈ 0.2836 × 3,000,000 = $850,800 against a 100,000 GHO reserve: ≈ $750,000 lender loss.
- Change: add `INV-074` (solvency per debt asset, §1.1). Add to `SPEC-CAP-007` a tail requirement for every non-GHO token t and debt asset a: `(tokenUsdCap[t] + Σ_{m∋t} topUpSliceUsd[m]) × CF_LP / minOpeningHealthFactor ≤ firstLossReserveMinimum[a]` (at launch values the factor is 0.2836), enforced on-chain by `loosenTokenUsdCap` and `setInitialTokenCap` (read the Coverage Spoke minimum) and checked by a Z3 model. At launch values: `tokenUsdCap ≤ $352,564` less slices.

### DR-02 — High — Account-wide liquidation gate creates cross-market contagion and a cheap shield

- Rules: `LIQ-006`, `LIQ-013`, `REQ-SWAP-008`, `INV-030`, `INV-072`, `EMG-005`–`007`, `EMG-020`, `minPledgeUsd` ($10).
- Scenario: a borrower with $1,000,000 of collateral in market A also pledges $10 in market B (or borrows 1 wei of a debt reserve whose feed has a 24 h heartbeat). When B is Cached, Expired or in a disagreement pause, or the debt feed is older than `liquidationPriceMaxAge`, every liquidation of the account reverts `StalePrice`/`DebtPriceStale`, including liquidation of market A, which is healthy and fresh. In a systemic event (B fails), every account holding any B position is unliquidatable everywhere. Cost of the shield: $10 plus gas.
- Change: rewrite `LIQ-006`/`REQ-SWAP-008`/`INV-072` (liquidation part): liquidation requires the freshness, state and disagreement gates only for the seized collateral market and the repaid debt reserve. Other reserves of the account contribute at their served price (Aave already uses it for HF). Keep the account-wide gate for borrow and withdraw-with-debt (new activity, fail closed). Add `INV-075` (no contagion, §1.5). Add a Z3 check that a stale other market's served price can only overstate HF by at most its listing error bound (stable ceiling, band), so the change cannot cause wrongful liquidation beyond that bound.

### DR-03 — High — Persistent disagreement and Expired halt liquidation for at least 5 days, beyond the 48 h sizing window

- Rules: `EMG-005`, `EMG-007`, `EMG-036`, `EMG-041`, `SPEC-ORC-016`, `Q-192`, `Q-208`, `setPriceSource` (normal).
- Scenario: during a depeg the alternate route lags; disagreement > 225 bps lasts > 3,600 s; the market is "treated as Expired for liquidation" until the routes agree or `setPriceSource` executes (5 days, cancellable by any one canceller). Caps assume liquidation stops ≤ 48 h. A 40 % further fall over those 5 days on a falling token turns liquidatable accounts into deficits.
- Change: after `disagreementPauseMax`, serve for liquidation the lower of the two routes for each collateral leg (and the higher for a debt feed) instead of halting; borrow stays blocked. Make switching to a pre-approved standby route (listed at registration) a short-delay operation `useStandbyPriceSource`. Rewrite `EMG-041` to state the real maximum stop of each halting state, or size caps for it.

### DR-04 — High — The user's automatic breakers and address freeze are not in the spec

- Rules: `Q-102`, `REQ-FLR-014`, `EMG-028`, `EMG-045`, `REQ-ACCESS-078`, U2, U4.
- Scenario: the reserve falls to 40,000 GHO after a deficit; borrowing continues until a human acts (`Q-102` rejects automation). An exploiter contract keeps opening positions mid-incident; the only tool is an application-wide pause.
- Change: replace `Q-102`'s "no automatic borrow block" with breakers CB-1…CB-8 (§9.2) as RiskModule checks with new error and `DriftReason`-style reasons; add the address freeze (§9.3) to the MarketRegistry pause piece with `freezeAccount`/`unfreezeAccount`, rules REQ-MREG for blocked and never-blocked paths, and invariants "a frozen wallet's repay, debt-free withdraw, fee collection and liquidation of its positions behave exactly as for an unfrozen wallet". Decide explicitly whether top-ups are blocked; blocking them lets a compromised guardian force liquidations (cost to borrower ≤ 5 % bonus), allowing them lets a frozen exploiter add collateral it controls.

### DR-05 — Medium — Aave collateral factor, bonus curve and target HF are not drift-checked after activation

- Rules: `SPEC-CF-001`, `SPEC-CF-002`, `SPEC-HUB-005`, `REQ-CONFIG-044`/`045`, `DriftReason` enum, `EMG-053`.
- Scenario: an AIP raises the reserve CF from 3,120 to 6,000 bps. Max opening LTV becomes 54.5 %; `maxLB × CF = 0.63` still < 1, but the liquidation margin Avana's caps, listing margin (`SPEC-CF-004`) and sizing assume is gone. Avana keeps opening loans. Separately, `tightenPoolRiskFactor` changes nothing live.
- Change: append `DriftReason.CollateralFactorAboveExpected`, `BonusBoundViolated`, `LiquidationConfigChanged`; `preBorrowCheck` and `checkPledge` revert `ConfigDrift` when any dynamic key's CF > `expectedCollateralFactorBps(m)`, when `⌈maxLB × CF / 10⁴⌉ ≥ 10⁴`, or when min bonus < `minLiquidationBonus` or target HF ≠ `aaveTargetHealthFactor`. Liquidation is unaffected.

### DR-06 — Medium — Two-leg slippage can be 0 at the minimum bonus; non-GHO liquidations near HF 1 revert

- Rules: `SPEC-LIQ-016`, `REQ-PSTORE-006`, `MKT-011`, `REQ-CONFIG-045`, 1.5 `buySlippageAllowanceBps` [1, 300], `minLiquidationBonus` ≥ 200.
- Scenario: `bNet = 10,200`, `cBuy = 200`: `102,000,000 − 100,000,000 × 1.02 = 0` → `s = 0`; any conversion loss reverts `RecoveryBelowFloor`. With `cBuy = 300` the term is negative → `s = 0`. Accounts at HF 0.97–1.0 holding that debt cannot be liquidated until HF falls to where the bonus grows.
- Change: on-chain check in `setBuySlippageAllowanceBps`, `approveDebtReserve` and `activateMarket`: for every market on the Spoke, `⌊10⁴ × (minLB×10⁴ − (10⁴+maxFlashFeeBps)(10⁴+cBuy)) / (minLB×10⁴)⌋ ≥ slippageAllowanceMinBps[m]`; revert otherwise. Z3 model in `z3/settlement/`.

### DR-07 — Medium — Every swap leg runs with minOut = 0

- Rules: `REQ-ROUTE-009`, `REQ-SWAP-025`, `REQ-VAULT-149`, `SPEC-LIQ-005`, `SPEC-LIQ-014`.
- Scenario: the aggregate floor protects lenders, but each leg is open to full sandwiching down to the aggregate floor. Extraction per liquidation ≈ `s × V` + 1 GHO (20.5 GHO on V = 2,047.5). On `settlePending` the extraction comes from the Coverage Spoke and is the only incentive to call it. A self-sandwiching keeper captures Avana's 20 % fee.
- Change: keep `decreaseLiquidity` minimums at 0 (safe by `SPEC-ORC-007`). For every conversion leg set `minOut_leg = ⌈valueGho(amountIn at the leg's oracle price) × (10⁴ − s)/10⁴⌉ − U_leg` (same `s` and `U` as the floor), passed by LPVaultSwap into `convert`; keep the aggregate floor. For `settlePending` use `s_pending = min(slippageAllowanceBps, 30)` and restrict callers to approved keepers or add a caller reward of 0.1 % of `V_P` so honest settlement is not left to searchers. Rewrite `REQ-ROUTE-009` accordingly.

### DR-08 — Medium — Any single canceller can cancel every liquidation repair

- Rules: `REQ-ACCESS-020`, `SPEC-GOV-005`, `EMG-057`, `ATTACK-097`.
- Scenario: Emergency Guardian Safe compromised (3 keys). During an Expired market it cancels `setPriceSource`, `enableInKind` and `restoreRoute` each time they are scheduled. Removal of its role takes a 5-day role-change op. Liquidation stays halted ≥ 5 days.
- Change: classify `setPriceSource`, `useStandbyPriceSource` (DR-03), `enableInKind`, `restoreRoute`, `restoreBuyRoute`, `addKeeper` as "liquidation-restoring"; cancel of such an operation requires `DAO_CANCELLER_ROLE` or two distinct cancellers. Correct `ATTACK-097`.

### DR-09 — Medium — Tightening has no step limit and `minPledgeUsd` applies to rescue top-ups

- Rules: `SPEC-GOV-011`, `REQ-PSTORE-005`, `SPEC-CAP-001`, R-24, `REQ-CONFIG-049`.
- Scenario: one 12 h operation raises `minPledgeUsd` to $100,000. An indebted borrower at HF 1.02 cannot top up with a $20,000 NFT and is liquidated at 2–5 % bonus. Same for repeated cap tightening. Loosening has no step limit either (drift, §5).
- Change: exempt slice-eligible top-ups (`SPEC-CAP-003`) from `minPledgeUsd`. Add per-operation step limits (§8.3) and one loosening per parameter per `normalDelay`, enforced in the ParameterStore.

### DR-10 — Medium — USDT fee switch, issuer pause or blocklist halts liquidation of every affected market

- Rules: `REQ-CONFIG-018`, `SPEC-BACK-008`, `REQ-ROUTE` `TransferMismatch`, EXT-017, `ATTACK-058/059`.
- Scenario: Tether sets `basisPointsRate > 0`. `c0 = a0` fails, routes revert, Adapter repays of USDT debt revert. Every USDT market's liquidation halts. Blocklisting LPVaultSwap by USDC halts every USDC market permanently (address immutable in the Spoke and vault tokens).
- Change: measure every received pool-token and debt-asset amount by balance delta (collect, route input, proxy repay) and size subsequent steps from the delta; add CB-7; add a migration runbook for an issuer action against LPVaultSwap; add token edge-case tests (§11).

### DR-11 — Medium — Chainlink phase rollover disables the grace latch

- Rules: `SPEC-ORC-014`, `EMG-008`, `EMG-034`.
- Scenario: §5. Accounts with HF 0.95–1.0 liquidated without the 30-minute grace after an outage that ended on a new aggregator phase.
- Change: when `uint64(roundId) == 1` (first round of a phase), read the last round of the previous phase through `phaseAggregators(phaseId − 1)` or treat the lookup as evidence of a gap ≥ `cachedWindow` (apply grace). Add a fork test at a real phase change block.

### DR-12 — Medium — Pool share is tested only at pledge

- Rules: `SPEC-CAP-005`, `poolShareMaxBps`.
- Scenario: 80 % of other LP liquidity leaves; Avana's share goes from 10 % to 35.7 %; TWAP manipulation cost and backup-route depth fall 5×.
- Change: CB-4 (live share > 2 × `poolShareMaxBps` blocks new pledges and borrows); monitoring at 15 %/20 %; forbid a market's backup DEX route from routing through the market's own pool (`Q-187` amendment).

### DR-13 — Low — Keeper adverse selection drains reimbursement

- Rules: `Q-185`, `Q-213`, `REQ-ROLE-084`.
- Scenario: permissionless searchers take every liquidation with positive payout; approved keepers keep the loss-making ones; reimbursement (sized from simulations where keepers did all liquidations) depletes early in a stress event.
- Change: size `keeperReimbursementBudget` assuming keepers get only negative-payout liquidations; alert at 50 %/25 %; keepers use private order flow.

### DR-14 — Low — `minPledgeUsd = $10` makes small accounts guaranteed keeper losses and cheapens DR-02

- Rules: R-24 (user override), `Q-215`, `Q-230`.
- Scenario: $10 collateral → max debt $2.84; min bonus 2 % pays $0.06; liquidation gas ≈ 0.6–1.0 M gas = $40–$300 at 20–100 gwei. Every such account is a reimbursement cost or, unliquidated, eventual dust deficit.
- Change: decision for the user, not a design flaw. Either keep $10 and size the reimbursement budget per account count, or raise to ≥ $1,000 (the earlier `Q-230` value). If DR-02 is not adopted, add `minPledgeUsd` per additional market ≥ $1,000.

### DR-15 — Medium — Liquidation below collateral = debt × LB pays the bonus from the reserve

- Rules: `INV-032`, `INV-041`, `MATH-AR-11b`, `SYM-13a`.
- Scenario: account with C = $10,000, D = 9,800 GHO: full seizure repays 9,524 GHO; deficit grows from $0 (C ≥ D) to 276 GHO, all of it bonus.
- Change: state §1.4 as `INV-076`; include `C × (1 − 1/LB)` per insolvent account in reserve sizing. Keeper speed does not remove this term: accounts fall below `LB × CF_LP` (HF 0.3276) only in a crash, when liquidation is slowest.

### DR-16 — Low — The governance Safe's own pause path takes 5 days

- Rules: `REQ-ACCESS-062/063`, `REQ-ACCESS-128`, R-13.
- Scenario: both guardians unavailable; the governance Safe "can still freeze, pause or tighten through the timelock" (`REQ-ACCESS-128`), but `pause`/`freeze` via `APPLICATION_ADMIN` are normal delay.
- Change: add `freeze`, `pause`, `freezeAccount` to the short-delay list (they block new activity only); correct `REQ-ACCESS-128`.

### DR-17 — Medium — The governance Safe is the only proposer and cannot be replaced without its own cooperation

- Rules: `REQ-ACCESS-004`, `REQ-ACCESS-107`, `REQ-ROLE-086`, OZ `renounceRole`.
- Scenario: 4 of 7 keys lost, or the Safe renounces `PROPOSER_ROLE` by mistake: no upgrade, price-source fix, route restore or in-kind ever again. Safe owner changes are instant, so 4 compromised keys can lock out the other 3.
- Change: grant `PROPOSER_ROLE` to the Aave governance executor as backup; add a Safe guard and owner-change delay (§8.2 step 6); invariant "`PROPOSER_ROLE` has ≥ 2 holders" in the live-config check.

### DR-18 — Medium — The exit-safety window can be shrunk by normal-delay self-calls

- Rules: `SPEC-GOV-003`, `SPEC-GOV-014`, `REQ-ROLE-104`, `setShortDelaySelector`, `setNormalDelay`.
- Scenario: one 5-day operation sets `normalDelay = 43,200` or adds `upgradeToAndCall` to the short list. `SPEC-GOV-014` itself shows a 3-day reaction fails at W = 43,200 even for one NFT. Later hostile upgrades then wait 12 h.
- Change: raise the lower bound of `setNormalDelay` to 259,200 (3 days); make the short-delay selector set an immutable allowlist (the R-13 list) so `setShortDelaySelector` can only remove entries; state both in `INV-051`.

### DR-19 — Low — Budget caps per `(spoke, GHO)` couple markets

- Rules: `R-22`, `INV-037`.
- Scenario: a dust wave in market A consumes the 500 GHO/24 h; draw-needing liquidations in market B revert for the rest of the window and become deficits.
- Change: per-market sub-caps inside the `(spoke, GHO)` cap (`per24hCap / marketCount`, floor 100 GHO), and size the GHO reserve's 24 h cap from the expected dust-liquidation count in the listing stress case (up to the 20,000 GHO maximum).

### DR-20 — Info — Consistency

- `R-09`/`R-10` in the architecture map still say Paused stops liquidation; the user override and `EMG-018`, `LIQ-002` say it does not. `Q-213`, `Q-206`, `Q-219` keep superseded wording; `review/decision-map.md:327` and `review/questions/07:497` say the Guardian can pause liquidation.
- Quint and Hypothesis models predate `Q-223`…`Q-240` (§10); evidence cited for `INV-049`/`INV-067` comes from an outdated model.
- `TEST-073` vs `TEST-116` direction (§10 item 4).
- Freeze-only key argument (`REQ-ACCESS-009`, `EMG-042`) has no holder: both guardians hold pause and freeze roles.
- `borrowPriceMaxAge = 3,600` against 24 h-heartbeat feeds blocks borrowing except in the hour after a feed update. Fail closed, but record it as intended.

---

## Required tests

Each requirement states the invariant and why single-call fuzzing cannot find a violation. IDs are local to this review (DR-T-NN); the verification owner assigns TEST IDs.

**DR-T-01 Multi-actor sequence invariant suite.** Actors: borrowers (several wallets per actor), LPs outside Avana (add/remove pool liquidity), approved keepers, permissionless liquidators, a flash-loan attacker (GHO flash mint, Uniswap flash swaps, spot pushes before and after any Avana call, sandwiches of every route), a lender (Lend Spoke supply/withdraw), guardians, timelock. Handlers include price paths, feed staleness, aggregator phase change, pool liquidity drain, GSM freeze. After every step assert §1.1–§1.6 and `INV-001`…`INV-073`. Why sequences: shielding (DR-02) needs a pledge in market B, a later oracle failure and a liquidation attempt; reflexive depth loss needs several liquidations in a row; reserve erosion needs many small deficits; none exists within one call.

**DR-T-02 Solvency after arbitrary sequences.** Invariant §1.1 with realizable value computed by simulating the configured routes at current pool state and GSM headroom. Ghost variables: cumulative deficit, cumulative bonus paid on insolvent accounts. Assert `HubDeficit ≤ CoverageFunded` while total LP drop < the listing stress case, and §1.4 per liquidation. Why sequences: insolvency is the sum of interest accrual, price moves, partial liquidations and failed liquidations over time.

**DR-T-03 Conservative LP value fuzz.** Inputs: reserves of both tokens (pool liquidity 10⁴–10¹⁵), Chainlink prices 0.01–2.0 per leg, pool spot independent of feeds, tick spacing, decimals 6/12/18, removal size 0–100 % of pool. Invariants: `price8 × units / 10^d ≤ value of removed amounts at oracle prices` (SPEC-ORC-007/008); `route_out(removed) ≥ V(1−s) − U − 1 GHO` whenever the route's measured depth ≥ threshold; and a recorded counterexample set where it fails (to size `slippageAllowanceBps`). Why not single-call: the failure needs the pool state produced by earlier unwinds and outside LP exits.

**DR-T-04 Withdrawal and liquidation cascade fuzz.** Sequence: N accounts near HF 1.10, outside LPs remove 0–90 % of pool liquidity, a price move, then keepers liquidate in random order; borrowers withdraw debt-free in between. Invariants: every liquidatable account is liquidated or the halt reason is in `EMG-047`; live pool share; no liquidation succeeds below its floor; deficit ≤ §1.4 bound. Why: the effect of each seizure on the next conversion is a cross-call property.

**DR-T-05 Oracle fuzz.** Per leg: answer 0, 1, `minAnswer`, `minAnswer + 1`, `maxAnswer − 1`, `maxAnswer`, negative, decimals mismatch, `updatedAt` 0/future/old, revert, out of gas, jumps of ±50 %, ±99 % in one round, primary/alternate divergence just inside and outside tolerance for durations around `disagreementPauseMax`, round-ID phase change during and after an outage. Same for debt feeds through the AaveOracle (≤ 0 reverts). Invariants: served price ≥ 1 and never above the capped fair value; liquidation never at a price from an invalid leg; grace applied after every Expired recovery; liquidation stop durations recorded and compared with the 48 h sizing window. Why sequences: Cached → Expired → recovery → grace is a timed state machine across many calls.

**DR-T-06 Token edge cases.** Mock tokens and mainnet-fork tokens: USDT with `basisPointsRate > 0`, USDC `pause()` and blocklist of LPVaultSwap, LPVault, a proxy, a borrower and a receiver; no-return-value `transfer`/`approve`; revert on zero transfer; decimals 6, 8, 12, 18 for pool tokens and debt assets; a rebasing token (must be rejected at listing). Invariants: no funds stuck, exits open where the token allows, breaker CB-7 trips, conservation by balance delta. Why sequences: the fee switch or blocklist happens after positions exist.

**DR-T-07 LP journey tests (end to end on a fork).** Deposit NFT → borrow GHO → collect fees → partial repay → top-up → price drop → partial liquidation → reconcile → repayAllAndWithdraw → NFT returned with fees; also the in-kind path with escrow claim, the frozen-address path (U4) and the Paused path (U1). Assert user-visible balances at each step against the Lens. Why: each step's correctness depends on state left by the previous step (records, counters, pending balances).

**DR-T-08 Deployment simulation.** `forge script` of the full deployment and the first listing batch against a mainnet fork, executed through the real Safes' transaction format and the timelock (schedule, wait, public execute), followed by the live-config check, the activation check and DR-T-01 on the resulting state. Assert every initializer ran in its deploy transaction, no role holder other than the timelock, short-delay list equals R-13, `normalDelay` = 432,000. Why: deployment ordering errors (uninitialized proxy, wrong immutable, missing role) appear only in the real sequence.

**DR-T-09 Governance drift sequences.** Random sequences of tighten/loosen/structural operations within bounds, including Aave-side CF and bonus changes. Invariants: DR-01 tail inequality, DR-06 slippage inequality, DR-05 drift detection, DR-18 delay bounds hold after every executed operation. Why: each change is within bounds alone; the violation is in the combination.

**DR-T-10 Contagion test.** Two markets A and B, accounts holding both; B Cached, Expired, disagreeing, Aave-frozen; a debt feed stale. Invariant §1.5: liquidation of A-collateral of every account succeeds whenever its HF < 1 and A's prices are fresh. This test fails against the current spec (DR-02).

**DR-T-11 MEV test.** Fork test with a searcher contract sandwiching every route leg of a liquidation, the buy leg and `settlePending`, at sizes up to the debt cap. Invariant: extraction ≤ `s × V + U + 1 GHO` per call (or the per-leg bound after DR-07); lenders and the reserve lose nothing. Why: requires an attacker transaction before and after the Avana call in the same block.
