# Checklist: ClPricing

Spec pages: 10-lp-oracle.md, 20-uniswap-v3-integration.md. CVL specs: none.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (160: 9 verified, 0 failed, 124 not run, 27 unlinked)

- [~] `REQ-ORACLE-001` (10-lp-oracle.md:168) For each leg, LPOracle MUST call `latestRoundData()` and `decimals()` on the configured aggregator address as  — TEST-038, TEST-219, TEST-275
- [~] `REQ-ORACLE-002` (10-lp-oracle.md:169) A leg MUST be treated as valid only if all of these hold: `decimals()` equals the pinned decimals; `answer > m — TEST-037, TEST-038, TEST-040, TEST-070, TEST-219, TEST-276, TEST-294
- [~] `REQ-ORACLE-003` (10-lp-oracle.md:170) A leg that fails only the `now − updatedAt ≤ feedMaxAge` condition MUST be classed `Stale`; a leg that fails a — TEST-040, TEST-219, TEST-276
- [~] `REQ-ORACLE-004` (10-lp-oracle.md:171) A route MUST be treated as valid only if every leg is valid and `r ≥ 1`; an invalid route is `Stale` if every  — TEST-040, TEST-219, TEST-276
- [x] `REQ-ORACLE-005` (10-lp-oracle.md:175) For each token *i*, LPOracle MUST select the quote as follows: if the primary route is valid, `q_i = r_primary — PROP-074, TEST-040, TEST-219, TEST-231, TEST-276 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_074_servedDebtPriceAgainstFixedAlternate
- [~] `REQ-ORACLE-006` (10-lp-oracle.md:176) Failover to the alternate MUST be automatic and re-evaluated on every read: no transaction, role or stored fla — PROP-074, TEST-040, TEST-219, TEST-231
- [ ] `REQ-ORACLE-007` (10-lp-oracle.md:177) LPOracle MUST NOT have a stored switch that disables a primary route: failover is automatic (`REQ-ORACLE-006`) — TEST-040 (only excluded checks: uses a stand-in for ClPricing)
- [x] `REQ-ORACLE-008` (10-lp-oracle.md:178) When both routes of a token are valid, LPOracle MUST run the agreement check `SPEC-ORC-003` on the uncapped ro — PROP-026, PROP-074, TEST-006, TEST-039, TEST-040, TEST-219 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_074_servedDebtPriceAgainstFixedAlternate
- [~] `SPEC-ORC-003` (10-lp-oracle.md:179) **Agreement tolerance.** Token *i* agrees iff `|p − b| · 10^4 ≤ T_i · min(p, b)`, where `p = r_primary`, `b =  — PROP-026, TEST-037, TEST-039, TEST-040, TEST-070, TEST-219
- [x] `SPEC-ORC-004` (10-lp-oracle.md:183) **Valuation price.** `v_i = min(q_i, stableCeilingUsd)` if `isUsdStable[i]`, else `v_i = q_i`. Units: 8-decima — PROP-024, TEST-036, TEST-037, TEST-167 — test/halmos/LPPriceMath.halmos.t.sol:LPPriceMathHalmosTest.check_PROP_024_stableCeilingNeverRaisesAndIsMonotone
- [x] `REQ-ORACLE-009` (10-lp-oracle.md:184) LPOracle MUST use `v` (capped) for every valuation output: `price8` (`SPEC-ORC-008`), the composition (`SPEC-O — PROP-024, TEST-036, TEST-167, TEST-251 — test/halmos/LPPriceMath.halmos.t.sol:LPPriceMathHalmosTest.check_PROP_024_stableCeilingNeverRaisesAndIsMonotone
- [ ] `REQ-ORACLE-010` (10-lp-oracle.md:185) `isUsdStable[i]` MUST be set at `initialize` for every approved USD-pegged stable (GHO, USDC, USDT, DAI, USDS  — TEST-036 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-011` (10-lp-oracle.md:191) LPOracle MUST compute `price8` with `SPEC-ORC-008` from the pricing module's composition `a(10^d, v)` at the v — TEST-036
- [~] `REQ-ORACLE-012` (10-lp-oracle.md:192) Every division and square root in the valuation path MUST round down (against the borrower) using pinned OpenZ — PROP-023, TEST-036, TEST-037, TEST-070, TEST-079, TEST-217, TEST-279
- [~] `REQ-ORACLE-013` (10-lp-oracle.md:193) LPOracle MUST NOT apply any haircut, discount, premium or smoothing to `price8`; the value of a vault token de — PROP-024, TEST-036
- [~] `REQ-ORACLE-103` (10-lp-oracle.md:194) Preserves: the vault-token price never exceeds the oracle value of the backing. The pricing module MUST provid — PROP-023, TEST-036, TEST-037, TEST-040, TEST-042, TEST-139, TEST-217, TEST-219, TEST-250, TEST-251
- [~] `REQ-ORACLE-015` (10-lp-oracle.md:198) A USD band breach MUST make the market Drifting (reason `USD_BAND`), which blocks new borrowing and withdraw-w — TEST-039, TEST-040, TEST-043, TEST-251
- [~] `REQ-ORACLE-085` (10-lp-oracle.md:204) While the market is Expired, `latestAnswer()` and the `answer` of `latestRoundData()` and `getPriceState()` MU — PROP-074, TEST-038, TEST-039, TEST-219, TEST-230, TEST-247, TEST-294
- [~] `REQ-ORACLE-086` (10-lp-oracle.md:205) While some token disagrees (`SPEC-ORC-016` `pauseActive ∨ disagreementExpired`) and the market is not failed,  — PROP-074, TEST-040, TEST-044, TEST-219, TEST-230
- [~] `REQ-ORACLE-087` (10-lp-oracle.md:206) `lastAcceptedPrice()` MUST return `(uint256(accepted.answer), accepted.updatedAt)` in every state, with no ext — TEST-038, TEST-042, TEST-105, TEST-230
- [~] `SPEC-ORC-001` (10-lp-oracle.md:212) **Leg normalisation.** For a raw answer `a` (the signed `int256` of `latestRoundData()`) with `f` decimals: `n — TEST-037, TEST-038, TEST-070, TEST-219
- [~] `SPEC-ORC-002` (10-lp-oracle.md:213) **Route value and timestamp.** One leg: `r = n`. Two legs `A` (token in intermediate `X`, raw `aA`, `fA` decim — TEST-037, TEST-070, TEST-219, TEST-276
- [~] `SPEC-ORC-019` (10-lp-oracle.md:214) **Feed age limit.** For each leg: `feedMaxAge = feedHeartbeat + heartbeatMargin`, where `feedHeartbeat` is the — TEST-040, TEST-219, TEST-250, TEST-276
- [~] `SPEC-ORC-005` (10-lp-oracle.md:215) **Vault-token unit.** One vault-token base unit is one unit of the position measure the AMM integration credit — TEST-036, TEST-062, TEST-139, TEST-264
- [~] `SPEC-ORC-007` (10-lp-oracle.md:216) **Fair composition is the minimum over pool prices.** For a price vector `x`, let `V(a) = Σ_i a_i · x_i / 10^( — TEST-217, TEST-279
- [~] `SPEC-ORC-008` (10-lp-oracle.md:217) **Price of one whole vault token.** With `a = composition(10^d, v)` (raw units, each floored by the pricing mo — PROP-023, PROP-024, TEST-036, TEST-037, TEST-070, TEST-217, TEST-219, TEST-230
- [~] `SPEC-ORC-011` (10-lp-oracle.md:218) **USD band.** For a market whose tokens are all USD-pegged stables, the market is in band iff `usdBandLow^⊗n ≤ — TEST-037, TEST-043, TEST-251
- [~] `SPEC-ORC-012` (10-lp-oracle.md:219) **Fresh price and served timestamp.** If the market is not failed: `fresh = price8(v)` (`SPEC-ORC-008`) and `s — PROP-074, TEST-037, TEST-038, TEST-040, TEST-219, TEST-231
- [~] `SPEC-ORC-015` (10-lp-oracle.md:220) **Age limits of the served price.** When the market is not failed, let `Λ` be the legs of each token's route i — PROP-074, TEST-037, TEST-219, TEST-250, TEST-276
- [~] `SPEC-ORC-017` (10-lp-oracle.md:221) **Served price by state.** Let `A = accepted.answer`, `fresh` as in `SPEC-ORC-012`, and, for a disagreement, ` — PROP-074, TEST-037, TEST-038, TEST-039, TEST-044, TEST-219, TEST-230, TEST-294
- [~] `SPEC-ORC-020` (10-lp-oracle.md:222) **Second-source agreement.** For token *i* with quote `q_i` and second-source value `s_i` (8-decimal USD per w — PROP-026, PROP-100, TEST-037, TEST-039, TEST-219, TEST-250, TEST-276, TEST-294
- [~] `SPEC-ORC-021` (10-lp-oracle.md:223) **Sequencer gate.** On a chain whose `sequencer.feed ≠ address(0)`, read `(answer, startedAt)` from its `lates — TEST-037, TEST-275, TEST-276
- [~] `SPEC-ORC-022` (10-lp-oracle.md:224) **Observation buffer per chain.** For a consistency check over window `W` on a pool that writes at most one ob — TEST-037, TEST-139, TEST-250, TEST-264, TEST-265
- [~] `SPEC-ORC-023` (10-lp-oracle.md:225) **Gas guard for external reads.** Each external read `k` of an evaluation (legs, previous-phase lookups, secon — TEST-037, TEST-038, TEST-042, TEST-219, TEST-275
- [~] `SPEC-ORC-009` (10-lp-oracle.md:239) **sqrtPriceX96 from two prices.** Inputs: prices `x0`, `x1` (8 decimals; uncapped `q0`, `q1` for the consisten — TEST-037, TEST-079, TEST-279
- [~] `SPEC-ORC-006` (10-lp-oracle.md:240) **Concentrated-liquidity composition.** For `u` units at the capped price vector `v`: `s_O = SPEC-ORC-009(v0,  — PROP-083, TEST-037, TEST-217, TEST-266, TEST-279
- [~] `SPEC-ORC-010` (10-lp-oracle.md:241) **Consistency check (TWAP).** `tickRef = TickMath.getTickAtSqrtRatio(s_ref)`, with `s_ref` from `SPEC-ORC-009` — TEST-079, TEST-264, TEST-265, TEST-279
- [ ] `REQ-ORACLE-014` (10-lp-oracle.md:242) The consistency check MUST read only the market's own pool stored at `initialize`, in the pool's token order,  — TEST-040 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-104` (10-lp-oracle.md:243) The concentrated-liquidity module MUST set reason `PRICE_CLAMPED` (Drifting) when `SPEC-ORC-009` clamped the s — TEST-040, TEST-279
- [~] `REQ-ORACLE-105` (10-lp-oracle.md:244) At listing and on every later `checkConfig`, on-chain, the concentrated-liquidity module's `listingChecks` MUS — TEST-139, TEST-264, TEST-279
- [ ] `REQ-ORACLE-016` (10-lp-oracle.md:286) LPOracle MUST report exactly one of four states with severity `Live (0) < Drifting (1) < Cached (2) < Expired  — PROP-100, TEST-006, TEST-039, TEST-042, TEST-219, TEST-276, TEST-294 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-017` (10-lp-oracle.md:287) The market MUST be failed when any token has no valid route; when the configuration read `getOracleInputs` fai — PROP-074, TEST-006, TEST-039, TEST-040, TEST-042, TEST-105, TEST-219, TEST-231, TEST-250, TEST-294
- [~] `SPEC-ORC-013` (10-lp-oracle.md:288) **Failure start ("first failed read").** For a route that is `Stale`: `staleFrom_r = min over its Stale legs o — PROP-074, TEST-039, TEST-040, TEST-042, TEST-105, TEST-219, TEST-231, TEST-276, TEST-294
- [ ] `REQ-ORACLE-018` (10-lp-oracle.md:289) A market that is not failed MUST be Drifting if any of these holds: a token's routes disagree (`REQ-ORACLE-008 — TEST-006, TEST-039, TEST-040 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-019` (10-lp-oracle.md:290) A market whose tokens use their alternate routes MUST be Live when no Drifting condition holds; using the alte — TEST-040, TEST-231, TEST-276
- [~] `REQ-ORACLE-020` (10-lp-oracle.md:291) `latestAnswer()` MUST return the served price (`SPEC-ORC-017`): the fresh price when Live and when Drifting wi — PROP-074, TEST-038, TEST-039, TEST-219, TEST-230
- [~] `REQ-ORACLE-021` (10-lp-oracle.md:292) Freshness MUST be exposed separately from the price: the served price keeps its original source timestamp (`se — TEST-038, TEST-040, TEST-105, TEST-219, TEST-230
- [~] `REQ-ORACLE-099` (10-lp-oracle.md:347) Preserves: no borrowing on prices nobody could react to; liquidation never stops for a broken uptime feed. On  — TEST-037, TEST-219, TEST-250, TEST-275, TEST-276
- [~] `REQ-ORACLE-100` (10-lp-oracle.md:348) Preserves: no borrowing on a single network's frozen price. For every token, LPOracle MUST evaluate the second — PROP-100, TEST-038, TEST-040, TEST-042, TEST-105, TEST-157, TEST-219, TEST-250, TEST-276, TEST-294
- [ ] `REQ-ORACLE-101` (10-lp-oracle.md:349) Preserves: an oracle switch never stops liquidation. A market's LPOracle proxy address MUST stay the Aave pric — TEST-062 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-102` (10-lp-oracle.md:350) Preserves: no caller can make a healthy feed look failed. Every external read of the LPOracle and the DebtOrac — TEST-038, TEST-042, TEST-219, TEST-276
- [ ] `REQ-ORACLE-107` (10-lp-oracle.md:351) Preserves: no borrowing or seizure at a valuation built on token decimals the token no longer reports. `initia — PROP-100, TEST-042, TEST-062, TEST-276, TEST-294 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-022` (10-lp-oracle.md:365) The disagreement pause MUST be reported active iff some token disagrees (`REQ-ORACLE-008`) and `now < disagree — PROP-049, TEST-040, TEST-044, TEST-105, TEST-157, TEST-159, TEST-219
- [~] `REQ-ORACLE-023` (10-lp-oracle.md:366) `disagreementPauseMax` MUST stay within its bound in [1.5](../01-architecture/05-parameters.md); LPOracle read — TEST-159, TEST-219
- [~] `SPEC-ORC-016` (10-lp-oracle.md:367) **Pause and expiry windows.** With `D` = "some token disagrees" and `s = disagreeSince ≠ 0 ? disagreeSince : n — PROP-049, TEST-044, TEST-105, TEST-157, TEST-159, TEST-219, TEST-250
- [~] `REQ-ORACLE-094` (10-lp-oracle.md:371) LPOracle MUST read, on every evaluation, each token's routes in force (`MarketRegistry.activePriceRoutes(token — TEST-040, TEST-219, TEST-231, TEST-250
- [~] `REQ-ORACLE-095` (10-lp-oracle.md:372) When some token's `priceRouteVersion` differs from `routeVersion[i]`, the evaluation MUST treat `disagreeSince — PROP-049, TEST-231, TEST-252, TEST-294
- [~] `REQ-ORACLE-024` (10-lp-oracle.md:376) `poke()` MUST revert with `InsufficientGas(gasleft(), pokeMinGas)` when `gasleft() < pokeMinGas` at entry, bef — TEST-042, TEST-062, TEST-159
- [~] `REQ-ORACLE-025` (10-lp-oracle.md:377) `poke()` MUST be permissionless, MUST NOT take the Avana lock, and MUST make only static calls (to legs and th — TEST-105
- [ ] `REQ-ORACLE-026` (10-lp-oracle.md:378) `poke()` MUST evaluate the market with the same code and in the same block as `getPriceState()`, except that i — TEST-042 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-027` (10-lp-oracle.md:379) If the market is failed and `failedSince == 0`, `poke()` MUST set `failedSince = min(S_ts, now)` (`SPEC-ORC-01 — PROP-049, PROP-074, TEST-040, TEST-042, TEST-219, TEST-231, TEST-294
- [~] `REQ-ORACLE-028` (10-lp-oracle.md:380) If some token disagrees and `disagreeSince == 0`, `poke()` MUST set `disagreeSince = now`; if no token disagre — PROP-049, TEST-042, TEST-159, TEST-219, TEST-294
- [~] `REQ-ORACLE-029` (10-lp-oracle.md:381) `poke()` MUST store `accepted = {price8, min_i t_i, v}` only when the state is Live and `min_i t_i > accepted. — TEST-042, TEST-105, TEST-219, TEST-231, TEST-276
- [~] `REQ-ORACLE-030` (10-lp-oracle.md:382) `poke()` MUST set `expiredLatched = true` only when the source timestamps show Expired: some failed token has  — TEST-042, TEST-219, TEST-294
- [~] `REQ-ORACLE-031` (10-lp-oracle.md:383) `poke()` MUST record, for every leg whose read returned decodable data (valid, `Stale` or `Invalid`), its aggr — TEST-042, TEST-219
- [~] `SPEC-ORC-014` (10-lp-oracle.md:384) **Recovery evidence from source timestamps.** Evaluated by `poke()` for each token *i* when the market is not  — TEST-042, TEST-219, TEST-220, TEST-231
- [~] `REQ-ORACLE-032` (10-lp-oracle.md:385) When the market is not failed, `poke()` MUST start a grace window if `expiredLatched` is true or `SPEC-ORC-014 — TEST-042, TEST-219, TEST-231, TEST-252, TEST-294
- [~] `REQ-ORACLE-033` (10-lp-oracle.md:386) Each outage MUST start at most one grace window: an interval ending at or before the stored `recoveredAt` neve — TEST-042, TEST-219
- [~] `REQ-ORACLE-034` (10-lp-oracle.md:387) `inGrace` MUST be reported true iff (`recoveredAt ≠ 0` and `recoveredAt ≤ now < recoveredAt + graceDuration`)  — TEST-042, TEST-105, TEST-219, TEST-276
- [~] `REQ-ORACLE-035` (10-lp-oracle.md:388) `poke()` MUST emit `PriceStateChanged` when the state differs from `lastState`, `RouteChanged` when a token's  — TEST-042, TEST-219, TEST-231
- [ ] `REQ-ORACLE-036` (10-lp-oracle.md:389) The callers that act on LPOracle state MUST call `poke()` on each LPOracle they rely on before reading it, so  — TEST-159 (only excluded checks: uses a stand-in for ClPricing)
- [ ] `REQ-ORACLE-037` (10-lp-oracle.md:390) Keepers MUST call `poke()` on every market's LPOracle and every DebtOracle at least once per `CHECKPOINT_INTER — TEST-294 (only excluded checks: uses a stand-in for ClPricing)
- [x] `REQ-ORACLE-038` (10-lp-oracle.md:391) `setPokeMinGas(g)` MUST revert with `PokeMinGasOutOfBounds` unless `POKE_MIN_GAS_FLOOR ≤ g ≤ POKE_MIN_GAS_CEIL — PROP-034, TEST-042, TEST-062, TEST-231 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_034_setPokeMinGasNeedsApplicationAdmin
- [ ] `REQ-ORACLE-088` (10-lp-oracle.md:392) `priceCheckpoint()` MUST return `(checkpoint.price8, checkpoint.at)`. `initialize` MUST set the checkpoint to  — TEST-042 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-089` (10-lp-oracle.md:393) When a leg's current round is the first of a new aggregator phase (`uint64(roundId) == 1`), the recovery-evide — TEST-042, TEST-220
- [~] `REQ-ORACLE-039` (10-lp-oracle.md:397) In any read path (views and `poke()`), LPOracle MUST make every external read with the explicit gas and the pr — TEST-038, TEST-042, TEST-219, TEST-276, TEST-294
- [~] `REQ-ORACLE-040` (10-lp-oracle.md:398) `decimals()` MUST return 8 for the life of the proxy, matching Aave's 8-decimal USD format, and `description() — TEST-036, TEST-062
- [~] `REQ-ORACLE-041` (10-lp-oracle.md:399) `latestRoundData()` MUST return `answer = served`, `updatedAt = startedAt = servedUpdatedAt` (the oldest input — TEST-036, TEST-038, TEST-105, TEST-219, TEST-230
- [~] `REQ-ORACLE-042` (10-lp-oracle.md:400) `getPriceState()` MUST return a `PriceStateView` computed by the same code as `latestAnswer()` in the same blo — TEST-037, TEST-038, TEST-039, TEST-040, TEST-042, TEST-105, TEST-219, TEST-251, TEST-276
- [~] `REQ-ORACLE-043` (10-lp-oracle.md:401) `borrowPriceMaxAge()` and `liquidationPriceMaxAge()` MUST return the `SPEC-ORC-015` values; LPOracle does not  — TEST-040, TEST-219, TEST-250, TEST-276
- [~] `REQ-ORACLE-090` (10-lp-oracle.md:402) While a token's route in use is its alternate, LPOracle MUST hold every leg of that alternate to its `borrowPr — TEST-037, TEST-105, TEST-219, TEST-247, TEST-250, TEST-276
- [ ] `REQ-ORACLE-044` (10-lp-oracle.md:403) `getTokenPrices()` MUST return `(v, servedUpdatedAt, state)`: the capped valuation price vector of the fresh e — TEST-038, TEST-219 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-045` (10-lp-oracle.md:404) Every view MUST return the same result for every caller in the same block; no output depends on `msg.sender`,  — TEST-062
- [ ] `REQ-ORACLE-046` (10-lp-oracle.md:410) `checkConfig` MUST check, on-chain, every rule from `REQ-ORACLE-047` to `REQ-ORACLE-056` and `REQ-ORACLE-105`  — TEST-219, TEST-250, TEST-294 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-047` (10-lp-oracle.md:411) On-chain: `2 ≤ n ≤ MAX_POOL_TOKENS` and the vault-token decimals `d` MUST be the value of `SPEC-ORC-005` at th — TEST-036, TEST-062, TEST-139, TEST-219
- [ ] `REQ-ORACLE-048` (10-lp-oracle.md:412) On-chain: token order and decimals MUST be read from the pool and tokens, never from the listing name, and sto — TEST-219 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-049` (10-lp-oracle.md:413) On-chain: for every leg, the pinned `decimals` MUST equal `decimals()` read at listing; the pinned `minAnswer` — TEST-070, TEST-219, TEST-250
- [ ] `REQ-ORACLE-050` (10-lp-oracle.md:414) On-chain: with every price moved by `LISTING_SHOCK_FACTOR = 100` in each direction (each token up with the oth — TEST-219 (only excluded checks: uses a stand-in for ClPricing)
- [ ] `REQ-ORACLE-051` (10-lp-oracle.md:415) On-chain: a token's primary and alternate routes MUST share no aggregator; no two tokens' alternate routes MUS — TEST-219 (only excluded checks: uses a stand-in for ClPricing)
- [ ] `REQ-ORACLE-052` (10-lp-oracle.md:416) Off-chain: each primary MUST be the token's direct `TOKEN/USD` Chainlink feed through its standard Chainlink p — checked outside contracts/: an off-chain listing rule: which Chainlink proxy is each token's primary and that no alternate route assumes a peg are reviewed in the listing package (3.8); checkConfig's on-chain route rules are REQ-ORACLE-046 to REQ-ORACLE-051 (TEST-219)
- [~] `REQ-ORACLE-053` (10-lp-oracle.md:417) On-chain: `feedAgreementToleranceBps[i]` MUST be at least the sum of the `feedDeviationThresholdBps` of every  — TEST-219, TEST-250
- [~] `REQ-ORACLE-054` (10-lp-oracle.md:418) On-chain, in the MarketRegistry's route checks ([2.8](08-market-registry.md)) and the ParameterStore's `setFee — TEST-219, TEST-250, TEST-276
- [~] `REQ-ORACLE-055` (10-lp-oracle.md:419) On-chain: `twapWindow > 0` and `twapToleranceTicks ≥ twapToleranceMinTicks` (10 ticks; the launch τ of 50 tick — TEST-139
- [ ] `REQ-ORACLE-056` (10-lp-oracle.md:420) On-chain: for a market whose tokens are all USD-pegged stables, `usdBandLow < 10^8 < usdBandHigh` (8-decimal l — TEST-036, TEST-219 (only excluded checks: uses a stand-in for ClPricing)
- [ ] `REQ-ORACLE-057` (10-lp-oracle.md:421) Off-chain: listing MUST show `(1 − CF)` larger than the feed deviation threshold plus heartbeat drift, minimum — checked outside contracts/: an off-chain listing rule: the (1 - CF) margin study, the per-pool manipulation-cost study and each second source's stress history are evidence in the listing package (3.8)
- [~] `REQ-ORACLE-058` (10-lp-oracle.md:422) `initialize` MUST run once, in the same transaction as the proxy deployment, which Avana operators make before — TEST-062, TEST-219, TEST-242, TEST-294
- [~] `REQ-ORACLE-059` (10-lp-oracle.md:423) `initialize` MUST revert unless the evaluation of the configuration in its arguments is Live (the pipeline of  — TEST-036, TEST-042, TEST-062, TEST-231
- [~] `REQ-ORACLE-060` (10-lp-oracle.md:480) LPOracle MUST NOT return a value ≤ 0 from `latestAnswer()` or `latestRoundData()` in any state, including Expi — PROP-074, TEST-036, TEST-038, TEST-219, TEST-230
- [~] `REQ-ORACLE-061` (10-lp-oracle.md:481) `latestAnswer()`, `latestRoundData()`, `decimals()`, `description()`, `getPriceState()`, `getTokenPrices()`, ` — TEST-036, TEST-038, TEST-040, TEST-070, TEST-105, TEST-219
- [~] `REQ-ORACLE-062` (10-lp-oracle.md:482) LPOracle MUST NOT have any function that sets, overrides or extends the accepted price, its timestamp, `failed — TEST-062
- [ ] `REQ-ORACLE-063` (10-lp-oracle.md:483) The valuation and state paths MUST NOT read a pool's spot price or spot balances for valuation (`slot0`, `bala — TEST-266 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-064` (10-lp-oracle.md:484) LPOracle MUST NOT hold or receive tokens or ETH (no `payable` function, no `receive`), grant approvals, or mak — TEST-062
- [~] `REQ-ORACLE-065` (10-lp-oracle.md:485) LPOracle MUST NOT set `expiredLatched` or `recoveredAt` from a caught error, a failed configuration read, a ga — TEST-042, TEST-219, TEST-231, TEST-252
- [~] `REQ-ORACLE-066` (10-lp-oracle.md:486) LPOracle MUST NOT refresh `accepted.updatedAt` or `servedUpdatedAt` by reading, caching or re-serving the same — TEST-038, TEST-040, TEST-042, TEST-105, TEST-219
- [ ] `REQ-ORACLE-082` (10-lp-oracle.md:487) The `poke()` selector, its empty argument list and its `PriceState` return MUST stay unchanged across upgrades — TEST-062 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-083` (10-lp-oracle.md:488) LPOracle MUST apply the `feedAgreementToleranceBps`, second-source tolerances and `twapToleranceTicks` returne — TEST-040, TEST-219, TEST-250
- [~] `REQ-ORACLE-084` (10-lp-oracle.md:489) When some token still disagrees after `disagreementPauseMax` (`SPEC-ORC-016` `disagreementExpired`), LPOracle  — PROP-049, TEST-105, TEST-157, TEST-219, TEST-231
- [x] `REQ-ORACLE-097` (10-lp-oracle.md:490) The LPOracle and every DebtOracle MUST override `_grantRole` to revert `AdminRoleOnlyTimelock(role, account)`  — PROP-070, TEST-062, TEST-242 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_070_adminRolesOnlyTimelock
- [~] `REQ-ORACLE-067` (10-lp-oracle.md:496) A token's primary leg reverts, returns malformed data, a wrong `decimals()`, an answer at or beyond its pinned — TEST-038, TEST-040, TEST-219, TEST-231
- [~] `REQ-ORACLE-068` (10-lp-oracle.md:497) Both routes of a token are invalid (Source: Q-079, Q-183) | Fallback: serve the accepted price with its origin — TEST-040, TEST-105, TEST-219, TEST-231
- [~] `REQ-ORACLE-069` (10-lp-oracle.md:498) The configuration read `getOracleInputs` fails (including a failed MarketRegistry route read inside it) or is  — TEST-040, TEST-219
- [~] `REQ-ORACLE-070` (10-lp-oracle.md:499) Both routes valid and outside `T_i` (Source: Q-112, Q-162, Q-208) | Pause: Drifting; this market's seizure pau — TEST-044, TEST-219
- [ ] `REQ-ORACLE-071` (10-lp-oracle.md:500) The consistency read fails, or the consistency check fails (concentrated liquidity: `|meanTick − tickRef| > τ` — TEST-040 (only excluded checks: uses a stand-in for ClPricing)
- [ ] `REQ-ORACLE-072` (10-lp-oracle.md:501) `num ≥ 2^64 · den` or `s < MIN_SQRT_RATIO` in `SPEC-ORC-009`, or the oracle ratio lies outside the market's ra — TEST-040 (only excluded checks: uses a stand-in for ClPricing)
- [ ] `REQ-ORACLE-073` (10-lp-oracle.md:502) `⊗ q_i < usdBandLow^⊗n` or `⊗ v_i > usdBandHigh^⊗n` (`SPEC-ORC-011`) (Source: Q-176, Q-195, Q-275, Q-329) | Dr — TEST-043, TEST-251 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-074` (10-lp-oracle.md:503) `gasleft() < pokeMinGas` at `poke()` entry, or below the pre-call bound of `SPEC-ORC-023` before any read (Sou — TEST-042
- [~] `REQ-ORACLE-075` (10-lp-oracle.md:504) `getRoundData(roundId − 1)` reverts or returns unusable data during `SPEC-ORC-014`, or, on the first round of  — TEST-042, TEST-219, TEST-220
- [~] `REQ-ORACLE-076` (10-lp-oracle.md:505) `checkConfig` non-zero or evaluation not Live at `initialize` (Source: Q-128, Q-191) | `initialize` reverts wi — TEST-062, TEST-231
- [ ] `REQ-ORACLE-077` (10-lp-oracle.md:506) A new oracle configuration fails `checkConfig` (Source: Q-184, Q-191) | The ParameterStore or MarketRegistry r — TEST-219, TEST-250 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-078` (10-lp-oracle.md:510) LPOracle MUST be deployed behind an ERC-1967 proxy using the UUPS pattern, whose `_authorizeUpgrade` requires  — TEST-062
- [~] `REQ-ORACLE-079` (10-lp-oracle.md:511) New price sources (any new aggregator, route composition, second source, sequencer feed or consistency pool) a — TEST-040, TEST-063
- [~] `REQ-ORACLE-080` (10-lp-oracle.md:512) Implementations MUST use ERC-7201 storage, call `_disableInitializers()` in their constructor, run any `reinit — TEST-062, TEST-242
- [ ] `REQ-ORACLE-106` (10-lp-oracle.md:513) Each AMM protocol's LPOracle implementation MUST be a proxy target holding the roles, the upgrade, `setPokeMin — TEST-038, TEST-062 (only excluded checks: uses a stand-in for ClPricing)
- [~] `REQ-ORACLE-081` (10-lp-oracle.md:514) After every upgrade, `decimals()` MUST return 8 and `latestAnswer()` MUST be ≥ 1 in the same transaction (chec — TEST-062
- [~] `REQ-ORACLE-091` (10-lp-oracle.md:576) Preserves: always a price; the price source cannot be swapped without the Aave DAO. Each non-GHO debt asset MU — TEST-062, TEST-219, TEST-231, TEST-242
- [~] `REQ-ORACLE-092` (10-lp-oracle.md:577) Preserves: S; always a price. The DebtOracle MUST evaluate its asset with the LPOracle's rules applied to one  — PROP-074, TEST-042, TEST-105, TEST-219, TEST-220, TEST-230, TEST-231, TEST-275, TEST-276
- [x] `REQ-ORACLE-093` (10-lp-oracle.md:578) Preserves: S; no repayment or seizure at a stress price; always a price. `latestAnswer()` and the `answer` of  — PROP-074, TEST-105, TEST-219, TEST-230, TEST-276 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_074_servedDebtPriceAgainstFixedAlternate
- [x] `SPEC-ORC-018` (10-lp-oracle.md:579) **Served debt price by state.** Let `A = accepted.price8`, `q` the fresh quote (`REQ-ORACLE-005`), `p` and `b` — PROP-074, TEST-037, TEST-070, TEST-105, TEST-219, TEST-230, TEST-247 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_074_servedDebtPriceAgainstFixedAlternate
- [~] `REQ-ORACLE-096` (10-lp-oracle.md:580) The callers that act on a DebtOracle's state MUST call its `poke()` before reading it, so the first observatio — TEST-163
- [x] `REQ-ORACLE-098` (10-lp-oracle.md:581) Preserves: always a price; no role can choose a price. The DebtOracle MUST make only static calls (to its legs — PROP-034, TEST-062, TEST-231 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_034_setPokeMinGasNeedsApplicationAdmin
- [~] `REQ-AMM-V3-001` (20-uniswap-v3-integration.md:46) The Uniswap v3 LPVault MUST take `NFPM` and `FACTORY` from its constructor and revert deployment with `Invalid — TEST-108, TEST-264
- [~] `REQ-AMM-V3-002` (20-uniswap-v3-integration.md:47) `bindMarket(marketId, pool, bytes32(0), PositionShape(TickRange, tickLower, tickUpper), integrationData)` MUST — TEST-264
- [~] `REQ-AMM-V3-003` (20-uniswap-v3-integration.md:48) Every read of `pool.slot0()` MUST decode the Uniswap v3 layout of 7 fields, `(uint160 sqrtPriceX96, int24 tick — TEST-011
- [~] `REQ-AMM-V3-004` (20-uniswap-v3-integration.md:49) The Uniswap v3 LPVault MUST make every state-changing NFPM call on pledged NFTs (`transferFrom`, `decreaseLiqu — TEST-021
- [~] `REQ-AMM-V3-005` (20-uniswap-v3-integration.md:50) `composition` MUST follow `SPEC-AMM-V3-001` and read no pool state: the price input is the oracle price vector — TEST-217, TEST-279
- [~] `REQ-AMM-V3-006` (20-uniswap-v3-integration.md:51) `riskMetadata(marketId, positionKey)` MUST report `inRange` as `tickLower ≤ slot0().tick < tickUpper`, `readSa — TEST-264, TEST-279
- [~] `REQ-AMM-V3-007` (20-uniswap-v3-integration.md:52) The Uniswap v3 liquidity bound MUST hold for every market: credited liquidity on one range is at most `maxLiqu — TEST-279
- [ ] `REQ-AMM-V3-012` (20-uniswap-v3-integration.md:53) The Uniswap v3 LPVault MUST take the chain's minimum block interval `BLOCK_TIME` (seconds) from its constructo
- [~] `REQ-VAULT-147` (20-uniswap-v3-integration.md:57) The Uniswap v3 `receivePosition(marketId, owner, positionKey)`, with `tokenId = uint256(positionKey)`, MUST ru — PROP-083, TEST-010, TEST-011, TEST-116, TEST-265
- [~] `REQ-VAULT-148` (20-uniswap-v3-integration.md:58) The Uniswap v3 `returnPosition(positionKey)` MUST revert with `NotCollateralization`, `LockNotHeld` or `NotInC — TEST-016
- [~] `REQ-VAULT-149` (20-uniswap-v3-integration.md:59) The Uniswap v3 `unwind(positionKey, units, minAmounts, recipient)` MUST pass the checks of `REQ-AMM-CORE-008`  — TEST-058, TEST-116, TEST-265
- [~] `REQ-VAULT-161` (20-uniswap-v3-integration.md:60) The Uniswap v3 `releaseToDepositor(positionKey, units, minAmounts)` MUST pass the checks of `REQ-AMM-CORE-008` — TEST-237
- [~] `REQ-VAULT-162` (20-uniswap-v3-integration.md:61) The Uniswap v3 `unitsOf(positionKey)` MUST revert with `NotInCustody` without a custody entry and otherwise re — TEST-016, TEST-222, TEST-291
- [~] `REQ-VAULT-065` (20-uniswap-v3-integration.md:62) The Uniswap v3 `collectFees(positionKey, depositor)` MUST require `depositor == depositorOf(positionKey)` (`No — TEST-017, TEST-091
- [~] `REQ-VAULT-008` (20-uniswap-v3-integration.md:66) The Uniswap v3 `receivePosition` MUST read `(token0, token1, fee, tickLower, tickUpper)` from `NFPM.positions( — PROP-083, TEST-011
- [~] `REQ-VAULT-009` (20-uniswap-v3-integration.md:67) The Uniswap v3 `receivePosition` MUST revert with `RangeMismatch(tickLower, tickUpper)` unless `tickLower == m — PROP-083, TEST-011
- [~] `REQ-VAULT-011` (20-uniswap-v3-integration.md:68) The borrower MUST grant the per-token `NFPM.approve(LPVault, tokenId)` or an NFPM `permit` before a pledge; ap — TEST-010
- [~] `REQ-VAULT-057` (20-uniswap-v3-integration.md:72) For each record debited for a seizure with debit `take > 0`, the Uniswap v3 removal MUST call `NFPM.decreaseLi — TEST-058
- [~] `REQ-VAULT-058` (20-uniswap-v3-integration.md:73) Immediately after the `decreaseLiquidity`, the LPVault MUST call `NFPM.collect({tokenId, recipient, amount0Max — TEST-058, TEST-091, TEST-177
- [~] `REQ-VAULT-078` (20-uniswap-v3-integration.md:77) `onERC721Received` MUST revert with `UnsupportedNft` unless `msg.sender == NFPM`; for the canonical NFPM it MU — TEST-015
- [~] `REQ-VAULT-079` (20-uniswap-v3-integration.md:78) A stray NFT is a canonical-NFPM token with `NFPM.ownerOf(tokenId) == address(this)` and no custody entry for i — TEST-015
- [~] `REQ-VAULT-080` (20-uniswap-v3-integration.md:79) The Uniswap v3 `returnStray(bytes32(tokenId), recipient)` MUST pass the checks of [2.2](02-lp-vault.md) `REQ-V — TEST-015
- [~] `SPEC-BACK-001` (20-uniswap-v3-integration.md:85) **Exact range check.** With `s = pool.tickSpacing()`, `MIN_TICK = −887272`, `MAX_TICK = 887272`, and `%` the s — TEST-264, TEST-265, TEST-279
- [~] `SPEC-BACK-008` (20-uniswap-v3-integration.md:86) **Principal-capped collect** (executed by `unwind` and `releaseToDepositor`). `(a0, a1) = NFPM.decreaseLiquidi — TEST-058, TEST-074, TEST-091, TEST-116, TEST-177, TEST-237, TEST-265
- [~] `SPEC-AMM-V3-001` (20-uniswap-v3-integration.md:87) **Composition at the clamped oracle price.** The floored amounts here are exactly those of [2.10](10-lp-oracle — PROP-083, TEST-037, TEST-217, TEST-266, TEST-279
- [~] `REQ-VAULT-124` (20-uniswap-v3-integration.md:106) `onERC721Received` from any contract other than `NFPM` | Reverts with `UnsupportedNft` (Source: Q-144) — TEST-015, TEST-265
- [~] `REQ-AMM-V3-008` (20-uniswap-v3-integration.md:107) `bindMarket` for a pool not deployed by `FACTORY` with the canonical init code, a non-standard tick spacing, o — TEST-264
- [~] `REQ-AMM-V3-009` (20-uniswap-v3-integration.md:108) A pledged NFT's derived pool or ticks differ from the market's | The LPVault reverts with `PoolMismatch` or `R — TEST-011
- [~] `REQ-AMM-V3-010` (20-uniswap-v3-integration.md:109) `slot0().unlocked == false` during custody, removal or a live-liquidity read under the Lock | Reverts with `Po — TEST-011, TEST-058
- [~] `REQ-AMM-V3-011` (20-uniswap-v3-integration.md:110) The NFPM's `decreaseLiquidity` in `releaseToDepositor` returns less than a minimum | The NFPM's `Price slippag — TEST-237

## TEST rows (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## PROP rows (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## INV (2: 1 verified, 0 failed, 1 not run, 0 unlinked)

- [~] `INV-030` `LPVaultSwap.liquidate`, the only liquidation entry point (`INV-062`), admits any caller that is not a frozen  — PROP-022, PROP-066, TEST-049, TEST-055, TEST-160, TEST-174
- [x] `INV-087` Stress valuation is monotone and never prices a seizure or repayment. A market's LPOracle serves (`SPEC-ORC-01 — PROP-074, TEST-037, TEST-044, TEST-105, TEST-219, TEST-230 — test/halmos/DebtOracle.halmos.t.sol:DebtOracleHalmosTest.check_PROP_074_servedDebtPriceAgainstFixedAlternate

## ATTACK (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## Cross-cutting TEST rows, every contract (17): see --uncovered

- `TEST-001` [environment] The Foundry workspace builds with solc 0.8.28 and EVM `cancun`, the same compiler as Aave V4; dependencies are
- `TEST-032` [access-control] Selector inventory: the external selectors of every deployed Avana contract are enumerated from bytecode and c
- `TEST-061` [unit] Events: every borrower and keeper action is one atomic call that emits the inventory events of its contracts, 
- `TEST-177` [unit] Zero-amount transfers skipped: with mock tokens that revert on a zero-amount `transfer` and `transferFrom`, ev
- `TEST-062` [access-control] Role map: every privileged selector of every Avana contract checks the role or the `TIMELOCK` address in the r
- `TEST-066` [access-control] Guardian powers: the Emergency Guardian (3-of-5) and the Aave Protocol Guardian hold `APPLICATION_PAUSE_GUARDI
- `TEST-080` [fuzz] Dust donations: sending 1 wei up to 10^6 wei of GHO, USDC, WETH, DAI, pool tokens or vault tokens (where the r
- `TEST-092` [invariant] Conservation: for every token (each debt asset, each pool token, each vault token), the sum of tracked balance
- `TEST-107` [invariant] Hostile suite: with the RiskModule, MarketRegistry, ParameterStore, LPOracle and LPVaultSwap replaced through 
- `TEST-108` [invariant] Structure and governance: immutables and runtime code hashes of the LPVault, Collateralization, vault tokens, 
- `TEST-212` [invariant] Timelock timing: handlers schedule normal, short and mixed batches (short-listed and normal calls in one batch
- `TEST-121` [fork] End-to-end lifecycle on one fork (Avana-deployed Aave V4 plus Ethereum Uniswap v3, Chainlink, GHO, the Aave V3
- `TEST-126` [fork] Emergency matrix: for every row of the matrix in [3.6](../03-operations/06-emergency-operations.md) (applicati
- `TEST-127` [fork] Halt deterioration and caps: with liquidation of an account stopped for the 48-hour incident window of `Q-192`
- `TEST-137` [deployment-check] Upgrade safety: every UUPS contract (AaveAdapter, MarketRegistry, ParameterStore, RiskModule, LPOracle, LPVaul
- `TEST-214` [deployment-check] Role snapshot: on every upgradeable Avana contract `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` are held only 
- `TEST-224` [deployment-check] Deployment simulation: `forge script` on the Ethereum fork and on the Base fork runs the chain's full deployme
