# Checklist: ParameterStore

Spec pages: 09-parameter-store.md. CVL specs: ParameterStore.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (62: 0 verified, 0 failed, 60 not run, 2 unlinked)

- [~] `REQ-PSTORE-001` (09-parameter-store.md:182) The ParameterStore of each chain MUST sit behind one fixed ERC-1967 proxy address using the UUPS pattern, whos — TEST-062, TEST-133, TEST-242
- [~] `REQ-PSTORE-002` (09-parameter-store.md:183) Every setter MUST require `APPLICATION_ADMIN`, so every value is the value an executed timelock operation set, — TEST-062, TEST-063, TEST-066, TEST-225, TEST-242
- [~] `REQ-PSTORE-003` (09-parameter-store.md:184) The blast radius of a faulty or hostile ParameterStore implementation is: it can return any value its code cho — TEST-062, TEST-133
- [~] `REQ-CONFIG-049` (09-parameter-store.md:188) Each parameter's change class MUST match [1.5](../01-architecture/05-parameters.md), with these directions: `h — TEST-061, TEST-064
- [~] `REQ-CONFIG-050` (09-parameter-store.md:189) Every setter MUST enforce the hard-coded minimum and maximum of the ParameterStore implementation, which equal — PROP-042, TEST-061, TEST-062, TEST-064, TEST-225, TEST-230, TEST-242, TEST-246, TEST-249, TEST-250, TEST-273
- [~] `REQ-CONFIG-051` (09-parameter-store.md:190) A two-direction parameter MUST have separate tighten and loosen (or structural) setters; the tighten setter MU — PROP-042, TEST-062, TEST-063, TEST-064, TEST-225, TEST-250
- [~] `REQ-CONFIG-052` (09-parameter-store.md:191) Liquidation-liveness bounds: no setter MAY take `slippageAllowanceBps` below `slippageAllowanceMinBps` (per ma — PROP-042, TEST-061, TEST-062, TEST-064, TEST-225, TEST-242, TEST-245, TEST-250
- [~] `REQ-CONFIG-053` (09-parameter-store.md:192) Loosen setters MUST run only through the timelock at the normal delay, cancellable by any `CANCELLER_ROLE` hol — TEST-061, TEST-062, TEST-063, TEST-225
- [~] `REQ-CONFIG-054` (09-parameter-store.md:193) Structural setters MUST run only through the timelock at the normal delay; new price sources and any change to — TEST-061, TEST-062, TEST-063, TEST-064, TEST-225, TEST-250
- [~] `REQ-CONFIG-055` (09-parameter-store.md:194) Setting `usdBandLow`/`usdBandHigh` MUST require `usdBandLow < 10^8 < usdBandHigh` (8-decimal USD levels per 1  — TEST-061, TEST-064, TEST-242
- [~] `REQ-CONFIG-057` (09-parameter-store.md:195) No temporary override of any parameter exists: the LPOracle applies the stored `feedAgreementToleranceBps` and — TEST-062, TEST-278
- [~] `REQ-CONFIG-058` (09-parameter-store.md:196) No account MAY set, restore or override a parameter outside a timelock operation, except the Joint Configurati — TEST-062, TEST-066, TEST-225
- [~] `REQ-CONFIG-071` (09-parameter-store.md:197) Each parameter MUST have one stored value, the value the last executed timelock operation or risk-steward call — TEST-063, TEST-225
- [~] `REQ-PSTORE-004` (09-parameter-store.md:201) `setInitialMarketParams(marketId, params)` MUST revert with `NotInListing` unless the MarketRegistry has the m — TEST-061, TEST-064, TEST-250, TEST-272
- [~] `REQ-CONFIG-015` (09-parameter-store.md:202) `poolRiskFactor` per market MUST be stored in bps, > 0 and ≤ the launch ceiling bound in [1.5](../01-architect — PROP-042, TEST-062, TEST-064, TEST-250
- [~] `REQ-CONFIG-041` (09-parameter-store.md:203) `slippageAllowanceMinBps` for the market MUST be set at listing (`setInitialMarketParams`) to at least the lar — TEST-064, TEST-245, TEST-250
- [~] `REQ-PSTORE-005` (09-parameter-store.md:204) `minPledgeUsd` MUST be stored per market in 8-decimal USD within `[0, 100_000e8]` and launch at $10 (`10e8`) f — PROP-042, TEST-061, TEST-062, TEST-064, TEST-225, TEST-250
- [~] `REQ-RISK-041` (09-parameter-store.md:208) Initial `marketUsdCap`, `topUpSliceUsd`, `stressFloorUsd` (per market) and `tokenUsdCap(hub, token)` (per pool — TEST-225, TEST-250, TEST-272
- [~] `REQ-RISK-042` (09-parameter-store.md:209) Each cap MUST have a tighten setter that reverts with `NotStricter` unless the new value is strictly lower tha — PROP-042, TEST-062, TEST-225, TEST-242, TEST-272
- [~] `REQ-RISK-043` (09-parameter-store.md:210) Each cap MUST have a loosen setter that reverts with `NotLooser` unless the new value is strictly higher, exec — TEST-061, TEST-225, TEST-272
- [~] `REQ-RISK-044` (09-parameter-store.md:211) Every cap setter MUST enforce the hard-coded minimum and maximum of [1.5](../01-architecture/05-parameters.md) — PROP-042, TEST-064, TEST-225, TEST-272
- [~] `REQ-RISK-045` (09-parameter-store.md:212) `setStressFloorUsd` MUST run at the normal delay; it MAY lower the floor only if [SPEC-CAP-006](07-risk-module — TEST-225, TEST-272
- [~] `REQ-CONFIG-019` (09-parameter-store.md:216) Each pool token MUST carry `tokenCollateralFactorBps`, recorded with its source and written with `setTokenColl — TEST-061, TEST-064, TEST-250
- [~] `REQ-CONFIG-020` (09-parameter-store.md:217) A token with no Core Hub collateral factor, or one Avana must not inherit, MUST carry an explicit `tokenCollat — TEST-064, TEST-250
- [~] `REQ-CONFIG-022` (09-parameter-store.md:218) For every feed, `setFeed` MUST read `decimals` on-chain and pin it, and read `minAnswer` and `maxAnswer` on-ch — TEST-250
- [~] `REQ-CONFIG-023` (09-parameter-store.md:219) Each feed MUST carry its own published `heartbeat`, a freshness margin `heartbeatMargin`, `feedMaxAge`, `feedD — TEST-028, TEST-062, TEST-064, TEST-225, TEST-250
- [~] `REQ-CONFIG-024` (09-parameter-store.md:220) Feed-agreement tolerance lower bound: for each token, `feedAgreementToleranceBps ≥ max(dev(P) + dev(A), dev(S) — TEST-061, TEST-062, TEST-064, TEST-225, TEST-242, TEST-250
- [~] `REQ-PSTORE-009` (09-parameter-store.md:221) `setFeed` and every per-feed setter MUST revert with `OracleConfigRejected(lpOracle, failedChecks)` when the L — TEST-062, TEST-064, TEST-219, TEST-225, TEST-250, TEST-295
- [~] `REQ-PSTORE-006` (09-parameter-store.md:225) No buy-leg slippage parameter exists: the liquidation caller funds the debt asset itself (and `deleverage` fla — TEST-061, TEST-246
- [~] `REQ-PSTORE-007` (09-parameter-store.md:226) No buy-route depth threshold exists, for the reason in `REQ-PSTORE-006`; the depth a liquidation needs is the  — TEST-278
- [~] `REQ-PSTORE-015` (09-parameter-store.md:227) The lower side of liquidation liveness MUST be `slippageAllowanceMinBps(m)`, set per market to cover the real  — PROP-042, TEST-064, TEST-225, TEST-245
- [~] `REQ-PSTORE-021` (09-parameter-store.md:228) For every Active or Offboarding market `m` of a CDP Spoke and every enabled debt reserve `r` of that Spoke, li — TEST-225, TEST-245
- [~] `REQ-CONFIG-070` (09-parameter-store.md:229) Each swap-route slot `(marketId, token, debtAsset, kind)` ([2.12](12-settlement-routes.md) `REQ-ROUTE-006`; `k — PROP-042, TEST-061, TEST-062, TEST-064
- [~] `REQ-PSTORE-016` (09-parameter-store.md:233) The ParameterStore MUST hold the on-chain breaker values of `Q-399` in the table, within these bounds and chan — TEST-061, TEST-062, TEST-063, TEST-064, TEST-225, TEST-228, TEST-272, TEST-278
- [~] `REQ-PSTORE-030` (09-parameter-store.md:240) `gateRecoverySeconds` MUST be stored per chain in seconds within `[600, 7,200]`, launch 1,800 (30 minutes, a p — PROP-042, TEST-061, TEST-062, TEST-064, TEST-225, TEST-242
- [ ] `REQ-PSTORE-035` (09-parameter-store.md:244) The ParameterStore MUST hold the speed-limit parameters the RiskModule reads (2.7 `REQ-RISK-092`, `REQ-RISK-09
- [ ] `REQ-PSTORE-036` (09-parameter-store.md:254) `tightenMarketSpeedLimits(marketId, v)` and `tightenDebtSpeedLimit(hub, asset, v)` MUST take a full new value 
- [~] `REQ-PSTORE-023` (09-parameter-store.md:258) Each chain's ParameterStore MUST hold the chain's sequencer-uptime check `sequencer = SequencerConfig{feed, gr — TEST-062, TEST-242, TEST-250
- [~] `REQ-PSTORE-034` (09-parameter-store.md:259) On a chain with a sequencer (`HAS_SEQUENCER`), the ParameterStore MUST keep `sequencer.gracePeriod ≥ max(twapW — TEST-250
- [~] `REQ-PSTORE-024` (09-parameter-store.md:260) `maxFlashFeeBps` MUST be a chain parameter in bps within `[0, 100]`, launch 10 on Ethereum and on Base, lowere — PROP-042, TEST-052, TEST-062, TEST-064, TEST-225, TEST-242, TEST-245
- [~] `REQ-PSTORE-025` (09-parameter-store.md:261) The ParameterStore MUST hold no minimum debt: it stores no debt floor, has no setter or event for one, and no  — TEST-278
- [~] `REQ-PSTORE-026` (09-parameter-store.md:262) Hub-wide caps MUST be keyed by Hub: `tokenUsdCap(hub, token)` and `depositorUsdCap(hub)`. `setInitialHubCaps(h — PROP-042, TEST-062, TEST-225, TEST-242, TEST-272
- [~] `REQ-PSTORE-027` (09-parameter-store.md:263) `CHAIN_BLOCK_TIME` MUST be an implementation immutable equal to the chain's block time (12 s on Ethereum, 2 s  — TEST-062, TEST-250
- [~] `REQ-PSTORE-028` (09-parameter-store.md:264) Each pool token and each debt asset with a DebtOracle MUST carry `secondSource(token)`, the independent second — TEST-250
- [~] `REQ-PSTORE-029` (09-parameter-store.md:265) **Standby second source.** `setSecondSource(token, src, standby)` MUST apply every check of `REQ-PSTORE-028` t — TEST-062, TEST-066, TEST-133, TEST-219, TEST-250
- [~] `REQ-PSTORE-031` (09-parameter-store.md:266) `hardHealthFloor(marketId)` MUST be stored per market in WAD, 0 (off) by default and at launch, or within `[1e — PROP-042, TEST-062, TEST-064, TEST-225
- [~] `REQ-PSTORE-032` (09-parameter-store.md:267) `coverageRatioBps` MUST be stored per chain in bps within `[0, 10,000]`, set by `setCoverageRatioBps` at the n — TEST-064, TEST-273
- [~] `REQ-PSTORE-018` (09-parameter-store.md:271) `maxShortfallBps` MUST be stored in bps within `[0, 5,000]`, launch 1,000, lowered by `tightenMaxShortfallBps` — PROP-042, TEST-061, TEST-062, TEST-064, TEST-225, TEST-242
- [~] `REQ-PSTORE-019` (09-parameter-store.md:272) There MUST be no `inKindAutoDelay`: in-kind settlement and its automatic trigger are removed (`Q-401`), so the — TEST-278
- [~] `REQ-PSTORE-020` (09-parameter-store.md:273) `debtStressRiseBps(asset)` MUST be stored per debt asset that has a DebtOracle (every debt asset except one Aa — PROP-042, TEST-061, TEST-062, TEST-064, TEST-225, TEST-230, TEST-250
- [~] `REQ-PSTORE-017` (09-parameter-store.md:277) Each loosening of a step-limited parameter MUST move it at most one step and MUST execute at least `normalDela — TEST-061, TEST-063, TEST-064, TEST-225
- [~] `REQ-PSTORE-022` (09-parameter-store.md:278) Each approved CDP Spoke MUST carry `aaveTargetHealthFactor(spoke)` (WAD) and `minLiquidationBonus(spoke)` (bps — TEST-061, TEST-249, TEST-272
- [~] `REQ-PSTORE-008` (09-parameter-store.md:282) There MUST be no `inKindExpiry` and no `setInKindExpiry`: in-kind settlement is removed (`Q-401`). The PayoutE — TEST-278
- [~] `REQ-PSTORE-010` (09-parameter-store.md:283) `avanaFeeShareBps` MUST stay within `[0, 5,000]` with launch value 2,000 (a proposed default; final value set  — TEST-061, TEST-062, TEST-064, TEST-206, TEST-242
- [~] `REQ-CONFIG-056` (09-parameter-store.md:284) `feeRecipient` MUST NOT be the zero address, an Avana contract, any Hub or Spoke on the chain or a PositionPro — TEST-061, TEST-062, TEST-133, TEST-242
- [~] `REQ-CONFIG-072` (09-parameter-store.md:288) `getOracleConfig(lpOracle)` MUST return, for the market `MARKET_REGISTRY.marketOfLpOracle(lpOracle)`: `marketI — TEST-133, TEST-250
- [~] `REQ-PSTORE-033` (09-parameter-store.md:289) `getOracleInputs(lpOracle, tokens, withSecondSources)` MUST return the words of `OracleInputsLayout`, `10 + n  — TEST-250
- [~] `REQ-PSTORE-011` (09-parameter-store.md:290) Every view MUST be `view`, never revert for a listed market, token, feed or debt reserve, and return the value — TEST-062, TEST-064, TEST-133, TEST-250
- [~] `REQ-CONFIG-067` (09-parameter-store.md:296) A tighten value is not strictly safer, a loosen value not strictly looser, a value crosses a hard or liveness  — TEST-064, TEST-225
- [~] `REQ-PSTORE-012` (09-parameter-store.md:297) An initial setter targets a market that is not `Registered` or a token that already has a cap | The setter rev — TEST-250, TEST-272
- [~] `REQ-PSTORE-013` (09-parameter-store.md:298) A feed or oracle-configuration change would fail the LPOracle's `checkConfig` for any affected market | The se — TEST-064, TEST-225, TEST-250
- [~] `REQ-PSTORE-014` (09-parameter-store.md:299) ParameterStore implementation broken or reverting | Every LPOracle configuration read fails, so every market i — TEST-133, TEST-250

## TEST rows (23: 0 verified, 0 failed, 17 not run, 6 unlinked)

- [~] `TEST-013` [unit] Exposure caps: `RiskModule.checkPledge` values the pledge from the LPOracle and checks the post-pledge totals 
- [ ] `TEST-206` [unit] No interest fee: the selector inventories of the AaveAdapter, the PositionProxy and the ParameterStore contain (only excluded checks: tag on a test named for another row; uses a stand-in for ParameterStore)
- [~] `TEST-196` [unit] Minimum pledge value: `RiskModule.checkPledge` computes `pledgeUsd = mulDiv(L, price8, 10^d, Floor)` with the 
- [ ] `TEST-325` [unit] Speed-limit parameters: views read all zero before the first write; the loosen setters write a scope's first v
- [ ] `TEST-326` [integration] On the real local Aave V4 Hub and CDP Spoke through the AaveAdapter: a borrow charges both windows by the real
- [~] `TEST-039` [unit] Price states: precedence Expired > Cached > Drifting > Live, recomputed on every read. Drifting when the TWAP 
- [~] `TEST-295` [unit, integration] Market-count limit (2.8 `REQ-MREG-034`): with `MAX_MARKET_COUNT = N`, markets 1 to N list and the next pair re
- [~] `TEST-054` [unit] Routes: a fixed swap route from each pool token into each debt asset the CDP Spoke can borrow (Uniswap v3, Sli
- [~] `TEST-063` [unit] Delay classes: an operation gets the short delay (43,200 s) only when every call in it is on the short-delay l
- [~] `TEST-064` [unit] Liquidation-liveness bounds: for every value the ParameterStore setters accept for `slippageAllowanceBps`, `gr
- [ ] `TEST-168` [access-control] Pause location: the only pause state is the MarketRegistry's `PauseState`; the AaveAdapter, RiskModule, Parame (only excluded checks: uses a stand-in for ParameterStore)
- [~] `TEST-097` [invariant] Caps: Collateralization's aggregate counters equal the sum of remaining record charges, never go negative, and
- [ ] `TEST-215` [invariant] Multi-actor invariant suite (Foundry invariant test with handlers, extending `TEST-082`). Actors: borrowers wi (only excluded checks: tag on a test named for another row)
- [~] `TEST-133` [hostile] Hostile MarketRegistry and ParameterStore: remapping a market to an attacker pool, Spoke, vault token or debt 
- [ ] `TEST-138` [deployment-check] Listing order: token and feed are deployed and a valid price is seeded before the DAO payload; the governance  (only excluded checks: uses a stand-in for ParameterStore)
- [~] `TEST-139` [deployment-check] Listing guards reject a market unless: `d0 + d1` is even; every feed's normalised `minAnswer` is ≥ 1; the pool
- [~] `TEST-225` [invariant] Governance drift sequences: random tighten, loosen and structural operations within bounds, scheduled and exec
- [~] `TEST-242` [access-control] Admin grant: on every upgradeable Avana contract, `grantRole(APPLICATION_ADMIN, a)` and `grantRole(DEFAULT_ADM
- [~] `TEST-244` [unit] Timelock allowlists: `setNormalDelay` below `MIN_NORMAL_DELAY` (345,600) or above `MAX_DELAY` reverts `DelayOu
- [~] `TEST-245` [unit] Two-leg liveness: `setBuySlippageAllowanceBps`, `enableDebtReserve` and `activateMarket` revert `LivenessBound
- [~] `TEST-250` [unit] Feed cadence: a feed is fresh while its age is at most its own heartbeat, read from the feed's configuration a
- [~] `TEST-272` [unit] Hub-keyed and pool-keyed caps: the token and depositor counters are held in the one ledger per chain, keyed by
- [~] `TEST-278` [unit] No minimum debt on any chain: on both chain profiles a borrow of 1 base unit of the debt asset, a borrow of $1

## PROP rows (4: 4 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-034` [Certora] Every restricted selector of every upgradeable Avana contract (AaveAdapter, MarketRegistry, ParameterStore, Ri — MarketRegistryRoles job 64b019d802284238bcda1b390f66903c
- [x] `PROP-042` [Halmos] Every `tighten*` selector of the ParameterStore leaves the parameter inside its hard bounds and inside the liq — ParameterStore job 5cf1a73b625f4624b65c99923de6cb24
- [x] `PROP-044` [SMTChecker] LPOracle (with the pricing library of each AMM protocol), LPVaultSwap (with SettlementMath), each AMM integrat — ParameterStore job 5cf1a73b625f4624b65c99923de6cb24
- [x] `PROP-070` [Certora] Inductive admin invariant: for every upgradeable Avana contract (not the ProxyManager, which is immutable with — AvanaTimelock job 51a4165fa4db461e888652ad6b397943

## INV (14: 4 verified, 0 failed, 6 not run, 4 unlinked)

- [x] `INV-011` Transfer allowlist. A market's vault-token balances change only on these paths, and every other `transfer` and — PROP-008, PROP-055, TEST-022, TEST-087, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [~] `INV-017` Collateralization and each LPVault obtain an AMM protocol's position manager and factory only from the LPVault — PROP-083, TEST-010, TEST-030, TEST-108, TEST-114, TEST-116, TEST-171, TEST-264, TEST-265
- [~] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin — TEST-031, TEST-107, TEST-130, TEST-133, TEST-195
- [ ] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe — TEST-027, TEST-106 (only excluded checks: uses a stand-in for ParameterStore)
- [ ] `INV-022` Calldata built by `packages/protocol` asks a user for only two kinds of approval: an approval of exactly one p
- [ ] `INV-024` A borrow, a withdrawal that leaves debt, and a partial removal that leaves debt complete only if: the caller ( — TEST-019, TEST-028, TEST-095, TEST-229 (only excluded checks: uses a stand-in for ParameterStore)
- [~] `INV-028` (a) A pledge, top-up or re-credit completes only if, after it, every counter is within its cap (`marketUsdCap` — PROP-030, TEST-013, TEST-272
- [~] `INV-069` Minimum pledge value. Every pledge and re-credit, for a new account and for a top-up alike, completes only if  — PROP-062, TEST-196, TEST-235
- [~] `INV-043` For any proxy with debt in reserve `r`, `AaveAdapter.repay(borrower, spoke, r, maxRepaySpend, repayAll, deadli — PROP-057, PROP-066, TEST-029, TEST-075, TEST-099, TEST-132, TEST-162, TEST-193
- [x] `INV-047` Every ParameterStore setter for `slippageAllowanceBps`, `graceHealthFactor`, `graceDuration`, `consistencyTole — PROP-042, TEST-064, TEST-225 — ParameterStore job 5cf1a73b625f4624b65c99923de6cb24
- [ ] `INV-075` No contagion from pool-level failures. A failure confined to collateral market `m′` (its pool, its LPOracle st
- [x] `INV-051` Every privileged change to Avana executes through the AvanaTimelock: proposed only by the governance multisig  — PROP-034, PROP-058, PROP-073, PROP-099, TEST-062, TEST-166, TEST-194, TEST-212 — AvanaTimelock job 51a4165fa4db461e888652ad6b397943
- [~] `INV-065` Implementation changes only by timelock; proxy code never changes. A PositionProxy's code is fixed at creation — PROP-010, PROP-058, TEST-025, TEST-062, TEST-063, TEST-089, TEST-130, TEST-168, TEST-172, TEST-191
- [x] `INV-090` Timelock allowlists. `normalDelay ∈ [MIN_NORMAL_DELAY, MAX_DELAY]` = [345,600, 432,000] s; the enabled short-d — PROP-073, TEST-194, TEST-212, TEST-225, TEST-244 — AvanaTimelock job 51a4165fa4db461e888652ad6b397943

## ATTACK (2: 0 verified, 0 failed, 1 not run, 1 unlinked)

- [~] `ATTACK-033` Re-pointing proxies or the LPVault through configuration — TEST-138, TEST-171
- [ ] `ATTACK-087` Exposure-cap bypass

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
