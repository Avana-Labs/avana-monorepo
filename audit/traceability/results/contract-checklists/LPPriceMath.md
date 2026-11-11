# Checklist: LPPriceMath

Spec pages: 10-lp-oracle.md. CVL specs: none.

## REQ / SPEC on the page (129)

- [ ] `REQ-ORACLE-001` (10-lp-oracle.md:161) For each leg, LPOracle MUST call `latestRoundData()` and `decimals()` on the configured aggregator address as 
- [x] `REQ-ORACLE-002` (10-lp-oracle.md:162) A leg MUST be treated as valid only if all of these hold: `decimals()` equals the pinned decimals; `answer > m — TEST-037, TEST-038, TEST-070
- [ ] `REQ-ORACLE-003` (10-lp-oracle.md:163) A leg that fails only the `now − updatedAt ≤ feedMaxAge` condition MUST be classed `Stale`; a leg that fails a
- [ ] `REQ-ORACLE-004` (10-lp-oracle.md:164) A route MUST be treated as valid only if every leg is valid and `r ≥ 1`; an invalid route is `Stale` if every 
- [ ] `REQ-ORACLE-005` (10-lp-oracle.md:168) For each token *i*, LPOracle MUST select the quote as follows: if the primary route is valid, `q_i = r_primary
- [ ] `REQ-ORACLE-006` (10-lp-oracle.md:169) Failover to the alternate MUST be automatic and re-evaluated on every read: no transaction, role or stored fla
- [ ] `REQ-ORACLE-007` (10-lp-oracle.md:170) LPOracle MUST NOT have a stored switch that disables a primary route: failover is automatic (`REQ-ORACLE-006`)
- [x] `REQ-ORACLE-008` (10-lp-oracle.md:171) When both routes of a token are valid, LPOracle MUST run the agreement check `SPEC-ORC-003` on the uncapped ro — PROP-026, TEST-039
- [x] `SPEC-ORC-003` (10-lp-oracle.md:172) **Agreement tolerance.** Token *i* agrees iff `|p − b| · 10^4 ≤ T_i · min(p, b)`, where `p = r_primary`, `b =  — PROP-026, TEST-037, TEST-039, TEST-070
- [x] `SPEC-ORC-004` (10-lp-oracle.md:176) **Valuation price.** `v_i = min(q_i, stableCeilingUsd)` if `isUsdStable[i]`, else `v_i = q_i`. Units: 8-decima — PROP-024, TEST-037, TEST-167
- [x] `REQ-ORACLE-009` (10-lp-oracle.md:177) LPOracle MUST use `v` (capped) for every valuation output: `price8` (`SPEC-ORC-008`), the composition (`SPEC-O — PROP-024, TEST-167, TEST-251
- [ ] `REQ-ORACLE-010` (10-lp-oracle.md:178) `isUsdStable[i]` MUST be set at `initialize` for every approved USD-pegged stable (GHO, USDC, USDT, DAI, USDS 
- [x] `REQ-ORACLE-011` (10-lp-oracle.md:184) LPOracle MUST compute `price8` with `SPEC-ORC-008` from the pricing module's composition `a(10^d, v)` at the v — TEST-036
- [x] `REQ-ORACLE-012` (10-lp-oracle.md:185) Every division and square root in the valuation path MUST round down (against the borrower) using pinned OpenZ — PROP-023, TEST-036, TEST-037, TEST-070, TEST-217
- [x] `REQ-ORACLE-013` (10-lp-oracle.md:186) LPOracle MUST NOT apply any haircut, discount, premium or smoothing to `price8`; the value of a vault token de — PROP-024, TEST-036
- [x] `REQ-ORACLE-103` (10-lp-oracle.md:187) Preserves: the vault-token price never exceeds the oracle value of the backing. The pricing module MUST provid — PROP-023, TEST-036, TEST-037, TEST-139, TEST-217, TEST-251
- [x] `REQ-ORACLE-015` (10-lp-oracle.md:191) A USD band breach MUST make the market Drifting (reason `USD_BAND`), which blocks new borrowing and withdraw-w — TEST-251
- [x] `REQ-ORACLE-085` (10-lp-oracle.md:197) While the market is Expired, `latestAnswer()` and the `answer` of `latestRoundData()` and `getPriceState()` MU — TEST-230
- [x] `REQ-ORACLE-086` (10-lp-oracle.md:198) While some token disagrees (`SPEC-ORC-016` `pauseActive ∨ disagreementExpired`) and the market is not failed,  — TEST-219, TEST-230
- [ ] `REQ-ORACLE-087` (10-lp-oracle.md:199) `lastAcceptedPrice()` MUST return `(uint256(accepted.answer), accepted.updatedAt)` in every state, with no ext
- [x] `SPEC-ORC-001` (10-lp-oracle.md:205) **Leg normalisation.** For a raw answer `a` (the signed `int256` of `latestRoundData()`) with `f` decimals: `n — TEST-037, TEST-038, TEST-070
- [x] `SPEC-ORC-002` (10-lp-oracle.md:206) **Route value and timestamp.** One leg: `r = n`. Two legs `A` (token in intermediate `X`, raw `aA`, `fA` decim — TEST-037, TEST-070
- [x] `SPEC-ORC-019` (10-lp-oracle.md:207) **Feed age limit.** For each leg: `feedMaxAge = feedHeartbeat + heartbeatMargin`, where `feedHeartbeat` is the — TEST-250
- [x] `SPEC-ORC-005` (10-lp-oracle.md:208) **Vault-token unit.** One vault-token base unit is one unit of the position measure the AMM integration credit — TEST-139
- [ ] `SPEC-ORC-007` (10-lp-oracle.md:209) **Fair composition is the minimum over pool prices.** For a price vector `x`, let `V(a) = Σ_i a_i · x_i / 10^(
- [x] `SPEC-ORC-008` (10-lp-oracle.md:210) **Price of one whole vault token.** With `a = composition(10^d, v)` (raw units, each floored by the pricing mo — PROP-023, PROP-024, TEST-036, TEST-037, TEST-070, TEST-217, TEST-219, TEST-230
- [x] `SPEC-ORC-011` (10-lp-oracle.md:211) **USD band.** For a market whose tokens are all USD-pegged stables, the market is in band iff `usdBandLow^⊗n ≤ — TEST-037, TEST-251
- [x] `SPEC-ORC-012` (10-lp-oracle.md:212) **Fresh price and served timestamp.** If the market is not failed: `fresh = price8(v)` (`SPEC-ORC-008`) and `s — TEST-037, TEST-038
- [x] `SPEC-ORC-015` (10-lp-oracle.md:213) **Age limits of the served price.** When the market is not failed, let `Λ` be the legs of each token's route i — TEST-037, TEST-250
- [x] `SPEC-ORC-017` (10-lp-oracle.md:214) **Served price by state.** Let `A = accepted.answer`, `fresh` as in `SPEC-ORC-012`, and, for a disagreement, ` — TEST-037, TEST-219, TEST-230
- [x] `SPEC-ORC-020` (10-lp-oracle.md:215) **Second-source agreement.** For token *i* with quote `q_i` and second-source value `s_i` (8-decimal USD per w — PROP-026, TEST-037, TEST-039, TEST-276
- [x] `SPEC-ORC-021` (10-lp-oracle.md:216) **Sequencer gate.** On a chain whose `sequencer.feed ≠ address(0)`, read `(answer, startedAt)` from its `lates — TEST-037, TEST-275
- [x] `SPEC-ORC-022` (10-lp-oracle.md:217) **Observation buffer per chain.** For a consistency check over window `W` on a pool that writes at most one ob — TEST-037, TEST-139, TEST-250
- [x] `SPEC-ORC-023` (10-lp-oracle.md:218) **Gas guard for external reads.** Each external read `k` of an evaluation (legs, previous-phase lookups, secon — TEST-037, TEST-042
- [ ] `SPEC-ORC-009` (10-lp-oracle.md:224) **sqrtPriceX96 from two prices.** Inputs: prices `x0`, `x1` (8 decimals; uncapped `q0`, `q1` for the consisten
- [ ] `SPEC-ORC-006` (10-lp-oracle.md:225) **Concentrated-liquidity composition.** For `u` units at the capped price vector `v`: `s_O = SPEC-ORC-009(v0, 
- [ ] `SPEC-ORC-010` (10-lp-oracle.md:226) **Consistency check (TWAP).** `tickRef = TickMath.getTickAtSqrtRatio(s_ref)`, with `s_ref` from `SPEC-ORC-009`
- [ ] `REQ-ORACLE-014` (10-lp-oracle.md:227) The consistency check MUST read only the market's own pool stored at `initialize`, in the pool's token order, 
- [ ] `REQ-ORACLE-104` (10-lp-oracle.md:228) The concentrated-liquidity module MUST set reason `PRICE_CLAMPED` (Drifting) when `SPEC-ORC-009` clamped the s
- [x] `REQ-ORACLE-105` (10-lp-oracle.md:229) At listing (`checkConfig`), on-chain: the market's `tickLower` and `tickUpper` MUST each satisfy `tick % tickS — TEST-139
- [ ] `REQ-ORACLE-016` (10-lp-oracle.md:233) LPOracle MUST report exactly one of four states with severity `Live (0) < Drifting (1) < Cached (2) < Expired 
- [ ] `REQ-ORACLE-017` (10-lp-oracle.md:234) The market MUST be failed when any token has no valid route; when the ParameterStore configuration read fails 
- [ ] `SPEC-ORC-013` (10-lp-oracle.md:235) **Failure start ("first failed read").** For a route that is `Stale`: `staleFrom_r = min over its Stale legs o
- [ ] `REQ-ORACLE-018` (10-lp-oracle.md:236) A market that is not failed MUST be Drifting if any of these holds: a token's routes disagree (`REQ-ORACLE-008
- [ ] `REQ-ORACLE-019` (10-lp-oracle.md:237) A market whose tokens use their alternate routes MUST be Live when no Drifting condition holds; using the alte
- [x] `REQ-ORACLE-020` (10-lp-oracle.md:238) `latestAnswer()` MUST return the served price (`SPEC-ORC-017`): the fresh price when Live; the lower of the fr — TEST-219, TEST-230
- [x] `REQ-ORACLE-021` (10-lp-oracle.md:239) Freshness MUST be exposed separately from the price: the served price keeps its original source timestamp (`se — TEST-038
- [x] `REQ-ORACLE-099` (10-lp-oracle.md:289) Preserves: no borrowing on prices nobody could react to; liquidation never stops for a broken uptime feed. On  — TEST-037, TEST-250, TEST-275
- [x] `REQ-ORACLE-100` (10-lp-oracle.md:290) Preserves: no borrowing on a single network's frozen price. For every token, LPOracle MUST evaluate the second — TEST-276
- [ ] `REQ-ORACLE-101` (10-lp-oracle.md:291) Preserves: an oracle switch never stops liquidation. A market's LPOracle proxy address MUST stay the Aave pric
- [x] `REQ-ORACLE-102` (10-lp-oracle.md:292) Preserves: no caller can make a healthy feed look failed. Every external read of the LPOracle and the DebtOrac — TEST-042
- [ ] `REQ-ORACLE-022` (10-lp-oracle.md:296) The disagreement pause MUST be reported active iff some token disagrees (`REQ-ORACLE-008`) and `now < disagree
- [ ] `REQ-ORACLE-023` (10-lp-oracle.md:297) `disagreementPauseMax` MUST stay within its bound in [1.5](../01-architecture/05-parameters.md); LPOracle read
- [ ] `SPEC-ORC-016` (10-lp-oracle.md:298) **Pause and expiry windows.** With `D` = "some token disagrees" and `s = disagreeSince ≠ 0 ? disagreeSince : n
- [ ] `REQ-ORACLE-094` (10-lp-oracle.md:302) LPOracle MUST read, on every evaluation, each token's routes in force from `MarketRegistry.activePriceRoutes(t
- [ ] `REQ-ORACLE-095` (10-lp-oracle.md:303) When some token's `priceRouteVersion` differs from `routeVersion[i]`, the evaluation MUST treat `disagreeSince
- [ ] `REQ-ORACLE-024` (10-lp-oracle.md:307) `poke()` MUST revert with `InsufficientGas(gasleft(), pokeMinGas)` when `gasleft() < pokeMinGas` at entry, bef
- [ ] `REQ-ORACLE-025` (10-lp-oracle.md:308) `poke()` MUST be permissionless, MUST NOT take the Avana lock, and MUST make only static calls (to legs and th
- [ ] `REQ-ORACLE-026` (10-lp-oracle.md:309) `poke()` MUST evaluate the market with the same code and in the same block as `getPriceState()`, then apply `R
- [ ] `REQ-ORACLE-027` (10-lp-oracle.md:310) If the market is failed and `failedSince == 0`, `poke()` MUST set `failedSince = min(S_ts, now)` (`SPEC-ORC-01
- [ ] `REQ-ORACLE-028` (10-lp-oracle.md:311) If some token disagrees and `disagreeSince == 0`, `poke()` MUST set `disagreeSince = now`; if no token disagre
- [ ] `REQ-ORACLE-029` (10-lp-oracle.md:312) `poke()` MUST store `accepted = {price8, min_i t_i, v}` only when the state is Live and `min_i t_i > accepted.
- [ ] `REQ-ORACLE-030` (10-lp-oracle.md:313) `poke()` MUST set `expiredLatched = true` only when the source timestamps show Expired: some failed token has 
- [ ] `REQ-ORACLE-031` (10-lp-oracle.md:314) `poke()` MUST record, for every leg whose read returned decodable data (valid, `Stale` or `Invalid`), its aggr
- [ ] `SPEC-ORC-014` (10-lp-oracle.md:315) **Recovery evidence from source timestamps.** Evaluated by `poke()` for each token *i* when the market is not 
- [ ] `REQ-ORACLE-032` (10-lp-oracle.md:316) When the market is not failed, `poke()` MUST start a grace window if `expiredLatched` is true or `SPEC-ORC-014
- [ ] `REQ-ORACLE-033` (10-lp-oracle.md:317) Each outage MUST start at most one grace window: an interval ending at or before the stored `recoveredAt` neve
- [ ] `REQ-ORACLE-034` (10-lp-oracle.md:318) `inGrace` MUST be reported true iff (`recoveredAt ≠ 0` and `recoveredAt ≤ now < recoveredAt + graceDuration`) 
- [ ] `REQ-ORACLE-035` (10-lp-oracle.md:319) `poke()` MUST emit `PriceStateChanged` when the state differs from `lastState`, `RouteChanged` when a token's 
- [ ] `REQ-ORACLE-036` (10-lp-oracle.md:320) The callers that act on LPOracle state MUST call `poke()` on each LPOracle they rely on before reading it, so 
- [ ] `REQ-ORACLE-037` (10-lp-oracle.md:321) Keepers MUST call `poke()` on every market's LPOracle and every DebtOracle at least once per `CHECKPOINT_INTER
- [x] `REQ-ORACLE-038` (10-lp-oracle.md:322) `setPokeMinGas(g)` MUST revert with `PokeMinGasOutOfBounds` unless `POKE_MIN_GAS_FLOOR ≤ g ≤ POKE_MIN_GAS_CEIL — TEST-042
- [ ] `REQ-ORACLE-088` (10-lp-oracle.md:323) `priceCheckpoint()` MUST return `(checkpoint.price8, checkpoint.at)`. `initialize` MUST set the checkpoint to 
- [ ] `REQ-ORACLE-089` (10-lp-oracle.md:324) When a leg's current round is the first of a new aggregator phase (`uint64(roundId) == 1`), the recovery-evide
- [x] `REQ-ORACLE-039` (10-lp-oracle.md:328) In any read path (views and `poke()`), LPOracle MUST make every external read with the explicit gas and the pr — TEST-042
- [ ] `REQ-ORACLE-040` (10-lp-oracle.md:329) `decimals()` MUST return 8 for the life of the proxy, matching Aave's 8-decimal USD format, and `description()
- [ ] `REQ-ORACLE-041` (10-lp-oracle.md:330) `latestRoundData()` MUST return `answer = served`, `updatedAt = startedAt = servedUpdatedAt` (the oldest input
- [x] `REQ-ORACLE-042` (10-lp-oracle.md:331) `getPriceState()` MUST return a `PriceStateView` computed by the same code as `latestAnswer()` in the same blo — TEST-037, TEST-039, TEST-251
- [x] `REQ-ORACLE-043` (10-lp-oracle.md:332) `borrowPriceMaxAge()` and `liquidationPriceMaxAge()` MUST return the `SPEC-ORC-015` values; LPOracle does not  — TEST-250
- [x] `REQ-ORACLE-090` (10-lp-oracle.md:333) While a token's route in use is its alternate, LPOracle MUST hold every leg of that alternate to its `borrowPr — TEST-037, TEST-250
- [ ] `REQ-ORACLE-044` (10-lp-oracle.md:334) `getTokenPrices()` MUST return `(v, servedUpdatedAt, state)`: the capped valuation price vector of the fresh e
- [ ] `REQ-ORACLE-045` (10-lp-oracle.md:335) Every view MUST return the same result for every caller in the same block; no output depends on `msg.sender`, 
- [ ] `REQ-ORACLE-046` (10-lp-oracle.md:341) `checkConfig` MUST check, on-chain, every rule from `REQ-ORACLE-047` to `REQ-ORACLE-056` and `REQ-ORACLE-105` 
- [x] `REQ-ORACLE-047` (10-lp-oracle.md:342) On-chain: `2 ≤ n ≤ MAX_POOL_TOKENS` and the vault-token decimals `d` MUST be the value of `SPEC-ORC-005` at th — TEST-139
- [ ] `REQ-ORACLE-048` (10-lp-oracle.md:343) On-chain: token order and decimals MUST be read from the pool and tokens, never from the listing name, and sto
- [x] `REQ-ORACLE-049` (10-lp-oracle.md:344) On-chain: for every leg, the pinned `decimals` MUST equal `decimals()` read at listing; the pinned `minAnswer` — TEST-070
- [ ] `REQ-ORACLE-050` (10-lp-oracle.md:345) On-chain: with every quote moved by `LISTING_SHOCK_FACTOR` in each direction from its current value (each toke
- [ ] `REQ-ORACLE-051` (10-lp-oracle.md:346) On-chain: a token's primary and alternate routes MUST share no aggregator; no two tokens' alternate routes MUS
- [ ] `REQ-ORACLE-052` (10-lp-oracle.md:347) Off-chain: each primary MUST be the token's direct `TOKEN/USD` Chainlink feed through its standard Chainlink p
- [ ] `REQ-ORACLE-053` (10-lp-oracle.md:348) On-chain: `feedAgreementToleranceBps[i]` MUST be at least the sum of the `feedDeviationThresholdBps` of every 
- [x] `REQ-ORACLE-054` (10-lp-oracle.md:349) On-chain, in the MarketRegistry's route checks ([2.8](08-market-registry.md)) and the ParameterStore's `setFee — TEST-250
- [x] `REQ-ORACLE-055` (10-lp-oracle.md:350) On-chain: `twapWindow > 0` and `twapToleranceTicks ≥ twapToleranceMinTicks` (10 ticks; the launch τ of 50 tick — TEST-139
- [ ] `REQ-ORACLE-056` (10-lp-oracle.md:351) On-chain: for a market whose tokens are all USD-pegged stables, `usdBandLow < 10^8 < usdBandHigh` (8-decimal l
- [ ] `REQ-ORACLE-057` (10-lp-oracle.md:352) Off-chain: listing MUST show `(1 − CF)` larger than the feed deviation threshold plus heartbeat drift, minimum
- [ ] `REQ-ORACLE-058` (10-lp-oracle.md:353) `initialize` MUST run once, in the same transaction as the proxy deployment, which Avana operators make before
- [ ] `REQ-ORACLE-059` (10-lp-oracle.md:354) `initialize` MUST revert unless the evaluation of the configuration in its arguments is Live (the pipeline of 
- [x] `REQ-ORACLE-060` (10-lp-oracle.md:409) LPOracle MUST NOT return a value ≤ 0 from `latestAnswer()` or `latestRoundData()` in any state, including Expi — TEST-036, TEST-219, TEST-230
- [x] `REQ-ORACLE-061` (10-lp-oracle.md:410) `latestAnswer()`, `latestRoundData()`, `decimals()`, `description()`, `getPriceState()`, `getTokenPrices()`, ` — TEST-036, TEST-038, TEST-070
- [ ] `REQ-ORACLE-062` (10-lp-oracle.md:411) LPOracle MUST NOT have any function that sets, overrides or extends the accepted price, its timestamp, `failed
- [ ] `REQ-ORACLE-063` (10-lp-oracle.md:412) The valuation and state paths MUST NOT read a pool's spot price or spot balances for valuation (`slot0`, `bala
- [ ] `REQ-ORACLE-064` (10-lp-oracle.md:413) LPOracle MUST NOT hold or receive tokens or ETH (no `payable` function, no `receive`), grant approvals, or mak
- [ ] `REQ-ORACLE-065` (10-lp-oracle.md:414) LPOracle MUST NOT set `expiredLatched` or `recoveredAt` from a caught error, a failed configuration read, a ga
- [x] `REQ-ORACLE-066` (10-lp-oracle.md:415) LPOracle MUST NOT refresh `accepted.updatedAt` or `servedUpdatedAt` by reading, caching or re-serving the same — TEST-038
- [ ] `REQ-ORACLE-082` (10-lp-oracle.md:416) The `poke()` selector, its empty argument list and its `PriceState` return MUST stay unchanged across upgrades
- [ ] `REQ-ORACLE-083` (10-lp-oracle.md:417) LPOracle MUST apply the `feedAgreementToleranceBps`, second-source tolerances and `twapToleranceTicks` returne
- [ ] `REQ-ORACLE-084` (10-lp-oracle.md:418) When some token still disagrees after `disagreementPauseMax` (`SPEC-ORC-016` `disagreementExpired`), LPOracle 
- [ ] `REQ-ORACLE-097` (10-lp-oracle.md:419) The LPOracle and every DebtOracle MUST override `_grantRole` to revert `AdminRoleOnlyTimelock(role, account)` 
- [ ] `REQ-ORACLE-067` (10-lp-oracle.md:425) A token's primary leg reverts, returns malformed data, a wrong `decimals()`, an answer at or beyond its pinned
- [ ] `REQ-ORACLE-068` (10-lp-oracle.md:426) Both routes of a token are invalid (Source: Q-079, Q-183) | Fallback: serve the accepted price with its origin
- [ ] `REQ-ORACLE-069` (10-lp-oracle.md:427) ParameterStore configuration or feed read fails, MarketRegistry route read fails, a pricing-module read fails 
- [ ] `REQ-ORACLE-070` (10-lp-oracle.md:428) Both routes valid and outside `T_i` (Source: Q-112, Q-162, Q-208) | Pause: Drifting; this market's seizure pau
- [ ] `REQ-ORACLE-071` (10-lp-oracle.md:429) The consistency read fails, or the consistency check fails (concentrated liquidity: `|meanTick − tickRef| > τ`
- [ ] `REQ-ORACLE-072` (10-lp-oracle.md:430) `num ≥ 2^64 · den` or `s < MIN_SQRT_RATIO` in `SPEC-ORC-009`, or the oracle ratio lies outside the market's ra
- [ ] `REQ-ORACLE-073` (10-lp-oracle.md:431) `⊗ q_i < usdBandLow^⊗n` or `⊗ v_i > usdBandHigh^⊗n` (`SPEC-ORC-011`) (Source: Q-176, Q-195, Q-275, Q-329) | Dr
- [ ] `REQ-ORACLE-074` (10-lp-oracle.md:432) `gasleft() < pokeMinGas` at `poke()` entry, or below the pre-call bound of `SPEC-ORC-023` before any read (Sou
- [ ] `REQ-ORACLE-075` (10-lp-oracle.md:433) `getRoundData(roundId − 1)` reverts or returns unusable data during `SPEC-ORC-014`, or, on the first round of 
- [ ] `REQ-ORACLE-076` (10-lp-oracle.md:434) `checkConfig` non-zero or evaluation not Live at `initialize` (Source: Q-128, Q-191) | `initialize` reverts wi
- [ ] `REQ-ORACLE-077` (10-lp-oracle.md:435) A new oracle configuration fails `checkConfig` (Source: Q-184, Q-191) | The ParameterStore or MarketRegistry r
- [ ] `REQ-ORACLE-078` (10-lp-oracle.md:439) LPOracle MUST be deployed behind an ERC-1967 proxy using the UUPS pattern, whose `_authorizeUpgrade` requires 
- [ ] `REQ-ORACLE-079` (10-lp-oracle.md:440) New price sources (any new aggregator, route composition, second source, sequencer feed or consistency pool) a
- [ ] `REQ-ORACLE-080` (10-lp-oracle.md:441) Implementations MUST use ERC-7201 storage, call `_disableInitializers()` in their constructor, run any `reinit
- [ ] `REQ-ORACLE-106` (10-lp-oracle.md:442) Each AMM protocol's LPOracle implementation MUST be a proxy target holding the roles, the upgrade, `setPokeMin
- [ ] `REQ-ORACLE-081` (10-lp-oracle.md:443) After every upgrade, `decimals()` MUST return 8 and `latestAnswer()` MUST be ≥ 1 in the same transaction (chec
- [ ] `REQ-ORACLE-091` (10-lp-oracle.md:504) Preserves: always a price; the price source cannot be swapped without the Aave DAO. Each non-GHO debt asset MU
- [ ] `REQ-ORACLE-092` (10-lp-oracle.md:505) Preserves: S; always a price. The DebtOracle MUST evaluate its asset with the LPOracle's rules applied to one 
- [x] `REQ-ORACLE-093` (10-lp-oracle.md:506) Preserves: S; no repayment or seizure at a stress price; always a price. `latestAnswer()` and the `answer` of  — TEST-219, TEST-230
- [x] `SPEC-ORC-018` (10-lp-oracle.md:507) **Served debt price by state.** Let `A = accepted.price8`, `q` the fresh quote (`REQ-ORACLE-005`), `p` and `b` — TEST-037, TEST-070, TEST-219, TEST-230
- [ ] `REQ-ORACLE-096` (10-lp-oracle.md:508) The callers that act on a DebtOracle's state MUST call its `poke()` before reading it, so the first observatio
- [ ] `REQ-ORACLE-098` (10-lp-oracle.md:509) Preserves: always a price; no role can choose a price. The DebtOracle MUST make only static calls (to its legs

## TEST rows (1)

- [x] `TEST-217` [fuzz] Conservative LP value (`INV-078`): pool liquidity 10⁴ to 10¹⁵, Chainlink answers 0.01 to 2.0 per leg, pool spo

## Cross-cutting TEST rows, every contract (17)

- [ ] `TEST-001` [environment] The Foundry workspace builds with solc 0.8.28 and EVM `cancun`, the same compiler as Aave V4; dependencies are
- [x] `TEST-032` [access-control] Selector inventory: the external selectors of every deployed Avana contract are enumerated from bytecode and c
- [x] `TEST-061` [unit] Events: every borrower and keeper action is one atomic call that emits the inventory events of its contracts, 
- [x] `TEST-177` [unit] Zero-amount transfers skipped: with mock tokens that revert on a zero-amount `transfer` and `transferFrom`, ev
- [x] `TEST-062` [access-control] Role map: every privileged selector of every Avana contract checks the role or the `TIMELOCK` address in the r
- [x] `TEST-066` [access-control] Guardian powers: the Emergency Guardian (3-of-5) and the Aave Protocol Guardian hold `APPLICATION_PAUSE_GUARDI
- [x] `TEST-080` [fuzz] Dust donations: sending 1 wei up to 10^6 wei of GHO, USDC, WETH, DAI, pool tokens or vault tokens (where the r
- [ ] `TEST-092` [invariant] Conservation: for every token (each debt asset, each pool token, each vault token), the sum of tracked balance
- [ ] `TEST-107` [invariant] Hostile suite: with the RiskModule, MarketRegistry, ParameterStore, LPOracle and LPVaultSwap replaced through 
- [x] `TEST-108` [invariant] Structure and governance: immutables and runtime code hashes of the LPVault, Collateralization, vault tokens, 
- [x] `TEST-212` [invariant] Timelock timing: handlers schedule normal, short and mixed batches (short-listed and normal calls in one batch
- [ ] `TEST-121` [fork] End-to-end lifecycle on one fork (Avana-deployed Aave V4 plus Ethereum Uniswap v3, Chainlink, GHO, the Aave V3
- [ ] `TEST-126` [fork] Emergency matrix: for every row of the matrix in [3.6](../03-operations/06-emergency-operations.md) (applicati
- [ ] `TEST-127` [fork] Halt deterioration and caps: with liquidation of an account stopped for the 48-hour incident window of `Q-192`
- [ ] `TEST-137` [deployment-check] Upgrade safety: every UUPS contract (AaveAdapter, MarketRegistry, ParameterStore, RiskModule, LPOracle, LPVaul
- [ ] `TEST-214` [deployment-check] Role snapshot: on every upgradeable Avana contract `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` are held only 
- [x] `TEST-224` [deployment-check] Deployment simulation: `forge script` on the Ethereum fork and on the Base fork runs the chain's full deployme

## PROP rows (0)


## INV (1)

- [x] `INV-087` Stress valuation is monotone and never prices a seizure or repayment. When a market is not Live, its LPOracle'

## ATTACK (1)

- [x] `ATTACK-055` Oracle rounding and normalisation edge cases
84 IDs without a link from contracts/: REQ-ORACLE-001, REQ-ORACLE-003, REQ-ORACLE-004, REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-007, REQ-ORACLE-010, REQ-ORACLE-087, SPEC-ORC-007, SPEC-ORC-009, SPEC-ORC-006, SPEC-ORC-010, REQ-ORACLE-014, REQ-ORACLE-104, REQ-ORACLE-016, REQ-ORACLE-017, SPEC-ORC-013, REQ-ORACLE-018, REQ-ORACLE-019, REQ-ORACLE-101 …
