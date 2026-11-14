# Checklist: MarketRegistry

Spec pages: 08-market-registry.md. CVL specs: MarketRegistry.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (99: 0 verified, 0 failed, 98 not run, 1 unlinked)

- [~] `REQ-CONFIG-001` (08-market-registry.md:194) The MarketRegistry MUST sit behind one fixed ERC-1967 proxy address using the UUPS pattern, whose `_authorizeU — TEST-062, TEST-168
- [~] `REQ-CONFIG-002` (08-market-registry.md:195) Upgrades MUST go only through `upgradeToAndCall` on the proxy, executed by the timelock at the normal delay an — TEST-062, TEST-063, TEST-168, TEST-242
- [~] `REQ-CONFIG-003` (08-market-registry.md:196) The MarketRegistry MUST NOT hold or approve any token or NFT and MUST NOT call any state-changing function on  — TEST-168, TEST-252
- [~] `REQ-CONFIG-004` (08-market-registry.md:197) Immutable Avana contracts (vault tokens, LPVaults, Collateralization, the Lock, the ProxyManager, PositionProx — TEST-168
- [~] `REQ-CONFIG-005` (08-market-registry.md:198) Canonical per-chain Avana addresses (`TIMELOCK`, `AAVE_GOVERNANCE_EXECUTOR`, `VAULT_TOKEN_FACTORY`, `AAVE_ADAP — TEST-168, TEST-204, TEST-285, TEST-289, TEST-295
- [~] `REQ-CONFIG-006` (08-market-registry.md:202) A market is one (chain, AMM integration, pool, exact position shape) = one vault token = one Hub asset `(homeH — TEST-024, TEST-138, TEST-139, TEST-213, TEST-228
- [~] `REQ-CONFIG-007` (08-market-registry.md:203) Each of `marketOfKey`, `marketOfVaultToken`, `marketOfLpOracle`, `marketOfHubAsset` and `marketOfReserve` MUST — PROP-098, TEST-138, TEST-252
- [~] `REQ-CONFIG-008` (08-market-registry.md:204) `hub`, `spoke`, `integrationId`, `integration`, `pool` or `poolId`, `shape`, `tokens`, `tokenDecimals`, `vault — TEST-138
- [~] `REQ-CONFIG-009` (08-market-registry.md:205) A market's `lpOracle` address MUST be immutable for the market; a new price source or a change to price comput — TEST-138, TEST-231
- [~] `REQ-CONFIG-010` (08-market-registry.md:206) Each vault token is permanently bound to its market's home Hub and CDP Spoke; a market moves to another Hub or — TEST-138, TEST-252
- [~] `REQ-CONFIG-011` (08-market-registry.md:207) A market MUST be registered only for an AMM integration registered on this chain whose readiness guards hold ( — TEST-138
- [~] `REQ-CONFIG-012` (08-market-registry.md:208) A market in `Registered` or `Cancelled` status MUST be treated as not listed by every Avana contract and the L — PROP-098, TEST-138
- [~] `REQ-CONFIG-013` (08-market-registry.md:209) A market MUST NOT be deleted or returned to `Active` once it leaves `Registered`; offboarding is `setMarketOff — PROP-098, TEST-213
- [~] `REQ-CONFIG-014` (08-market-registry.md:210) The MarketRegistry MUST NOT store a risk parameter value, a settlement mode, an allowlist or a markets-per-wal — TEST-032
- [~] `REQ-CONFIG-016` (08-market-registry.md:214) `deployCdpSpoke(def)` for a Spoke already recorded MUST re-approve it after an Aave DAO upgrade of its impleme — TEST-182, TEST-185
- [~] `REQ-CONFIG-074` (08-market-registry.md:215) `deployCdpSpoke`, for a new Spoke and for a re-approval, MUST revert with `InvalidSpoke` unless `implementatio — PROP-078, TEST-182, TEST-185, TEST-204
- [~] `REQ-CONFIG-083` (08-market-registry.md:216) Every Hub of the chain MUST be recorded with `recordHub(hub, tier)` (tier `StableLP`, `CorrelatedLP` or `Volat — TEST-065, TEST-185, TEST-204, TEST-273, TEST-285
- [~] `REQ-CONFIG-077` (08-market-registry.md:217) `deployCdpSpoke(def)` MUST, as one normal-delay timelock operation, record the standard Aave V4 Spoke that the — TEST-138, TEST-182, TEST-185, TEST-204
- [~] `REQ-CONFIG-078` (08-market-registry.md:218) `listCollateralMarket(def)` MUST: require the Spoke, Hub and integration of `REQ-CONFIG-033`; require the inte — TEST-138, TEST-139, TEST-213, TEST-295
- [~] `REQ-CONFIG-079` (08-market-registry.md:219) `enableDebtReserve(spoke, def)` MUST run the checks of `REQ-MREG-006` (funding Hub and asset, Aave reserve ide — TEST-185
- [~] `REQ-CONFIG-075` (08-market-registry.md:220) **Integration pinning.** `registerIntegration(integrationId, lpVault, pricing)` MUST pin, per AMM protocol per — TEST-264, TEST-296
- [~] `REQ-CONFIG-076` (08-market-registry.md:221) **Standard-Spoke settings at listing.** `deployCdpSpoke`, `listCollateralMarket` and `activateMarket` MUST run — TEST-138, TEST-185, TEST-204
- [~] `REQ-CONFIG-081` (08-market-registry.md:222) **Credit-line registry.** The MarketRegistry MUST keep, per (funding Hub, asset), the line the funding Hub's g — TEST-062, TEST-185, TEST-247, TEST-273
- [~] `REQ-CONFIG-082` (08-market-registry.md:223) **Pause per Hub, freeze per chain.** Pause state and reason MUST be keyed by Hub (`REQ-MREG-001`), so stopping — PROP-041, TEST-035, TEST-065
- [~] `REQ-MREG-006` (08-market-registry.md:227) `enableDebtReserve(spoke, def)` MUST revert with `InvalidSpoke` unless the Spoke is approved, and with `Invali — TEST-139, TEST-185, TEST-213, TEST-285, TEST-287
- [~] `REQ-MREG-007` (08-market-registry.md:228) The MarketRegistry's enabled debt-reserve set of each Spoke MUST equal the set of reserves the Spoke marks bor — TEST-185
- [~] `REQ-MREG-008` (08-market-registry.md:229) A debt reserve whose funding Hub prices the asset at a fixed value (GHO) MUST have `fixedPrice = true` and a p — TEST-139, TEST-185
- [~] `REQ-MREG-009` (08-market-registry.md:230) Each debt reserve's funding path MUST be explicit in its record: `fundingHub` is the Hub whose asset the CDP S — TEST-185, TEST-273
- [~] `REQ-MREG-010` (08-market-registry.md:231) `removeDebtReserve(spoke, reserveId)` MUST revert with `UnknownDebtReserve` unless the reserve is approved, an — TEST-213, TEST-228
- [~] `REQ-CONFIG-017` (08-market-registry.md:235) Every pool token MUST be listed with `listToken` before a market using it is registered, and every debt asset  — TEST-063, TEST-139, TEST-185, TEST-250
- [~] `REQ-CONFIG-018` (08-market-registry.md:236) A listed token's class MUST match the tier of every Hub whose markets use it (stablecoins only for Stable LP H — TEST-139
- [~] `REQ-CONFIG-021` (08-market-registry.md:237) Each token MUST have a primary, an alternate and a standby Chainlink route, each a list of one or two aggregat — TEST-139, TEST-231, TEST-250
- [~] `REQ-CONFIG-025` (08-market-registry.md:238) `pegModule` MUST record the Sky PSM a token's primary swap route uses (0 if none), never a GHO Stability Modul — TEST-054, TEST-250
- [~] `REQ-CONFIG-026` (08-market-registry.md:239) Listing a token, adding a feed definition (ParameterStore `setFeed`) or replacing a token's routes (`setPriceS — TEST-231
- [~] `REQ-CONFIG-027` (08-market-registry.md:240) `setPriceSource(token, primary, alternate, standby)` MUST re-run `REQ-CONFIG-021`, `REQ-CONFIG-034` (with the  — TEST-138, TEST-139, TEST-231, TEST-250
- [~] `REQ-MREG-027` (08-market-registry.md:246) `TokenDef` MUST record, beside the primary and alternate routes, a `standbyRoute` (`address[]`, one or two fee — TEST-139, TEST-185, TEST-221, TEST-228, TEST-231, TEST-250, TEST-287
- [~] `REQ-MREG-028` (08-market-registry.md:247) Standby switch: — TEST-062, TEST-066, TEST-168, TEST-231
- [~] `REQ-CONFIG-028` (08-market-registry.md:259) `listCollateralMarket` MUST be reachable only through the timelock at the normal delay, which enforces the pub — TEST-062, TEST-138
- [~] `REQ-CONFIG-029` (08-market-registry.md:260) Pool identity and orientation: the market's integration MUST validate the pool and shape in `bindMarket(market — TEST-138, TEST-139
- [~] `REQ-CONFIG-030` (08-market-registry.md:261) The shape MUST be valid for the integration: for concentrated liquidity, `tickLower < tickUpper`, both aligned — TEST-138, TEST-139
- [~] `REQ-CONFIG-031` (08-market-registry.md:262) Decimals rule: the vault-token decimals `d` MUST equal the value the market's integration fixes for its unit ( — TEST-138, TEST-139
- [~] `REQ-CONFIG-032` (08-market-registry.md:263) Vault-token and LPOracle binding: the listing batch deploys the market's vault token with the timelock's `Vaul — TEST-138, TEST-295
- [~] `REQ-CONFIG-033` (08-market-registry.md:264) Every pool token MUST be listed, and `spoke` MUST be a CDP Spoke registered by `deployCdpSpoke` whose integrat — TEST-138, TEST-139
- [~] `REQ-CONFIG-034` (08-market-registry.md:265) Common-mode guard: the alternate routes of the market's pool tokens MUST share no feed address pairwise, with  — TEST-139, TEST-231
- [~] `REQ-CONFIG-035` (08-market-registry.md:266) Raw-price bound: with `a0`, `a1` the current 8-decimal normalised answers of each token's primary route, `mulD — TEST-139
- [~] `REQ-CONFIG-036` (08-market-registry.md:267) Listing margin [SPEC-CF-004](07-risk-module.md#collateral-factor-math) MUST hold with `CF_LP` from [SPEC-CF-00 — TEST-138, TEST-231
- [~] `REQ-CONFIG-037` (08-market-registry.md:268) LPOracle seed: at registration the market's `lpOracle` MUST report `decimals() == 8` and `latestAnswer() > 0`  — TEST-138, TEST-139
- [~] `REQ-CONFIG-038` (08-market-registry.md:269) Consistency check: when the AMM protocol offers a time-weighted price, the TWAP source is the market's own poo — TEST-138
- [~] `REQ-CONFIG-039` (08-market-registry.md:270) Swap routes: for each pool token and each enabled debt asset of the Spoke other than that token, a primary (`k — TEST-054, TEST-138, TEST-245
- [~] `REQ-CONFIG-040` (08-market-registry.md:271) No route's `dependencies()` MAY include the market's own pool or its integration's LPVault, because unwinding  — TEST-054, TEST-229, TEST-296
- [~] `REQ-CONFIG-042` (08-market-registry.md:275) `activateMarket` MUST revert with `MarketNotRegistered` unless the market is `Registered`; it sets `hubAssetId — PROP-098, TEST-138, TEST-213
- [~] `REQ-CONFIG-043` (08-market-registry.md:276) Activation MUST run the RiskModule's full drift check `RISK_MODULE.checkAaveConfig(spoke, [marketId])` (the st — TEST-138
- [~] `REQ-CONFIG-044` (08-market-registry.md:277) Activation MUST require on the reserve's latest dynamic key: collateral factor `> 0` and `≤ RISK_MODULE.expect — TEST-138
- [~] `REQ-CONFIG-045` (08-market-registry.md:278) Activation MUST require the Spoke's `getLiquidationConfig()` to have `targetHealthFactor > 1e18` and equal to  — TEST-138
- [~] `REQ-CONFIG-046` (08-market-registry.md:279) Activation MUST require the market's parameters, caps and `minPledgeUsd` to be set in the ParameterStore and t — TEST-138
- [~] `REQ-CONFIG-047` (08-market-registry.md:280) Activation MUST require the vault-token reserve to be neither paused nor frozen, the market's LPOracle to be L — TEST-054, TEST-138, TEST-250
- [~] `REQ-CONFIG-048` (08-market-registry.md:281) `cancelRegistration` (short delay) MUST work only for a `Registered` market (else `MarketNotRegistered`), MUST — PROP-098, TEST-213, TEST-229, TEST-252, TEST-295
- [~] `REQ-CONFIG-073` (08-market-registry.md:282) A listing MUST carry one normal delay and one short delay: the listing batch with `listCollateralMarket` (and  — TEST-054, TEST-138
- [~] `REQ-MREG-030` (08-market-registry.md:284) Relisting: `cancelRegistration` keeps the cancelled `marketId` reserved for its (Spoke, market key) pair. `lis — PROP-098, TEST-138, TEST-213, TEST-229, TEST-252, TEST-295, TEST-296
- [~] `REQ-MREG-032` (08-market-registry.md:285) `enableDebtReserve` (for reserve `r`, against every Active or Offboarding market of the Spoke) and `activateMa — TEST-054, TEST-185, TEST-245
- [~] `REQ-MREG-033` (08-market-registry.md:287) **Settlement debt reserve of a market.** Each market MUST record `settlementReserve(marketId)`, the debt reser — TEST-138, TEST-213
- [~] `REQ-MREG-034` (08-market-registry.md:288) **Market-count limit.** `listCollateralMarket` MUST revert `MarketCountLimit(MAX_MARKET_COUNT)` when it would  — TEST-168, TEST-295
- [~] `REQ-MREG-015` (08-market-registry.md:292) `setMarketOffboarding(marketId)` MUST revert with `MarketNotActive` unless the market is `Active`, set `Offboa — PROP-098, TEST-213
- [~] `REQ-CONFIG-080` (08-market-registry.md:293) **Offboarding ends.** `setMarketOffboarding(marketId)` records `WindDownState{offboardedAt = now, unusedLastSt — PROP-098, TEST-062, TEST-138, TEST-213, TEST-252, TEST-272, TEST-295
- [~] `REQ-MREG-001` (08-market-registry.md:297) The MarketRegistry MUST hold one `PauseState` per registered Hub, initially `None`, changed only by these tran — PROP-041, TEST-065, TEST-101
- [ ] `REQ-MREG-002` (08-market-registry.md:298) Effects: Frozen MUST block new pledges by accounts with zero debt on every debt reserve, and every borrow; it  — TEST-192, TEST-193, TEST-235 (only excluded checks: uses a stand-in for MarketRegistry)
- [~] `REQ-MREG-003` (08-market-registry.md:299) The pause state MUST have no on-chain expiry. Avana's only restrictions on new activity are the pause state wi — TEST-035, TEST-065, TEST-101, TEST-168
- [~] `REQ-MREG-004` (08-market-registry.md:300) `freeze()` MUST require `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`; `pause(reason)`, `unfreeze()` an — PROP-041, TEST-062, TEST-063, TEST-065, TEST-066, TEST-101, TEST-168, TEST-229
- [~] `REQ-MREG-005` (08-market-registry.md:301) `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` MUST be held only by the timelock: `_grantRole` MUST revert `Admi — TEST-062, TEST-065, TEST-066, TEST-242
- [~] `REQ-MREG-024` (08-market-registry.md:303) `pause(reason)` MUST record a `PauseReason` with the Paused state: `General` (new activity stopped; rescue top — PROP-041, TEST-065, TEST-101
- [~] `REQ-MREG-019` (08-market-registry.md:309) `freezeAddress(account)` MUST require `APPLICATION_FREEZE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short  — PROP-071, TEST-062, TEST-229
- [~] `REQ-MREG-020` (08-market-registry.md:310) `freezeAddress` MUST revert `ProtectedAddress(account)` for: `TIMELOCK` and `AAVE_GOVERNANCE_EXECUTOR`; the Aa — PROP-071, TEST-054, TEST-185, TEST-229, TEST-264, TEST-285, TEST-289, TEST-296
- [~] `REQ-MREG-035` (08-market-registry.md:311) **Record of an integration's AMM contracts.** `recordIntegrationContracts(integrationId, contracts)` and `fina — TEST-054, TEST-138, TEST-229, TEST-296
- [~] `REQ-MREG-021` (08-market-registry.md:312) `freezeAddress` MUST NOT check any keeper floor and MUST NOT read LPVaultSwap's registry: a guardian can alway — PROP-071, TEST-229
- [~] `REQ-MREG-022` (08-market-registry.md:313) `unfreezeAddress(account)` MUST require `APPLICATION_ADMIN` at the normal delay, revert `AddressNotFrozen(acco — TEST-062, TEST-063, TEST-066, TEST-204, TEST-229
- [~] `REQ-MREG-023` (08-market-registry.md:314) The freeze MUST be read only on new-activity paths, by the calling wallet: the AaveAdapter (a frozen caller's  — TEST-229
- [~] `REQ-MREG-025` (08-market-registry.md:320) The MarketRegistry MUST store, per key (market key `bytes32(marketId)`, debt key `keccak256(abi.encode(spoke,  — TEST-066, TEST-204, TEST-228, TEST-252
- [~] `REQ-MREG-026` (08-market-registry.md:321) `recordBreach(key, reasons)` MUST revert `NotRiskModule` unless `msg.sender == RISK_MODULE`; it ORs the securi — TEST-062, TEST-228
- [~] `SPEC-BRK-005` (08-market-registry.md:322) **Seizure surge (monitoring alert, no on-chain trip).** Monitoring alerts when the units seized in one market  — TEST-228
- [~] `SPEC-BRK-006` (08-market-registry.md:323) **Swap-route failures (monitoring alert, no on-chain trip).** Monitoring alerts at 3 failed primary swap-route — TEST-228
- [~] `REQ-MREG-031` (08-market-registry.md:324) `activeMarketCount(spoke)` MUST return the number of markets on `spoke` whose status is `Active` or `Offboardi — TEST-138, TEST-204, TEST-213
- [~] `REQ-CONFIG-059` (08-market-registry.md:328) Each market MUST hold, per pool token and enabled debt asset, a fixed primary swap route and a pre-approved ba — TEST-054
- [~] `REQ-CONFIG-060` (08-market-registry.md:329) Adding or changing a route MUST go through `setRoute` at the normal delay, MUST re-run `REQ-CONFIG-039` and `R — TEST-054, TEST-252, TEST-296
- [~] `REQ-CONFIG-061` (08-market-registry.md:330) `disableRoute` (short delay) MUST set the record's status to `Disabled` until `restoreRoute` or `setRoute` cha — TEST-054, TEST-296
- [~] `REQ-CONFIG-062` (08-market-registry.md:331) `restoreRoute` (short delay) MUST revert with `NotPreviouslyApproved` unless `route` is in that slot's set of  — TEST-054, TEST-066, TEST-252, TEST-296
- [~] `REQ-CONFIG-063` (08-market-registry.md:332) `getRoute(marketId, token, asset, kind)` MUST return the route and `usable = (status == Active)`; LPVaultSwap  — TEST-054
- [~] `REQ-MREG-011` (08-market-registry.md:336) There MUST be no buy route: the liquidation caller funds the repayment in the debt asset itself, from its own  — TEST-053
- [~] `REQ-MREG-012` (08-market-registry.md:337) Swap-route containment MUST use `disableRoute` and `restoreRoute` per (market, token, asset, kind) at the shor — TEST-054
- [~] `REQ-MREG-013` (08-market-registry.md:338) There MUST be no sell-back route: leftover value of a liquidation is paid in the debt asset that was repaid (k — TEST-053
- [~] `REQ-MREG-014` (08-market-registry.md:339) `getRoute(marketId, token, asset, kind)` MUST return the route and `usable = (status == Active)`, and `(addres — TEST-054, TEST-204
- [~] `REQ-MREG-016` (08-market-registry.md:343) The MarketRegistry MUST hold no in-kind settlement window: `enableInKind`, `disableInKind`, `isInKindEnabled`  — TEST-053
- [~] `REQ-MREG-029` (08-market-registry.md:344) There MUST be no automatic in-kind trigger: `setInKindAutoTrigger`, `autoEnableInKind`, the listing flag and ` — TEST-053
- [~] `REQ-CONFIG-064` (08-market-registry.md:348) Every view MUST be `view`, never revert for a listed market, and return the values in force at the current blo — TEST-168
- [~] `REQ-CONFIG-065` (08-market-registry.md:354) Any registration check fails | `listCollateralMarket` reverts with the failing check's error; the listing batc — TEST-138
- [~] `REQ-CONFIG-066` (08-market-registry.md:355) Any activation check fails, such as a wrong Aave flag or CF in the DAO payload | `activateMarket` reverts; the — TEST-138
- [~] `REQ-CONFIG-068` (08-market-registry.md:356) A market's swap routes cannot settle | There is no in-kind window to end (`Q-401`); liquidations of that marke — TEST-053, TEST-228
- [~] `REQ-MREG-017` (08-market-registry.md:357) A pause-state call is not a valid transition or comes from a caller without the role | The call reverts (`Alre — PROP-041, TEST-065, TEST-066, TEST-101
- [~] `REQ-MREG-018` (08-market-registry.md:358) A debt-reserve, swap-route, credit-line or deployment call fails its checks | The call reverts with `InvalidSp — TEST-185
- [~] `REQ-CONFIG-069` (08-market-registry.md:359) MarketRegistry implementation broken or reverting | Reads fail: pledges, re-credits, borrow, withdraw-with-deb — TEST-229, TEST-243

## TEST rows (48: 0 verified, 0 failed, 36 not run, 12 unlinked)

- [~] `TEST-012` [unit] Pledge gates: a new account (no debt on any debt reserve) requires the market Live; a top-up is allowed into a
- [~] `TEST-171` [unit] Market identity from the vault token: during a pledge Collateralization takes the market ID and the LPOracle o
- [ ] `TEST-030` [unit] Fixed targets: the proxy calls only the Spoke it was initialized with; vault-token reserve IDs are derived at  (only excluded checks: uses a stand-in for MarketRegistry)
- [~] `TEST-033` [unit] Drift checks on pledge of a new account and on borrow and withdraw-with-debt (`RiskModule.checkAaveConfig`, re
- [~] `TEST-035` [unit] Per-market containment: Avana has no per-function or per-market pause selector (inventory over the AaveAdapter
- [~] `TEST-295` [unit, integration] Market-count limit (2.8 `REQ-MREG-034`): with `MAX_MARKET_COUNT = N`, markets 1 to N list and the next pair re
- [~] `TEST-296` [unit] Integration record (2.8 `REQ-MREG-035`, `REQ-CONFIG-040`): no route of an integration's markets is accepted un
- [~] `TEST-053` [unit] No in-kind settlement: LPVaultSwap has no in-kind branch and the MarketRegistry has no in-kind window, so `ena
- [~] `TEST-054` [unit] Routes: a fixed swap route from each pool token into each debt asset the CDP Spoke can borrow (Uniswap v3, Sli
- [~] `TEST-063` [unit] Delay classes: an operation gets the short delay (43,200 s) only when every call in it is on the short-delay l
- [~] `TEST-065` [unit] Pause-state transitions: `freeze()` moves None → Frozen for `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMI
- [~] `TEST-066` [access-control] Guardian powers: the Emergency Guardian (3-of-5) and the Aave Protocol Guardian hold `APPLICATION_PAUSE_GUARDI
- [~] `TEST-162` [unit] Pause-state readers: the AaveAdapter reads `MarketRegistry.pauseState()` and `pauseReason()` only in `pledge`,
- [~] `TEST-168` [access-control] Pause location: the only pause state is the MarketRegistry's `PauseState`; the AaveAdapter, RiskModule, Parame
- [~] `TEST-185` [unit] `MarketRegistry.deployCdpSpoke(def)` reverts `InvalidSpoke` when any Avana collateral reserve on the Spoke has
- [ ] `TEST-192` [unit] Pause matrix: for each state and reason and each action, with every other check passing: None allows new pledg (only excluded checks: tag on a test named for another row; uses a stand-in for MarketRegistry)
- [~] `TEST-213` [unit] Market offboarding: `setMarketOffboarding(marketId)` (short delay) sets status `Offboarding`; afterwards pledg
- [~] `TEST-098` [invariant] Keeper floor: the number of active (registered and unfrozen) committed operators on LPVaultSwap never falls be
- [~] `TEST-101` [invariant] Pause-state machine: a guardian handler calls `freeze`, `pause`, `unfreeze` and `unpause` with every role (Eme
- [ ] `TEST-193` [invariant] Exits and liquidation under every pause state and reason (`fail_on_revert` on for the live actions): a pause h (only excluded checks: tag on a test named for another row; uses a stand-in for MarketRegistry)
- [ ] `TEST-211` [invariant] Accounts and multi-asset accounting: handlers pledge, borrow, repay and liquidate on two Borrow Spokes, severa (only excluded checks: uses a stand-in for MarketRegistry)
- [ ] `TEST-215` [invariant] Multi-actor invariant suite (Foundry invariant test with handlers, extending `TEST-082`). Actors: borrowers wi (only excluded checks: tag on a test named for another row)
- [ ] `TEST-218` [invariant] Withdrawal and liquidation cascades: N accounts (N up to 200) opened near HF 1.10 in two markets; outside LPs  (only excluded checks: uses a stand-in for MarketRegistry)
- [~] `TEST-129` [fork] Guardian rehearsal, before launch and quarterly: the Emergency Guardian (3-of-5) and the Aave Protocol Guardia — checked outside contracts/: quarterly guardian rehearsal with the real Safe payloads on a fork of the deployed chain
- [~] `TEST-182` [unit, fork] Implementation drift through `MarketRegistry.spokeImplementationStatus`: `Spoke.extSload(0x3608…2bbc)` equals 
- [ ] `TEST-195` [fork] Exit inside the delay: the governance multisig schedules an AaveAdapter upgrade to a hostile implementation (n (only excluded checks: uses a stand-in for MarketRegistry)
- [~] `TEST-221` [fork] Token edge cases. A fee-on-transfer mock pool token is rejected at listing; a fee switched on after listing on
- [ ] `TEST-133` [hostile] Hostile MarketRegistry and ParameterStore: remapping a market to an attacker pool, Spoke, vault token or debt  (only excluded checks: uses a stand-in for MarketRegistry)
- [~] `TEST-138` [deployment-check] Listing order: token and feed are deployed and a valid price is seeded before the DAO payload; the governance 
- [~] `TEST-139` [deployment-check] Listing guards reject a market unless: `d0 + d1` is even; every feed's normalised `minAnswer` is ≥ 1; the pool
- [~] `TEST-204` [deployment-check] Debt-reserve set: for every CDP Spoke, the set of borrowable reserves read on-chain equals `MarketRegistry.get
- [~] `TEST-225` [invariant] Governance drift sequences: random tighten, loosen and structural operations within bounds, scheduled and exec
- [~] `TEST-228` [unit] Circuit breakers: each on-chain trigger (ORACLE, POOL_SHARE, ISSUER, DEFICIT, MANUAL) trips and blocks only it
- [~] `TEST-229` [unit] Address freeze: a frozen wallet's new pledge (non-rescue), borrow (as caller or receiver), withdraw-with-debt,
- [~] `TEST-231` [unit] Standby switch: the pause guardian's `useStandbyRoute` takes effect at once, increments `priceRouteVersion`, a
- [ ] `TEST-234` [unit] No automatic in-kind: repeated primary-route failures in a market change nothing about how its liquidations se (only excluded checks: uses a stand-in for MarketRegistry)
- [~] `TEST-242` [access-control] Admin grant: on every upgradeable Avana contract, `grantRole(APPLICATION_ADMIN, a)` and `grantRole(DEFAULT_ADM
- [~] `TEST-243` [hostile] Hostile MarketRegistry: an implementation that returns an empty debt set, `isApprovedDebtReserve` false for ev
- [~] `TEST-245` [unit] Two-leg liveness: `setBuySlippageAllowanceBps`, `enableDebtReserve` and `activateMarket` revert `LivenessBound
- [~] `TEST-250` [unit] Feed cadence: a feed is fresh while its age is at most its own heartbeat, read from the feed's configuration a
- [~] `TEST-252` [unit] Small fixes: grace starts at the newest leg in use of the fresh price, never after `block.timestamp`, includin
- [~] `TEST-273` [unit] Cross-Hub credit line: the funding Hub owns the cap of every line drawing its asset; the registry sums the `dr
- [ ] `TEST-274` [invariant] Draw gate: handlers borrow, accrue interest, cut a Spoke's `drawCap` below its drawn amount and record deficit (only excluded checks: uses a stand-in for MarketRegistry)
- [ ] `TEST-281` [fork] One-sided unwind stress: for each concentrated-liquidity market, a seizure at and beyond each range edge retur (only excluded checks: uses a stand-in for MarketRegistry)
- [ ] `TEST-283` [unit] Readiness listing guards for AMM protocols beyond Uniswap v3 and Slipstream: a Uniswap v2 pricing that reads ` (only excluded checks: tag on a test named for another row)
- [~] `TEST-285` [unit] Flash source that borrows from a Hub (`ATTACK-195`): a mock flash source whose own address is a Spoke but whos
- [~] `TEST-287` [fork] Transfer fee on a debt asset (`ATTACK-197`): on a fork with a USDT debt reserve, Tether's `basisPointsRate` is
- [~] `TEST-289` [unit] Public helper instance (2.11 `REQ-HELPER-010`): the payer and the payout recipient are `msg.sender` of `flashL

## PROP rows (7: 5 verified, 0 failed, 1 not run, 1 unlinked)

- [~] `PROP-021` [Certora] LPVaultSwap has no in-kind branch and the MarketRegistry has no in-kind window: neither contract exposes `enab
- [x] `PROP-034` [Certora] Every restricted selector of every upgradeable Avana contract (AaveAdapter, MarketRegistry, ParameterStore, Ri — MarketRegistryRoles job 64b019d802284238bcda1b390f66903c
- [x] `PROP-041` [Certora] `MarketRegistry.pauseState()` and `pauseReason()` change only by `freeze` (None → Frozen; `APPLICATION_FREEZE_ — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [x] `PROP-061` [Certora] Debt-reserve set: `MarketRegistry.activateMarket` and the RiskModule's drift check revert (`ActivationCheckFai — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [x] `PROP-070` [Certora] Inductive admin invariant: for every upgradeable Avana contract (not the ProxyManager, which is immutable with — AvanaTimelock job 51a4165fa4db461e888652ad6b397943
- [x] `PROP-071` [Certora] Address freeze: `freezeAddress(a)` succeeds only if `a` is not in the protected set, `a` is not frozen, and th — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [ ] `PROP-096` [Certora] Flash source never a Hub: `MarketRegistry.setFlashSource(src)` reverts `InvalidRoute` and every flash call rev (only excluded checks: uses a stand-in for MarketRegistry)

## INV (23: 8 verified, 0 failed, 10 not run, 5 unlinked)

- [x] `INV-011` Transfer allowlist. A market's vault-token balances change only on these paths, and every other `transfer` and — PROP-008, PROP-055, TEST-022, TEST-087, TEST-189 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_008_movementsOnlyOnAllowedPaths
- [~] `INV-013` A proxy's vault-token supply on the Spoke decreases only through (a) `Spoke.withdraw` called by the proxy thro — PROP-011, TEST-090, TEST-109, TEST-150, TEST-180, TEST-189, TEST-209
- [~] `INV-017` Collateralization and each LPVault obtain an AMM protocol's position manager and factory only from the LPVault — PROP-083, TEST-010, TEST-030, TEST-108, TEST-114, TEST-116, TEST-171, TEST-264, TEST-265
- [ ] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin — TEST-031, TEST-107, TEST-130, TEST-133, TEST-195 (only excluded checks: uses a stand-in for MarketRegistry)
- [ ] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe — TEST-027, TEST-106 (only excluded checks: uses a stand-in for MarketRegistry)
- [ ] `INV-022` Calldata built by `packages/protocol` asks a user for only two kinds of approval: an approval of exactly one p
- [~] `INV-023` A borrow or a withdrawal that leaves debt completes only after the AaveAdapter's call to `RiskModule.preBorrow — PROP-031, PROP-046, TEST-019, TEST-027, TEST-028, TEST-095, TEST-155
- [~] `INV-024` A borrow, a withdrawal that leaves debt, and a partial removal that leaves debt complete only if: the caller ( — TEST-019, TEST-028, TEST-095, TEST-229
- [~] `INV-029` No new-account pledge, borrow or withdrawal that leaves debt completes while the RiskModule's drift check find — PROP-078, TEST-012, TEST-033, TEST-114, TEST-268
- [x] `INV-073` A CDP Spoke's borrowable reserves through Avana are exactly the debt reserves the MarketRegistry approves for  — PROP-061, TEST-019, TEST-030, TEST-114 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [~] `INV-030` `LPVaultSwap.liquidate`, the only liquidation entry point (`INV-062`), admits any caller that is not a frozen  — PROP-022, PROP-066, TEST-049, TEST-055, TEST-160, TEST-174
- [x] `INV-040` Flash and swap callbacks. `liquidate` takes no flash loan and has no flash callback (Q-404). The core flash so — PROP-036, PROP-053, PROP-080, TEST-046, TEST-052, TEST-055, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [x] `INV-095` Flash source rules. No liquidation takes a flash loan inside LPVaultSwap (Q-404): `liquidate` calls no lender, — PROP-080, PROP-096, PROP-097, TEST-046, TEST-052, TEST-055, TEST-267, TEST-285, TEST-287, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [~] `INV-043` For any proxy with debt in reserve `r`, `AaveAdapter.repay(borrower, spoke, r, maxRepaySpend, repayAll, deadli — PROP-057, PROP-066, TEST-029, TEST-075, TEST-099, TEST-132, TEST-162, TEST-193
- [~] `INV-045` When the proxy has no debt on its Spoke (`spoke.getUserAccountData(proxy).borrowCount == 0`), the depositor's  — PROP-057, PROP-066, TEST-016, TEST-018, TEST-099, TEST-132, TEST-162, TEST-192, TEST-193, TEST-195, TEST-218, TEST-228, TEST-229
- [x] `INV-047` Every ParameterStore setter for `slippageAllowanceBps`, `graceHealthFactor`, `graceDuration`, `consistencyTole — PROP-042, TEST-064, TEST-225 — ParameterStore job 5cf1a73b625f4624b65c99923de6cb24
- [ ] `INV-075` No contagion from pool-level failures. A failure confined to collateral market `m′` (its pool, its LPOracle st
- [~] `INV-081` Stops never reach exits or liquidation. The application pause state and reason, the market and debt breakers a — PROP-066, TEST-218, TEST-228, TEST-229
- [x] `INV-049` Pause-state transitions. The MarketRegistry holds one `PauseState` and one `PauseReason` for Avana, and they c — PROP-041, PROP-057, TEST-065, TEST-101, TEST-192, TEST-193 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [~] `INV-065` Implementation changes only by timelock; proxy code never changes. A PositionProxy's code is fixed at creation — PROP-010, PROP-058, TEST-025, TEST-062, TEST-063, TEST-089, TEST-130, TEST-168, TEST-172, TEST-191
- [x] `INV-084` Admin roles only for the timelock. On every upgradeable Avana contract, `DEFAULT_ADMIN_ROLE` and `APPLICATION_ — PROP-070, TEST-062, TEST-212, TEST-242 — AvanaTimelock job 51a4165fa4db461e888652ad6b397943
- [x] `INV-085` Address freeze bounds. `freezeAddress` never covers the protected set (the AvanaTimelock, the Aave governance  — PROP-071, TEST-229 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [ ] `INV-057` Draw gate, per debt asset. No borrow completes that leaves a CDP Spoke's `drawn + premium + deficit` on its fu — TEST-274 (only excluded checks: uses a stand-in for MarketRegistry)

## ATTACK (12: 0 verified, 0 failed, 9 not run, 3 unlinked)

- [~] `ATTACK-005` Fake backing through an upgradeable market map — TEST-011, TEST-138, TEST-171
- [~] `ATTACK-033` Re-pointing proxies or the LPVault through configuration — TEST-138, TEST-171
- [ ] `ATTACK-035` Hostile RiskModule or Adapter blocks repay or exits — TEST-029, TEST-099, TEST-107, TEST-132, TEST-193, TEST-229, TEST-243 (only excluded checks: uses a stand-in for MarketRegistry)
- [ ] `ATTACK-086` Emergency pause used to halt liquidation
- [~] `ATTACK-098` Pause guardian used as an instant loosen key — TEST-066
- [~] `ATTACK-121` Listing on a Spoke that is not a reviewed standard Spoke with the required settings — TEST-138, TEST-182, TEST-185
- [~] `ATTACK-132` Pause-state misuse — TEST-065, TEST-229
- [~] `ATTACK-136` Debt-reserve offboarding with open debt — TEST-213
- [~] `ATTACK-139` Compromised guardian uses address freeze, breakers and the standby switch — TEST-066, TEST-228, TEST-229, TEST-231
- [~] `ATTACK-140` Standby switch to a stale or diverged route — TEST-231
- [~] `ATTACK-163` Cross-Hub credit line drawn past the funding Hub's limit — TEST-273
- [ ] `ATTACK-201` Restoring a route that governance replaced for cause

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
