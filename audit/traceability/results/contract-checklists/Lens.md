# Checklist: Lens

Spec pages: 17-lens.md. CVL specs: none.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (61: 0 verified, 0 failed, 49 not run, 12 unlinked)

- [~] `REQ-LENS-001` (17-lens.md:123) The Lens MUST be immutable: no proxy, no state-changing function, no storage other than constructor immutables — TEST-247, TEST-270
- [~] `REQ-LENS-002` (17-lens.md:124) A new Lens is a new deployment: one is deployed when a dependency's interface changes or a new Avana contract  — TEST-247
- [~] `REQ-LENS-003` (17-lens.md:125) No Avana core contract (AaveAdapter, ProxyManager, PositionProxies, Collateralization, every LPVault and AMM i — TEST-247
- [~] `REQ-LENS-004` (17-lens.md:126) Lens results are advisory. The keeper and the app MUST re-read the authoritative values by RPC at a fixed bloc — TEST-069
- [~] `REQ-LENS-005` (17-lens.md:130) Every return struct MUST include `blockNumber` and `timestamp` (`block.number`, `block.timestamp`). Values wit — TEST-069, TEST-247
- [~] `REQ-LENS-006` (17-lens.md:131) Every Lens function MUST revert with `Locked()` when `LOCK.isLocked()` is true, so no read observes accounting — TEST-060, TEST-247, TEST-270
- [~] `REQ-LENS-007` (17-lens.md:132) Lens functions MUST NOT revert because of a price state: LPOracle feeds never revert and always serve a positi — TEST-069, TEST-239, TEST-247
- [~] `REQ-LENS-008` (17-lens.md:136) `predictProxy(wallet, marketId)` MUST read `spoke` from `MARKET_REGISTRY.getMarket(marketId)` and return `prox — TEST-190, TEST-223, TEST-247
- [~] `REQ-LENS-009` (17-lens.md:137) `getAccount(wallet, marketId)` MUST return: wallet, `marketId`, its `spoke` and `hub`, proxy, `deployed`, `ADA — TEST-223, TEST-228, TEST-229, TEST-247
- [~] `REQ-LENS-010` (17-lens.md:138) `getAccount` loops once over the Spoke's enabled debt reserves and reads the account's one collateral reserve; — TEST-247
- [~] `REQ-LENS-011` (17-lens.md:139) `getRecords(proxy, offset, limit)` MUST resolve the proxy's market from the AaveAdapter's binding `accountOf(p — TEST-223, TEST-247
- [~] `REQ-LENS-012` (17-lens.md:143) `checkBacking(vaultToken)` MUST resolve the market (`marketOfVaultToken`), its CDP Spoke and home Hub `hub` fr — TEST-223, TEST-247
- [~] `REQ-LENS-013` (17-lens.md:144) `checkBacking` MUST loop only over the Spokes registered for the vault-token asset on the market's Hub (DAO-co — TEST-247
- [~] `REQ-LENS-014` (17-lens.md:145) `checkRecordBacking(vaultToken, offset, limit)` MUST first apply the limit checks of `REQ-LENS-023` (`limit =  — TEST-247
- [~] `REQ-LENS-026` (17-lens.md:146) `getPendingSettlement(vaultToken)` MUST return `pending.units` and `pending.amounts` (one amount per pool toke — TEST-069, TEST-223, TEST-247
- [~] `REQ-LENS-027` (17-lens.md:147) `getEscrowClaimable(recipient, tokens)` MUST return, for each address in `tokens` in the same order, `PAYOUT_E — TEST-247
- [~] `REQ-LENS-015` (17-lens.md:151) `getPriceState(vaultToken)` MUST return, from the market's LPOracle feed (`getPriceState()`, computed by the s — TEST-247
- [~] `REQ-LENS-030` (17-lens.md:152) `getDebtPriceState(spoke, debtReserveId)` MUST return, for an approved debt reserve of `spoke` (`MarketRegistr — TEST-069, TEST-247
- [~] `REQ-LENS-031` (17-lens.md:153) `getApplicationState(hub)` MUST return `MARKET_REGISTRY.pauseState(hub)` (`None`, `Frozen` or `Paused`) and `g — TEST-162, TEST-223, TEST-247
- [~] `REQ-LENS-016` (17-lens.md:157) `previewLiquidation(proxy, debtReserveId, deadline)` MUST resolve `(spoke, marketId, vaultToken) = ADAPTER.acc — TEST-069, TEST-162, TEST-223, TEST-247
- [~] `REQ-LENS-017` (17-lens.md:158) `previewLiquidation` MUST size the debt Aave repays, `expectedDebtRepaid`, with Aave V4's liquidation formulas — TEST-069, TEST-205
- [~] `REQ-LENS-028` (17-lens.md:159) Ready-to-send parameters. `previewLiquidation` MUST return in `params` a `LiquidationParams` ([2.11](11-lpvaul — TEST-069, TEST-205, TEST-223, TEST-247
- [~] `REQ-LENS-029` (17-lens.md:160) Expected amounts. With `D = expectedDebtRepaid` and the `drawnShares` and `premiumDebtRay` to liquidate that t — TEST-069, TEST-205
- [~] `REQ-LENS-018` (17-lens.md:164) `getCapHeadroom(vaultToken, depositor)` MUST report Avana USD headroom (8 decimals) as `max(0, cap − used)` fo — TEST-247
- [~] `REQ-LENS-019` (17-lens.md:165) `getCapHeadroom` MUST also report Aave headroom with the Hub's own formulas: vault-token `addHeadroom = max(0, — TEST-247
- [~] `REQ-LENS-034` (17-lens.md:169) `getTailCoverage(hub, debtAsset)` MUST return a `TailCoverageView` with the cap-based tail coverage of `SPEC-C — TEST-247
- [~] `REQ-LENS-037` (17-lens.md:170) `getBreakerStatus(marketId)` and `getDebtBreakerStatus(spoke, debtReserveId)` MUST return `RISK_MODULE.getBrea — TEST-223, TEST-228, TEST-229, TEST-247
- [~] `REQ-LENS-035` (17-lens.md:174) `previewBorrowMax(wallet, marketId, debtReserveId, deadline)` MUST return the largest `amount` (debt-asset bas — TEST-223, TEST-247
- [~] `REQ-LENS-036` (17-lens.md:175) `quoteRepayAll(borrower, marketId, debtReserveId, deadline)` MUST return `maxRepaySpend = ⌈total × (1 + rate × — TEST-223, TEST-247, TEST-248
- [~] `REQ-LENS-038` (17-lens.md:176) `previewRecredit(marketId, positionKey)` MUST return `added = Collateralization.previewRecredit(integrationId, — TEST-223, TEST-238, TEST-239
- [ ] `REQ-LENS-061` (17-lens.md:177) `getBorrowSpeed(marketId, debtReserveId)` MUST return the RiskModule's `getBorrowSpeed` windows ([2.7](07-risk
- [~] `REQ-LENS-020` (17-lens.md:181) Each Lens function MUST complete within the block gas limit of its chain at its worst-case bound: `getAccount` — TEST-247
- [~] `REQ-LENS-040` (17-lens.md:185) The Lens MUST be deployed once per chain as periphery, outside the audited core, and MUST serve every Hub, CDP — TEST-247
- [~] `REQ-LENS-041` (17-lens.md:186) `previewBorrowMax` MUST apply no minimum borrow for any account and debt reserve: Avana has no minimum debt, s — TEST-247
- [~] `REQ-LENS-042` (17-lens.md:187) `uncoveredDeficit(hub, asset)` MUST return `uncovered = max(0, Σ_s ⌈getSpokeDeficitRay(hubAssetId, s) / 10^27⌉ — TEST-247
- [~] `REQ-LENS-043` (17-lens.md:188) `getHubAssetExposure(hub, asset)` MUST return, per Spoke drawing `(hub, asset)`: its home Hub, `drawCap`, draw — TEST-247
- [~] `REQ-LENS-044` (17-lens.md:189) `previewBorrowRecommended(wallet, marketId, debtReserveId, deadline)` MUST return `maximum`, the `amount` of ` — TEST-247
- [~] `REQ-LENS-045` (17-lens.md:193) `getMarket(marketId)` MUST return, for a listed market (else `UnknownMarket(marketId)`), a `MarketView` with:  — TEST-247
- [~] `REQ-LENS-046` (17-lens.md:194) `getDebtReserve(spoke, debtReserveId)` MUST return, for an enabled debt reserve (else `UnknownDebtReserve`), a — TEST-247
- [~] `REQ-LENS-047` (17-lens.md:195) `getAccountRisk(wallet, marketId)` MUST return an `AccountRiskView` with the account's proxy (`REQ-LENS-008`), — TEST-247
- [~] `REQ-LENS-048` (17-lens.md:196) `previewPledge(depositor, marketId, positionKey)` MUST return `RISK_MODULE.previewPledge(depositor, marketId,  — TEST-247
- [~] `REQ-LENS-049` (17-lens.md:197) `previewWithdraw(wallet, marketId, positionKey, units)` MUST return a `WithdrawPreview` with `units` (the argu — TEST-247
- [ ] `REQ-LENS-050` (17-lens.md:201) `getPositionFees(marketId, positionKey)` MUST return a `PositionFeesView` with `marketId`, `positionKey`, `dep
- [ ] `REQ-LENS-051` (17-lens.md:202) `getAccountFees(wallet, marketId)` MUST return `getPositionFees(marketId, k)` for the position key `k` of each
- [ ] `REQ-LENS-052` (17-lens.md:206) `previewBorrowAfter(wallet, marketId, debtReserveId, amount)` and `previewRepayAfter(wallet, marketId, debtRes
- [ ] `REQ-LENS-053` (17-lens.md:207) `previewPledgeAfter(wallet, marketId, positionKey)` and `previewWithdrawAfter(wallet, marketId, positionKey)` 
- [ ] `REQ-LENS-054` (17-lens.md:211) `previewMaxWithdraw(wallet, marketId, targetHealthFactor)` MUST return a `RemovalSizing` with each record of t
- [ ] `REQ-LENS-055` (17-lens.md:212) `previewDeleverageTo(wallet, marketId, positionKey, debtReserveId, targetHealthFactor)` MUST return a `Delever
- [ ] `REQ-LENS-056` (17-lens.md:213) `previewCloseAccount(wallet, marketId, deadline)` MUST return a `CloseAccountView` with one `DebtClose` per en
- [ ] `REQ-LENS-057` (17-lens.md:217) The `MarketView` of `REQ-LENS-045` MUST also carry the market's risk configuration: `collateralRiskBps` (the v
- [ ] `REQ-LENS-058` (17-lens.md:218) `getHubAsset(hub, assetId)` MUST return, for an asset the Hub lists (`getAssetUnderlyingAndDecimals` names a n
- [ ] `REQ-LENS-059` (17-lens.md:219) Each `SpokeDraw` of `getHubAsset` and `getHubAssetExposure` MUST carry, for one Spoke registered on the Hub as
- [~] `REQ-LENS-021` (17-lens.md:225) Lock is held | reverts with `Locked()` (Source: Q-119, Q-148) — TEST-060
- [~] `REQ-LENS-022` (17-lens.md:226) `marketId` is not a listed market (`MarketRegistry.getMarket` returns a record with no vault token, or `market — TEST-247
- [~] `REQ-LENS-023` (17-lens.md:227) `limit == 0` or `limit > LENS_MAX_PAGE` | reverts with `LimitTooHigh(limit)` for the upper bound; returns an e — TEST-247
- [~] `REQ-LENS-024` (17-lens.md:228) `offset` at or beyond the last record (`offset ≥ getMarketRecordCount(marketId)` for `checkRecordBacking`, `of — TEST-247
- [~] `REQ-LENS-025` (17-lens.md:229) A dependency's interface changed after an upgrade | calls revert; a new Lens is deployed and recorded in the m — TEST-247
- [~] `REQ-LENS-032` (17-lens.md:230) `previewLiquidation` or `getDebtPriceState` for a debt reserve outside the MarketRegistry's enabled set of the — TEST-069, TEST-239, TEST-247
- [~] `REQ-LENS-033` (17-lens.md:231) `previewLiquidation` for an address that is not a registered proxy of the vault token (`isValidProxy` false) | — TEST-069, TEST-247
- [~] `REQ-LENS-039` (17-lens.md:232) `getTailCoverage` for a (Hub, asset) pair that no enabled debt reserve of any CDP Spoke draws | reverts with ` — TEST-247
- [ ] `REQ-LENS-060` (17-lens.md:233) `getHubAsset` for an asset the Hub does not list (its underlying reads as address(0)) | reverts with `UnknownH

## TEST rows (8: 0 verified, 0 failed, 7 not run, 1 unlinked)

- [ ] `TEST-327` [unit] Lens speed views: `getBorrowSpeed(m, r)` returns the RiskModule's two windows and `availableNow`, the smaller 
- [~] `TEST-205` [unit] Lens parameters execute unchanged: `Lens.previewLiquidation(proxy, debtReserveId, deadline)` returns `Liquidat
- [~] `TEST-069` [differential] Liquidation previews against execution at the same fork block: the Lens's `previewLiquidation` sizes `debtToCo
- [~] `TEST-223` [fork] LP journeys on one fork, end to end, with the Lens asserted at every step against execution: deposit → borrow 
- [~] `TEST-222` [unit] Reentrancy through `collect` and `decreaseLiquidity`: pool tokens with transfer hooks (ERC-777 style) re-enter
- [~] `TEST-225` [invariant] Governance drift sequences: random tighten, loosen and structural operations within bounds, scheduled and exec
- [~] `TEST-230` [unit] Stress valuation: an Expired market is served at 1 and a fresh market of the same account is liquidated; the s
- [~] `TEST-247` [fork] Lens against execution at the same fork block: seizure per Aave's formula on the compiled sizing; whole debt a

## PROP rows (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## INV (7: 2 verified, 0 failed, 4 not run, 1 unlinked)

- [ ] `INV-022` Calldata built by `packages/protocol` asks a user for only two kinds of approval: an approval of exactly one p
- [~] `INV-025` After every borrow, every withdrawal that leaves debt and every partial removal that leaves debt, the account' — PROP-031, TEST-019, TEST-027, TEST-095, TEST-132, TEST-236
- [~] `INV-082` Rescue units never support new debt. Collateralization books, per record, the rescue units of every rescue top — PROP-067, TEST-057, TEST-077, TEST-235, TEST-236
- [~] `INV-043` For any proxy with debt in reserve `r`, `AaveAdapter.repay(borrower, spoke, r, maxRepaySpend, repayAll, deadli — PROP-057, PROP-066, TEST-029, TEST-075, TEST-099, TEST-132, TEST-162, TEST-193
- [x] `INV-049` Pause-state transitions. The MarketRegistry holds one `PauseState` and one `PauseReason` for Avana, and they c — PROP-041, PROP-057, TEST-065, TEST-101, TEST-192, TEST-193 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [~] `INV-052` The vault tokens, VaultTokenFactory, every LPVault (one per AMM protocol per chain), Collateralization (one pe — PROP-099, TEST-108, TEST-166
- [x] `INV-054` Every external state-changing entry point of the AaveAdapter and LPVaultSwap either acquires the Lock (outer c — PROP-037, PROP-075, TEST-046, TEST-060, TEST-179 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock

## ATTACK (2: 0 verified, 0 failed, 2 not run, 0 unlinked)

- [~] `ATTACK-093` Read-only reentrancy on the Lens or LPOracle — TEST-060, TEST-222
- [~] `ATTACK-135` Stale or manipulated liquidation preview — TEST-069

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
