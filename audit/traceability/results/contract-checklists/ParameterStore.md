# Checklist: ParameterStore

Spec pages: 09-parameter-store.md. CVL specs: ParameterStore.spec.

## REQ / SPEC on the page (58)

- [x] `REQ-PSTORE-001` (09-parameter-store.md:173) The ParameterStore of each chain MUST sit behind one fixed ERC-1967 proxy address using the UUPS pattern, whos — TEST-062, TEST-242
- [x] `REQ-PSTORE-002` (09-parameter-store.md:174) Every setter MUST require `APPLICATION_ADMIN`, so every value is the value an executed timelock operation set. — TEST-062, TEST-063
- [ ] `REQ-PSTORE-003` (09-parameter-store.md:175) The blast radius of a faulty or hostile ParameterStore implementation is: it can return any value its code cho
- [x] `REQ-CONFIG-049` (09-parameter-store.md:179) Each parameter's change class MUST match [1.5](../01-architecture/05-parameters.md), with these directions: `h — TEST-064
- [x] `REQ-CONFIG-050` (09-parameter-store.md:180) Every setter MUST enforce the hard-coded minimum and maximum of the ParameterStore implementation, which equal — PROP-042, TEST-064, TEST-242, TEST-246
- [x] `REQ-CONFIG-051` (09-parameter-store.md:181) A two-direction parameter MUST have separate tighten and loosen (or structural) setters; the tighten setter MU — PROP-042, TEST-063, TEST-064
- [x] `REQ-CONFIG-052` (09-parameter-store.md:182) Liquidation-liveness bounds: no setter MAY take `slippageAllowanceBps` below `slippageAllowanceMinBps` (per ma — PROP-042, TEST-064, TEST-245, TEST-250
- [x] `REQ-CONFIG-053` (09-parameter-store.md:183) Loosen setters MUST run only through the timelock at the normal delay, cancellable by any `CANCELLER_ROLE` hol — TEST-063
- [x] `REQ-CONFIG-054` (09-parameter-store.md:184) Structural setters MUST run only through the timelock at the normal delay; new price sources and any change to — TEST-063
- [x] `REQ-CONFIG-055` (09-parameter-store.md:185) Setting `usdBandLow`/`usdBandHigh` MUST require `usdBandLow < 10^8 < usdBandHigh` (8-decimal USD levels per 1  — TEST-064
- [ ] `REQ-CONFIG-057` (09-parameter-store.md:186) No temporary override of any parameter exists: the LPOracle applies the stored `feedAgreementToleranceBps` and
- [x] `REQ-CONFIG-058` (09-parameter-store.md:187) No account MAY set, restore or override a parameter outside a timelock operation: there is no recovery role, n — TEST-062
- [x] `REQ-CONFIG-071` (09-parameter-store.md:188) Each parameter MUST have one stored value, the value the last executed timelock operation set; there is no app — TEST-063, TEST-225
- [x] `REQ-PSTORE-004` (09-parameter-store.md:192) `setInitialMarketParams(marketId, params)` MUST revert with `NotInListing` unless the MarketRegistry has the m — TEST-250
- [x] `REQ-CONFIG-015` (09-parameter-store.md:193) `poolRiskFactor` per market MUST be stored in bps, > 0 and ≤ the launch ceiling bound in [1.5](../01-architect — TEST-064, TEST-250
- [x] `REQ-CONFIG-041` (09-parameter-store.md:194) `slippageAllowanceMinBps` for the market MUST be set at listing (`setInitialMarketParams`) to at least the lar — TEST-064, TEST-245, TEST-250
- [x] `REQ-PSTORE-005` (09-parameter-store.md:195) `minPledgeUsd` MUST be stored per market in 8-decimal USD within `[0, 100_000e8]` and launch at $10 (`10e8`) f — PROP-042, TEST-064, TEST-225, TEST-250
- [x] `REQ-RISK-041` (09-parameter-store.md:199) Initial `marketUsdCap`, `topUpSliceUsd`, `stressFloorUsd` (per market) and `tokenUsdCap(hub, token)` (per pool — TEST-272
- [x] `REQ-RISK-042` (09-parameter-store.md:200) Each cap MUST have a tighten setter that reverts with `NotStricter` unless the new value is strictly lower tha — PROP-042, TEST-272
- [x] `REQ-RISK-043` (09-parameter-store.md:201) Each cap MUST have a loosen setter that reverts with `NotLooser` unless the new value is strictly higher, exec — TEST-225
- [x] `REQ-RISK-044` (09-parameter-store.md:202) Every cap setter MUST enforce the hard-coded minimum and maximum of [1.5](../01-architecture/05-parameters.md) — PROP-042, TEST-225, TEST-272
- [x] `REQ-RISK-045` (09-parameter-store.md:203) `setStressFloorUsd` MUST run at the normal delay; it MAY lower the floor only if [SPEC-CAP-006](07-risk-module — TEST-272
- [x] `REQ-CONFIG-019` (09-parameter-store.md:207) Each pool token MUST carry `tokenCollateralFactorBps`, recorded with its source and written with `setTokenColl — TEST-064
- [x] `REQ-CONFIG-020` (09-parameter-store.md:208) A token with no Core Hub collateral factor, or one Avana must not inherit, MUST carry an explicit `tokenCollat — TEST-064, TEST-250
- [x] `REQ-CONFIG-022` (09-parameter-store.md:209) For every feed, `setFeed` MUST read `decimals` on-chain and pin it, and read `minAnswer` and `maxAnswer` on-ch — TEST-250
- [x] `REQ-CONFIG-023` (09-parameter-store.md:210) Each feed MUST carry its own published `heartbeat`, a freshness margin `heartbeatMargin`, `feedMaxAge`, `feedD — TEST-064, TEST-250
- [x] `REQ-CONFIG-024` (09-parameter-store.md:211) Feed-agreement tolerance lower bound: for each token, `feedAgreementToleranceBps ≥ dev(primary) + dev(alternat — TEST-064, TEST-250
- [x] `REQ-PSTORE-009` (09-parameter-store.md:212) `setFeed` and every per-feed setter MUST revert with `OracleConfigRejected(lpOracle, failedChecks)` when the L — TEST-064, TEST-250
- [x] `REQ-PSTORE-006` (09-parameter-store.md:216) No buy-leg slippage parameter exists: the liquidation caller funds the debt asset itself (and `deleverage` fla — TEST-246
- [ ] `REQ-PSTORE-007` (09-parameter-store.md:217) No buy-route depth threshold exists, for the reason in `REQ-PSTORE-006`; the depth a liquidation needs is the 
- [x] `REQ-PSTORE-015` (09-parameter-store.md:218) The lower side of liquidation liveness MUST be `slippageAllowanceMinBps(m)`, set per market to cover the real  — PROP-042, TEST-064, TEST-245
- [x] `REQ-PSTORE-021` (09-parameter-store.md:219) For every Active or Offboarding market `m` of a CDP Spoke and every enabled debt reserve `r` of that Spoke, li — TEST-245
- [x] `REQ-CONFIG-070` (09-parameter-store.md:220) Each swap-route slot `(marketId, token, kind)` MUST carry `routeDepthThreshold`, the USD notional (8 decimals) — TEST-064
- [x] `REQ-PSTORE-016` (09-parameter-store.md:224) The ParameterStore MUST hold the on-chain breaker values of `Q-399` in the table, within these bounds and chan — TEST-064, TEST-225
- [x] `REQ-PSTORE-030` (09-parameter-store.md:231) `gateRecoverySeconds` MUST be stored per chain in seconds within `[600, 7,200]`, launch 1,800 (30 minutes, a p — PROP-042, TEST-064, TEST-225, TEST-242
- [x] `REQ-PSTORE-023` (09-parameter-store.md:235) Each chain's ParameterStore MUST hold the chain's sequencer-uptime check `sequencer = SequencerConfig{feed, gr — TEST-250
- [x] `REQ-PSTORE-024` (09-parameter-store.md:236) `maxFlashFeeBps` MUST be a chain parameter in bps within `[0, 100]`, launch 10 on Ethereum and on Base, lowere — PROP-042, TEST-052, TEST-064, TEST-245
- [x] `REQ-PSTORE-025` (09-parameter-store.md:237) The ParameterStore MUST hold no minimum debt: it stores no debt floor, has no setter or event for one, and no  — TEST-278
- [x] `REQ-PSTORE-026` (09-parameter-store.md:238) Hub-wide caps MUST be keyed by Hub: `tokenUsdCap(hub, token)` and `depositorUsdCap(hub)`. `setInitialHubCaps(h — TEST-225, TEST-272
- [x] `REQ-PSTORE-027` (09-parameter-store.md:239) `CHAIN_BLOCK_TIME` MUST be an implementation immutable equal to the chain's block time (12 s on Ethereum, 2 s  — TEST-250
- [x] `REQ-PSTORE-028` (09-parameter-store.md:240) Each pool token and each debt asset with a DebtOracle MUST carry `secondSource(token)`, the independent second — TEST-250
- [x] `REQ-PSTORE-029` (09-parameter-store.md:241) **Standby second source.** `setSecondSource(token, src, standby)` MUST apply every check of `REQ-PSTORE-028` t — TEST-062, TEST-250
- [x] `REQ-PSTORE-031` (09-parameter-store.md:242) `hardHealthFloor(marketId)` MUST be stored per market in WAD, 0 (off) by default and at launch, or within `[1e — PROP-042, TEST-064, TEST-225
- [x] `REQ-PSTORE-032` (09-parameter-store.md:243) `coverageRatioBps` MUST be stored per chain in bps within `[0, 10,000]`, set by `setCoverageRatioBps` at the n — TEST-273
- [x] `REQ-PSTORE-018` (09-parameter-store.md:247) `maxShortfallBps` MUST be stored in bps within `[0, 5,000]`, launch 1,000, lowered by `tightenMaxShortfallBps` — PROP-042, TEST-064, TEST-225, TEST-242
- [ ] `REQ-PSTORE-019` (09-parameter-store.md:248) There MUST be no `inKindAutoDelay`: in-kind settlement and its automatic trigger are removed (`Q-401`), so the
- [x] `REQ-PSTORE-020` (09-parameter-store.md:249) `debtStressRiseBps(asset)` MUST be stored per debt asset that has a DebtOracle (every debt asset except one Aa — TEST-064, TEST-225
- [x] `REQ-PSTORE-017` (09-parameter-store.md:253) Each loosening of a step-limited parameter MUST move it at most one step and MUST execute at least `normalDela — TEST-063, TEST-225
- [x] `REQ-PSTORE-022` (09-parameter-store.md:254) Each approved CDP Spoke MUST carry `aaveTargetHealthFactor(spoke)` (WAD) and `minLiquidationBonus(spoke)` (bps — TEST-249
- [ ] `REQ-PSTORE-008` (09-parameter-store.md:258) There MUST be no `inKindExpiry` and no `setInKindExpiry`: in-kind settlement is removed (`Q-401`). The PayoutE
- [x] `REQ-PSTORE-010` (09-parameter-store.md:259) `avanaFeeShareBps` MUST stay within `[0, 5,000]` with launch value 2,000 (a proposed default; final value set  — TEST-064, TEST-206
- [x] `REQ-CONFIG-056` (09-parameter-store.md:260) `feeRecipient` MUST NOT be the zero address, an Avana contract, any Hub or Spoke on the chain or a PositionPro — TEST-062
- [x] `REQ-CONFIG-072` (09-parameter-store.md:264) `getOracleConfig(lpOracle)` MUST return, for the market `MARKET_REGISTRY.marketOfLpOracle(lpOracle)`: `marketI — TEST-250
- [x] `REQ-PSTORE-011` (09-parameter-store.md:265) Every view MUST be `view`, never revert for a listed market, token, feed or debt reserve, and return the value — TEST-064, TEST-250
- [x] `REQ-CONFIG-067` (09-parameter-store.md:271) A tighten value is not strictly safer, a loosen value not strictly looser, a value crosses a hard or liveness  — TEST-064
- [x] `REQ-PSTORE-012` (09-parameter-store.md:272) An initial setter targets a market that is not `Registered` or a token that already has a cap | The setter rev — TEST-250, TEST-272
- [x] `REQ-PSTORE-013` (09-parameter-store.md:273) A feed or oracle-configuration change would fail the LPOracle's `checkConfig` for any affected market | The se — TEST-064
- [ ] `REQ-PSTORE-014` (09-parameter-store.md:274) ParameterStore implementation broken or reverting | Every LPOracle configuration read fails, so every market i

## TEST rows (19)

- [x] `TEST-013` [unit] Exposure caps: `RiskModule.checkPledge` values the pledge from the LPOracle and checks the post-pledge totals 
- [x] `TEST-206` [unit] No interest fee: the selector inventories of the AaveAdapter, the PositionProxy and the ParameterStore contain
- [ ] `TEST-196` [unit] Minimum pledge value: `RiskModule.checkPledge` computes `pledgeUsd = mulDiv(L, price8, 10^d, Floor)` with the 
- [x] `TEST-054` [unit] Routes: a fixed swap route from each pool token into each debt asset the CDP Spoke can borrow (Uniswap v3, Sli
- [x] `TEST-063` [unit] Delay classes: an operation gets the short delay (43,200 s) only when every call in it is on the short-delay l
- [x] `TEST-064` [unit] Liquidation-liveness bounds: for every value the ParameterStore setters accept for `slippageAllowanceBps`, `gr
- [x] `TEST-168` [access-control] Pause location: the only pause state is the MarketRegistry's `PauseState`; the AaveAdapter, RiskModule, Parame
- [x] `TEST-097` [invariant] Caps: Collateralization's aggregate counters equal the sum of remaining record charges, never go negative, and
- [ ] `TEST-215` [invariant] Multi-actor invariant suite (Foundry invariant test with handlers, extending `TEST-082`). Actors: borrowers wi
- [ ] `TEST-133` [hostile] Hostile MarketRegistry and ParameterStore: remapping a market to an attacker pool, Spoke, vault token or debt 
- [x] `TEST-138` [deployment-check] Listing order: token and feed are deployed and a valid price is seeded before the DAO payload; the governance 
- [x] `TEST-139` [deployment-check] Listing guards reject a market unless: `d0 + d1` is even; every feed's normalised `minAnswer` is ≥ 1; the pool
- [x] `TEST-225` [invariant] Governance drift sequences: random tighten, loosen and structural operations within bounds, scheduled and exec
- [x] `TEST-242` [access-control] Admin grant: on every upgradeable Avana contract, `grantRole(APPLICATION_ADMIN, a)` and `grantRole(DEFAULT_ADM
- [x] `TEST-244` [unit] Timelock allowlists: `setNormalDelay` below `MIN_NORMAL_DELAY` (345,600) or above `MAX_DELAY` reverts `DelayOu
- [x] `TEST-245` [unit] Two-leg liveness: `setBuySlippageAllowanceBps`, `enableDebtReserve` and `activateMarket` revert `LivenessBound
- [x] `TEST-250` [unit] Feed cadence: a feed is fresh while its age is at most its own heartbeat, read from the feed's configuration a
- [x] `TEST-272` [unit] Hub-keyed and pool-keyed caps: the token and depositor counters are held in the one ledger per chain, keyed by
- [x] `TEST-278` [unit] No minimum debt on any chain: on both chain profiles a borrow of 1 base unit of the debt asset, a borrow of $1

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

## PROP rows (4)

- [x] `PROP-034` [Certora] Every restricted selector of every upgradeable Avana contract (AaveAdapter, MarketRegistry, ParameterStore, Ri
- [x] `PROP-042` [Halmos] Every `tighten*` selector of the ParameterStore leaves the parameter inside its hard bounds and inside the liq
- [x] `PROP-044` [SMTChecker] LPOracle (with the pricing library of each AMM protocol), LPVaultSwap (with SettlementMath), each AMM integrat
- [x] `PROP-070` [Certora] Inductive admin invariant: for every upgradeable Avana contract (not the ProxyManager, which is immutable with

## INV (14)

- [x] `INV-011` Transfer allowlist. A market's vault-token balances change only on these paths, and every other `transfer` and
- [x] `INV-017` Collateralization and each LPVault obtain an AMM protocol's position manager, factory and a market's pool only
- [ ] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin
- [ ] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe
- [ ] `INV-022` Calldata built by `packages/protocol` asks a user for only two kinds of approval: an approval of exactly one p
- [ ] `INV-024` A borrow, a withdrawal that leaves debt, and a partial removal that leaves debt complete only if: the caller (
- [x] `INV-028` (a) A pledge, top-up or re-credit completes only if, after it, every counter is within its cap (`marketUsdCap`
- [x] `INV-069` Minimum pledge value. Every pledge and re-credit, for a new account and for a top-up alike, completes only if 
- [x] `INV-043` For any proxy with debt in reserve `r`, `AaveAdapter.repay(borrower, spoke, r, maxRepaySpend, repayAll, deadli
- [x] `INV-047` Every ParameterStore setter for `slippageAllowanceBps`, `graceHealthFactor`, `graceDuration`, `consistencyTole
- [ ] `INV-075` No contagion from pool-level failures. A failure confined to collateral market `m′` (its pool, its LPOracle st
- [x] `INV-051` Every privileged change to Avana executes through the AvanaTimelock: proposed only by the governance multisig 
- [x] `INV-065` Implementation changes only by timelock; proxy code never changes. A PositionProxy's code is fixed at creation
- [x] `INV-090` Timelock allowlists. `normalDelay ∈ [MIN_NORMAL_DELAY, MAX_DELAY]` = [345,600, 432,000] s; the enabled short-d

## ATTACK (2)

- [x] `ATTACK-033` Re-pointing proxies or the LPVault through configuration
- [ ] `ATTACK-087` Exposure-cap bypass
9 IDs without a link from contracts/: REQ-PSTORE-003, REQ-CONFIG-057, REQ-PSTORE-007, REQ-PSTORE-019, REQ-PSTORE-008, REQ-PSTORE-014, TEST-196, TEST-215, TEST-133
