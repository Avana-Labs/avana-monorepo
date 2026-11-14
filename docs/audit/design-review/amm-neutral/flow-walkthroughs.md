# AMM-neutral architecture: flow walkthroughs

Date: 2026-11-10. Scope: every user, keeper and governance flow of `spec/03-operations/` (FLOW-001 to FLOW-009), read against `spec/02-contracts/` (2.1 to 2.18), under the proposed AMM-neutral architecture:

- many CDP Spokes per Hub, one collateral market per CDP Spoke, three Hubs (Stable, Correlated, Volatile);
- an immutable LPVault and an immutable Collateralization ledger per CDP Spoke; a Lock, AaveAdapter, LPVaultSwap, MarketRegistry, ParameterStore, RiskModule, SettlementBudget and PayoutEscrow per Hub; a VaultTokenFactory, ProxyManager, Lens and Timelock per chain;
- debt reserves funded by another Hub (cross-Hub credit lines), GHO first, then non-GHO assets;
- a PositionProxy per wallet and CDP Spoke, pinned to one implementation (no beacon), with opt-in migration;
- launch AMM protocols: Uniswap v3 on Ethereum mainnet and Aerodrome Slipstream (unstaked NFTs) on Base.

Method: each flow is listed step by step (caller, call, state change, checks), then marked with:

- **(a)** assumptions the step makes about other contracts, external protocols or the user;
- **(b)** contradictions between pages, or with the new architecture;
- **(c)** states where the flow breaks, gets stuck or loses user funds;
- **(d)** ways a third party can exploit or grief the user.

Each problem is a finding `AMMN-FLOW-NN` in [Findings](#findings). Severity scale: **Critical** (a launch flow cannot run, or funds are lost without an attacker), **High** (funds stuck or loss under a plausible state or attack, or a contradiction that changes contract shape), **Medium** (a flow degrades, or an unstated assumption whose failure needs operator action), **Low** (documentation or indexing defects).

Spec IDs cite the current pages: `DEP` (3.1), `BOR` (3.2), `REP` (3.3), `WDR` (3.4), `LIQ` (3.5), `EMG` (3.6), `FEE` (3.7), `MKT` (3.8), `DEF` (3.9), `REQ-*`/`SPEC-*` (2.x).

---

## 1. Personas and what each one depends on

| Persona | Flows used | Contracts touched | Depends on |
|---|---|---|---|
| Borrower | pledge, borrow, repay, deleverage, partial removal, re-credit, withdraw, collect fees, proxy migration | AaveAdapter (Hub), PositionProxy (wallet × Spoke), Collateralization and LPVault (Spoke), VaultToken (market), Aave Spoke and Hub(s) | Lock membership of the Spoke's vault and ledger (FLOW-01); price feed freshness on the chain (FLOW-03); a migration path (FLOW-04) |
| LP who does not borrow | pledge, collect fees, debt-free withdraw | same, minus borrow | debt-free exit never gated (FLOW-12); caps it consumes (FLOW-16) |
| Lender on the Lend Spoke | supply, withdraw on the funding Hub | Aave Lend Spoke, Hub | losses of every Spoke on every Hub that draws from its reserve (FLOW-05, FLOW-15) |
| Approved keeper | `liquidate`, `reportRecoveryShortfall`, `settlePending`, `poke` | LPVaultSwap (Hub), Collateralization, LPVault, routes, FlashMinter | GHO flash mint and GHO routes on the chain (FLOW-02); keeper floor per LPVaultSwap (FLOW-25) |
| Permissionless liquidator | `liquidatePermissionless`, `settlePending` | same, no budget, no in-kind | own GHO or a flash mint (FLOW-02); stable pool spot (FLOW-09) |
| Governance (4/7 Safe, Timelock) | listing, parameter changes, routes, keepers, offboarding, oracle switch | Timelock (chain), MarketRegistry, ParameterStore, LPOracle (Hub/market) | Aave DAO payloads per Spoke (FLOW-21); cross-chain execution (FLOW-03, FLOW-19) |
| Guardian (3/5) | `freeze`, `pause(reason)`, standby route switch, breaker trip, address freeze | MarketRegistry (per Hub) | one pause per Hub per chain (FLOW-19) |

---

## 2. Flow walkthroughs

Notation: `W` wallet, `S` CDP Spoke, `H` home Hub, `H'` funding Hub of a debt reserve, `P` proxy, `VT` vault token, `AD` AaveAdapter, `CO` Collateralization, `LV` LPVault, `SW` LPVaultSwap, `MR` MarketRegistry, `RM` RiskModule, `PM` ProxyManager, `O` LPOracle, `L` Lock. The "Marks" column names findings.

### 2.1 Deposit / pledge (FLOW-001, `DEP-001`…`DEP-018`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| DEP-001 | `W` → `AD.pledge(S, VT, tokenId, deadline)` | Lock acquired | `LockHeld` | (b) one protocol-wide Lock with four immutable members (`REQ-LOCK-004`, `REQ-LOCK-024`); a per-Spoke `LV`/`CO` cannot be a member → FLOW-01 |
| DEP-002 | `AD` → `MR.pauseState/pauseReason/getSpoke/marketOfVaultToken`, `VT.spoke()` | none | deadline, `MintPathSuspect`, approved Spoke, `VT.spoke()==S` | (a) `MR` is the Hub's registry; pause is per Hub → FLOW-19 |
| DEP-003 | `AD` → `PM.deployProxy(W, S)` | proxy deployed, `proxyOf[W][S]` bound forever | only "the Adapter" may deploy; frozen wallet refused | (b) `BeaconProxy` vs pinned proxies; (b) one Adapter vs one per Hub calling a per-chain `PM`; (d) proxy-address squatting by another Hub's Adapter → FLOW-04, FLOW-18 |
| DEP-004 | `AD` → `S.getUserAccountData(P)`, `MR.isFrozenAddress(W)` | `requireRescue` | Frozen/new-account rule | (a) address freeze is per Hub → FLOW-19 |
| DEP-005 | `AD` → `VT.isValidProxy/addValidProxy`; reads `gapBefore` | proxy registered in the token | — | (a) with a standard Spoke this registry is also the liquidation access control → FLOW-13 |
| DEP-006 | `AD` → `CO.pledge(W, P, VT, tokenId, requireRescue)` | — | `VAULT_TOKEN_FACTORY.tokenOfPool(VT.pool())==VT`, `VT.collateralization()==CO`, `VT.lpVaultSwap()` | (b) one token per pool → FLOW-11 |
| DEP-007 | `CO` → NFPM `positions`, `UNISWAP_FACTORY.getPool(t0,t1,fee)`, pool `tickSpacing`, `slot0` | — | canonical NFPM, pool match, exact full range, `slot0.unlocked`, no open record | (b) Slipstream keys pools by tickSpacing and has a different `slot0` layout → FLOW-10; (b) full range only vs "market's fixed range" → FLOW-08 |
| DEP-008 | `CO` → `LV.receiveNft(W, tokenId)` → `NFPM.transferFrom` | NFT in custody, `depositorOf[tokenId]=W` | caller owns NFT, per-token approval | (a) LV member of the Lock → FLOW-01 |
| DEP-009 | `CO` → `NFPM.positions(tokenId)` | `L` read | `0 < L ≤ MAX_CREDITED_LIQUIDITY` | (a) bound sized for full-range `L`; a narrow range gives far more `L` per dollar → FLOW-08 |
| DEP-010 | `CO` → `O.poke()` | feed cache | — | (a) Chainlink heartbeats ≤ 3,600 s (`MKT-005`), no L2 sequencer check → FLOW-03 |
| DEP-011 | `CO` → `RM.checkPledge(...)` | — | market active, price state, Aave state, caps, pool share, breakers, `minPledgeUsd`, rescue | (a) pool share against harmonic-mean in-range liquidity is full-range logic → FLOW-08; (d) a debt-free LP can fill every cap → FLOW-16 |
| DEP-012 | `CO` writes the record | record with immutable `depositor`, `proxy`, `VT`; counters | charge bounds | (b) "proxy never changes while the record is open" blocks migration → FLOW-04 |
| DEP-013…017 | `AD` → `VT.mint(P, L)`; `P` → `VT.approve`, `S.supply`, `S.setUsingAsCollateral` | supplied shares | reserve not paused/frozen, Hub `addCap` | (a) Hub `addCap` in whole tokens and `uint40`, sized from `stressFloorUsd` per whole token of a full-range unit → FLOW-08 |
| DEP-018 | `AD` post-checks | Lock released | shares delta, backing gap | — |
| DEP-019…025 | `W` → `AD.recredit(...)` | `added = live − credited` booked and minted | as a top-up of `added` | (d) anyone can `increaseLiquidity` on a pledged NFT; harmless donation; same Lock and Slipstream issues as above |

### 2.2 Borrow GHO and a non-GHO asset (FLOW-002, `BOR-001`…`BOR-017`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| BOR-001/003/015/016 | `W` → `AD.borrow(S, r, amount, receiver, deadline, minHF, nonce)` | Lock | deadline, amount, pause `None` only, wallet and receiver not frozen | (a) per-Hub pause and freeze lists → FLOW-19 |
| BOR-002 | `AD` | `P = proxyOf[W][S]` | `NoProxy` | (b) after migration two proxies exist for `(W, S)` → FLOW-04 |
| BOR-005 | `AD` → `MR.isApprovedDebtReserve`, Hub views | — | receiver refusal list names "the Hub of the reserve or the Avana Stable LP Hub" | (b) single named Hub; must list every Hub on the chain and every CDP Spoke → FLOW-17 |
| BOR-004 | `AD` | `borrowNonce[P] += 1` | nonce | — |
| BOR-006/007/017 | `AD` → `RM.preBorrowCheck`; pokes; breakers read `GHO.balanceOf(SETTLEMENT_BUDGET)`, Coverage Spoke of `(H', asset)`, `activeKeeperCount` | caches | price states, drift (incl. `LIQUIDATION_MANAGER`), breakers, keepers | (a) for a non-GHO reserve, a DebtOracle and buy/sell-back routes exist on this chain; (b) breakers read the home Hub's budget and the funding Hub's coverage → FLOW-05; (b) `LIQUIDATION_MANAGER` drift check vs standard Spoke → FLOW-13 |
| BOR-008 | `P` → `S.borrow(r, amount, P)` → `H'.draw` | debt on `H'` | `drawCap` per Spoke; "drawCaps sum to at most each asset's credit line" | (a) the sum across Spokes and Hubs is not enforced on-chain → FLOW-06 |
| BOR-009/013/010 | `P` measures, transfers to receiver | — | delta == amount | — |
| BOR-011 | `AD` → `RM.postHealthCheck` | — | `hfEx ≥ max(1.10, 1.05, minHF)` | (b) health factor now covers one market only; no cross-margin between a wallet's markets → FLOW-07 |
| BOR-014 | event, unlock | — | — | — |

Non-GHO specifics: liquidation of that reserve requires flash-minted GHO bought into the debt asset (`LIQ-070`) and a sell-back; on Base neither a GHO FlashMinter nor a GSM exists (FLOW-02); for an ETH debt against an ETH/LST market the round trip collateral → GHO → ETH adds two swaps through GHO depth (FLOW-14).

### 2.3 Repay, by anyone (FLOW-003, `REP-001`…`REP-012`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| REP-001/002/003 | `Y` → `AD.repay(W, S, r, maxSpend, repayAll, deadline)` | Lock | deadline; no registry read | (a) `Y` must pick the Adapter of `S`'s home Hub; the Lens must route it |
| REP-012 | `AD` | `P = proxyOf[W][S]` | `NoProxy` | (c) after migration a stale binding sends the repayment to the wrong proxy → FLOW-04 |
| REP-004/005 | `AD` → `P.totalDebt(r)` | sizing | cap rule | — |
| REP-006…009 | `AD` → `A.transferFrom(Y, P, x)`; `P` → `S.repay` → `H'.restore` | debt down, refund | `H'.restore` requires the Spoke active and not halted | (c) a Hub halt of the CDP Spoke blocks every repay → FLOW-12; (c) a pinned proxy with a bug in `repay` cannot be fixed → FLOW-04 |
| REP-010/011 | completion check, event | — | — | — |

### 2.4 Deleverage / repay with collateral (`REP-013`…`REP-021`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| REP-013/015 | `W` → `AD.repayWithCollateral(p)` | Lock | `Paused` (either reason) refuses | (b) "pause never blocks repay" vs this refusal → FLOW-26 |
| REP-014 | `AD` → `VAULT_TOKEN_FACTORY.tokenOfPool(VT.pool())` | — | — | (b) pool-keyed market identity → FLOW-11 |
| REP-016/017 | `AD` → `SW.deleverage`; `SW` sizes with LPOracle, DebtOracle | session | liquidation-grade price gates | (a) LPOracle prices full-range composition → FLOW-08 |
| REP-018 | `SW` → GHO FlashMinter; buy route for non-GHO | debt repaid first | `maxGhoSpend` | (c) no FlashMinter on Base → FLOW-02 |
| REP-019 | `SW` → `AD.deleverageRelease` → `CO.releaseForDeleverage` → `LV.removeLiquidity` | units burned, record debited | pool unlocked | (d) the borrower's own removal can be sandwiched; the floor then reverts → FLOW-09 |
| REP-020/021 | conversion to GHO, flash repay, `hfAfter ≥ hfBefore` | GHO to `W` | per-leg minimums | (a) GHO depth on the chain → FLOW-14 |

### 2.5 Collect fees (FLOW-007, `FEE-001`…`FEE-008`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| FEE-001 | `W` → `LV.collectFees(tokenId)` | Lock | `LockHeld` | (b) per-Spoke `LV` must be a Lock member → FLOW-01 |
| FEE-002 | `LV` | — | `depositorOf[tokenId] == msg.sender` | — |
| FEE-003 | none | — | relies on the pool's own reentrancy lock | (a) holds for Uniswap v3 and Slipstream `burn`/`collect`; must be re-proven per AMM protocol → FLOW-10 |
| FEE-004/005/006 | `LV` → `NFPM.collect(recipient=W)` | fees to `W` | — | (a) Slipstream charges an `unstakedFee` share on unstaked positions; fee yield shown by the frontend must net it → FLOW-10 |

### 2.6 Partial liquidity removal (path E, `WDR-031`…`WDR-039`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| WDR-031/032/033 | `W` → `AD.removeLiquidity(S, VT, tokenId, units, a0Min, a1Min, ...)` | Lock | factory check, debt read, with debt: pause, freeze, `preWithdrawCheck` | (b) `tokenOfPool` keying → FLOW-11 |
| WDR-034/036 | `P` → `S.withdraw` → `H.remove`; burn | VT burned | HF ≥ 1 with debt | (c) Hub halt or VT reserve pause blocks it → FLOW-12 |
| WDR-037 | `AD` → `CO.releasePartial` → `LV.releaseLiquidity` | record debited, tokens to `W` | `0 < units < credited`; `a0Min`, `a1Min` | (a) two-token output; out of range one leg is 0, so a user-set non-zero min reverts → FLOW-08 |
| WDR-038/035/039 | remaining-record min, health check, backing | — | `minPledgeUsd` on the rest | — |

### 2.7 Withdraw (paths A–D, `WDR-001`…`WDR-030`)

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| WDR-001…005 | `W` → `AD.withdraw(S, VT, tokenId, units, ...)` | Lock | deadline, `NoProxy`, factory/token, `borrowCount` | (b) whole-NFT release keyed by `tokenId` |
| WDR-006/007 | with debt: pause, freeze, `preWithdrawCheck` | — | breakers incl. keeper count | (a) per-Hub keeper floor → FLOW-25 |
| WDR-008…012 | `P` → `S.withdraw` → `H.remove`; cleanup; burn | VT burned | Aave: reserve not paused, Spoke active and not halted | (c) debt-free withdraw blocked by a Hub halt or a VT reserve pause → FLOW-12 |
| WDR-013…017 | `AD` → `CO.release` → `LV.returnNft` | record closed, NFT returned | reconcile (path D) | (a) `LV` and `CO` are immutable; a ledger bug has no migration → FLOW-22 |
| WDR-019…023 | `W` → `CO.releaseZeroCredit(tokenId)` | NFT returned | none | (b) Lock member (`CO`) → FLOW-01 |
| WDR-024 | `W` → `AD.repayAllAndWithdraw` | repay all listed reserves, then path A | arrays | (b) example in 3.4 uses markets A and B on one Spoke → FLOW-07 |
| WDR-025…030 | `CO` reconcile; anyone → `SW.settlePending(marketId)` | pending pool tokens converted, GHO to "the GHO Coverage Spoke" | floor | (b) which Hub's GHO Coverage Spoke for a cross-Hub GHO reserve → FLOW-05 |

### 2.8 Liquidation (FLOW-005)

Keeper path (`liquidate`):

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| LIQ-011 | keeper → `SW.liquidate(params)` | Lock | keeper list, amounts, frozen caller | (a) `SW` per Hub holds the Lock of its Hub, but `CO`/`LV` belong to the Spoke → FLOW-01 |
| LIQ-012 | `SW` → `MR`, ParameterStore, Spoke views | market and reserve resolved | `LIQ-004` | (a) debt reserve on `H'` resolved through the home Hub's registry → FLOW-05 |
| LIQ-013 | `SW` → `O.poke()`, DebtOracle `poke()` | caches | `LIQ-003/006/007/008/073` | (a) no sequencer-uptime gate; grace only after an Expired outage → FLOW-03 |
| LIQ-014 | `SW` → Spoke views | bonus, `lf` | `lf == 0` | (b) liquidation-manager variant assumed → FLOW-13 |
| LIQ-015 | `SW` pulls `K`, flash-mints `F` GHO | GHO in | `maxFlashFeeBps` | (c) no FlashMinter on Base → FLOW-02 |
| LIQ-070 | `SW` → buy route GHO → debt asset | debt asset in | `limit = min(M, bound(X))` | (a) GHO → asset depth on the chain → FLOW-14 |
| LIQ-016 | `SW` → `CO.beginSeizure(proxy, VT)` | snapshot | lock holder, `isValidProxy`, shares == assets | (b) `CO` must accept the Hub's `SW` and Lock → FLOW-01 |
| LIQ-017 | `SW` → `S.liquidationCall(reserveId, r, proxy, X, false)` | debt repaid on `H'`, VT to `SW` | Spoke requires `msg.sender == LIQUIDATION_MANAGER` | (b) open decision: standard Spoke + restricted VT → FLOW-13; (c) Hub halt blocks it → FLOW-12 |
| LIQ-018/071/019 | `SW` measures `D`, `c`; sells back | — | `c > 0` | — |
| LIQ-072/020…025 | `AD.burnSeized`; `CO.settleSeizure` → `LV.removeLiquidity(tokenId, take_r, SW)` | records debited largest-first; principal to `SW` | `slot0.unlocked`, share and supply deltas | (d) spot manipulation before the removal → FLOW-09; (b) Slipstream `slot0` → FLOW-10 |
| LIQ-026/027 | `SW` measures `a0`, `a1`; floor `minGho` from oracle value `V` | — | — | (a) `V` from full-range composition; out of range the recovered mix differs → FLOW-08 |
| LIQ-028/029 | routed conversion to GHO per leg | GHO `R` | per-leg `minOutᵢ` | (a) a route per pool token to GHO on the chain → FLOW-02, FLOW-14 |
| LIQ-030/076 | shortfall top-up from caller | — | `≤ maxShortfallGho` | — |
| LIQ-031/032 | waterfall: flash repay, Avana fee `A`, `keeperOut` | GHO out | conservation | (b) proposal names a "borrower surplus"; spec pays the surplus to the caller → FLOW-23 |
| LIQ-079 | `MR.recordLiquidationOutcome` | breaker counters | gas floor | — |
| LIQ-034 | unlock | — | zero net balances | — |

Variants:

| Variant | Steps | Marks |
|---|---|---|
| Permissionless (`LIQ-061`, `LIQ-062`) | as above, `PrimaryThenBackup`, no budget, no in-kind | (c) on Base the caller needs GHO inventory → FLOW-02; (d) a spot move makes every permissionless attempt revert `RecoveryBelowFloor` → FLOW-09 |
| In-kind (`LIQ-045`…`LIQ-048a`) | `F = 0`; keeper share `kᵢ` at oracle prices; remainder `rᵢ` to `PositionProxy.wallet()` or PayoutEscrow | (a) two legs `token0`/`token1`; (a) PayoutEscrow per Hub must be found by the borrower → FLOW-24 |
| Shortfall top-up (`LIQ-076`, `LIQ-078`) | caller pays `minGho − R`; probe reports | (a) probe uses `minOut = 1` on GHO routes on the chain → FLOW-02 |
| Pending settlement (`LIQ-057`…`LIQ-059`, `WDR-030`) | anyone → `settlePending(marketId)` | (b) proceeds to "the GHO Coverage Spoke" → FLOW-05 |
| Deficit and coverage (`LIQ-049`…`LIQ-051`, `DEF-003`…`DEF-018`) | Spoke reports deficit on each `H'`; `COVERAGE_ROLE` covers within 72 h from the `(H', asset)` Coverage Spoke | (b) coverage sizing "on the Hub" misses Spokes of other Hubs → FLOW-05; (c) uncovered deficit borne first-come by Lend Spoke lenders → FLOW-15 |
| Multi-market sequencing (`LIQ-052`…`LIQ-054`) | one call per market and reserve | (b) with one market per Spoke the multi-market text is dead → FLOW-07 |
| Foreign `liquidationCall` (`LIQ-055`, `LIQ-056`) | reverts `Unauthorized()` | (b) holds only for the liquidation-manager variant → FLOW-13 |

### 2.9 Proxy migration to a new version (not specified)

No page defines it. The minimal flow the proposal implies:

| # | Caller → call | State change | Checks needed | Marks |
|---|---|---|---|---|
| M-1 | `W` → `AD.migrate(S, version)` | Lock | `W` owns `P`, new implementation approved | (b) `PM` deploys `BeaconProxy` with salt `(W, S)` (`DEP-003`, 2.5); a second proxy for `(W, S)` needs a new salt → FLOW-04 |
| M-2 | `PM.deployProxy(W, S, v)` | `P'` | — | (d) squatting by another Adapter → FLOW-18 |
| M-3 | flash-borrow each debt asset, `repay` all of `P`'s debt | `P` debt 0 | — | (c) re-borrowing in M-6 is "new debt" under `BOR-015`/`BOR-017` → blocked in `Paused`, `Frozen` or a breaker, exactly when a proxy bug forces migration → FLOW-04 |
| M-4 | `P` withdraws VT; VT moved to `P'` | — | VT recipient rule | (b) no proxy-to-proxy transfer exists |
| M-5 | `CO` rebinds every record, list, `accountCredited`, `accountRescueUnits`, `isValidProxy` | — | — | (b) `DEP-012`: record proxy never changes |
| M-6 | `P'` supplies, enables, borrows | debt on `P'` | drawCap, Hub liquidity, health | (c) at 100 % utilisation the re-borrow fails; risk premium resets |
| M-7 | `proxyOf[W][S] = P'`, nonce carried | — | — | (b) `DEP-003`: binding never changes; Ponder attribution |

### 2.10 Market listing (FLOW-008, `MKT-018`…`MKT-026`) and the three deployment operations

| # | Caller → call | State change | Checks | Marks |
|---|---|---|---|---|
| deployCdpSpoke | proposal: "creates the Spoke, AaveOracle, vault and ledger" | — | — | (b) `MKT-023`: Aave deploys and registers the Spoke and its AaveOracle; Avana cannot create them → FLOW-21; (b) new `LV`/`CO` must join the Lock → FLOW-01 |
| MKT-019 | operators deploy the market's LPOracle (UUPS) | — | — | — |
| MKT-018/020/021 | timelock batch: `approveSpoke`, `deployVaultToken` (CREATE3 salt = pool), `registerMarket` | Registered | `MKT-003`…`MKT-008`: Uniswap v3 canonical factory, two USD stablecoins, `d0 + d1` even, Chainlink heartbeat ≤ 3,600 s | (b) excludes Slipstream pools, Correlated and Volatile pairs, WBTC/WETH (8 + 18 odd), Base feeds → FLOW-21, FLOW-03, FLOW-10 |
| MKT-022 | `O.poke()` | Live price | — | — |
| MKT-023 | Aave DAO payload: Spoke with `LIQUIDATION_MANAGER = SW`, reserves, drawCaps, Coverage allowlist | — | — | (b) one AIP per market under one market per Spoke → FLOW-21; (b) open liquidation-manager decision → FLOW-13 |
| MKT-024/026 | live-config check, `activateMarket` at short delay | Active | on-chain match check | — |
| enableDebtReserve | proposal: "connects an approved funding Hub and asset" | — | — | (b) `MKT-044`/`DEF-016` describe one Hub; consent of the funding Hub's governance and Coverage Spoke is unstated → FLOW-05 |

### 2.11 Market wind-down and delisting (`MKT-037`…`MKT-042`, `EMG-060`, `EMG-061`)

| # | Caller → call | State change | Marks |
|---|---|---|---|
| Freeze | Aave Guardian → `freezeReserve` (VT reserve) | Frozen | — |
| Offboard | Timelock → `MR.setMarketOffboarding`; Aave CF cuts by AIP | Offboarding (final) | (c) no force-close and CF > 0 while debt: a market with dormant accounts never closes; feed, routes and keepers run indefinitely per Spoke → FLOW-22 |
| Close | VT supply 0 | Closed | (b) `MKT-041`: the pool can never get a second token, so the pool cannot be relisted on a new Spoke version or tier → FLOW-11 |
| Reclassify | not possible (`MKT-042`) | — | (b) "at launch there is one Stable LP Borrow Spoke" → FLOW-07 |

### 2.12 Emergency pause, freeze and breakers (FLOW-006)

| # | Caller → call | State change | Marks |
|---|---|---|---|
| EMG-040 | Guardian → `MR.freeze()` / `MR.pause(reason)` | per-Hub application state | (b) `MR` is per Hub; a fault in shared code (proxy implementation, VaultTokenFactory, LPPriceMath, ProxyManager) needs every Hub on every chain paused → FLOW-19 |
| Address freeze | Guardian → `MR.freezeAddress` | per Hub | (d) an exploiter frozen on one Hub keeps acting on the others → FLOW-19 |
| Breakers | automatic in `RM` | block new activity | (a) pool-share breaker uses in-range liquidity → FLOW-08 |
| EMG-052 | Aave governance → `haltSpoke` | only fee collection continues | (c) with one market per Spoke, halting a Spoke is the natural per-market lever and stops repay, liquidation and debt-free withdraw → FLOW-12 |
| EMG-064 | Aave Guardian → `pauseReserve(VT)` | liquidation of holders halts | (c) same → FLOW-12 |

### 2.13 Oracle switch (`MKT-033`, `MKT-047`, `EMG-091`)

| # | Caller → call | State change | Marks |
|---|---|---|---|
| Alternate failover | automatic inside `O` | served route | — |
| Standby | Guardian → `MR.useStandbyRoute(token, slot)`; normal delay `setPriceSource` | route swapped | (a) the standby must exist on Base with an L2 sequencer gate → FLOW-03 |
| New LPOracle | UUPS upgrade (normal delay) | code changed | (b) `VT.lpOracle()` is immutable (`MKT-051`); a new pricing model per AMM protocol means an upgrade, not a switch → FLOW-20 |
| AaveOracle source | Aave DAO `setReserveSource` per CDP Spoke | Aave price | (c) `LIQ-006(a)` requires the price to come from `m`'s LPOracle: a mismatched Aave-side switch halts liquidation of the market → FLOW-20 |

### 2.14 Market transitions

**In range to out of range.** Under the current spec this never happens: positions are full range (`SPEC-BACK-001`, `MKT-003`). The proposal prices "over the market's fixed range". With a bounded range: the position becomes one token, fees stop, the value per unit `L` stops being `2·√(p0·p1)` (`SPEC-ORC-005`…`SPEC-ORC-008`), a one-leg depeg scales value by `x` rather than `√x` (the `MKT-017` shock table), `poolShareMaxBps` compares against in-range liquidity that excludes Avana, and partial removal with non-zero `amount0Min`/`amount1Min` reverts. → FLOW-08.

**A pool whose liquidity drains.** Other LPs leave; Avana's full-range liquidity becomes most of the pool. Effects: (1) the pool-share breaker trips and blocks new borrowing only; rescue top-ups may still raise Avana's share (`Q-252`); (2) the TWAP consistency check becomes cheap to move, so new-account pledges see Drifting; (3) the pool spot is cheap to move, so an attacker or the borrower can make every unwind recover below `minGho` and every liquidation revert `RecoveryBelowFloor` unless the caller tops up; (4) `MKT-009` (manipulation-cost study as a listing criterion) no longer holds and nothing on-chain reacts to it. → FLOW-09.

### 2.15 Base sequencer outage

1. Sequencer stops. No L2 blocks; Chainlink on Base stops updating.
2. Users can only reach the chain through L1 forced inclusion, delayed by hours; those transactions execute against frozen Chainlink answers.
3. Sequencer restarts. Prices update in the first blocks. Keepers liquidate accounts whose owners had no chance to top up or repay.
4. The recovery grace (`LIQ-007`) starts only after an `Expired` oracle state; an outage shorter than `liquidationPriceMaxAge` (heartbeat + 600 s) never sets it, and Base stablecoin feeds publish on a 24-hour heartbeat, which `MKT-005` (≤ 3,600 s) already rejects.
5. No page reads a sequencer-uptime feed. → FLOW-03.

---

## 3. Findings

### AMMN-FLOW-01 — The Lock cannot admit per-Spoke vaults and ledgers

- **Severity:** Critical
- **Failing step:** `DEP-001`/`DEP-006`/`DEP-008`, `FEE-001`, `WDR-013`, `WDR-019`, `LIQ-016`, `LIQ-020`, `LIQ-023`.
- **Spec IDs:** `REQ-LOCK-004`, `REQ-LOCK-024` (2.16), `Q-148`; proposal instance table (Lock per Hub, `LV`/`CO` per Spoke).
- **Problem:** the Lock's members are four constructor immutables (`AAVE_ADAPTER`, `COLLATERALIZATION`, `LP_VAULT`, `LP_VAULT_SWAP`). A per-Hub Lock cannot add the `LV` and `CO` of a CDP Spoke deployed later by `deployCdpSpoke`. Every pledge, release, fee collection and seizure of that Spoke then reverts with `NotMember`. A per-Spoke Lock instead breaks the shared-lock model: `AD` and `SW` serve many Spokes and would need to hold several locks, and two Hubs' Locks do not see each other.
- **Fix:** keep one Lock per Hub with an append-only member registry written only by a deployer contract inside `deployCdpSpoke` (timelocked, no removal), checked as `isMember[msg.sender]`; state that cross-Hub calls never nest (an Avana entry point refuses to run while any Lock on the chain is held, read through a per-chain Lock directory); keep the inner-call rules keyed by contract role, not address.
- **Verification:** Foundry stateful test with two CDP Spokes on one Hub and one on another, fuzzing nested entry points through route and token callbacks; assert no second outer entry point succeeds in one call tree; Z3 not needed.

### AMMN-FLOW-02 — Liquidation and deleverage on Base assume a GHO FlashMinter, GSM routes and a $1 GHO

- **Severity:** Critical
- **Failing step:** `LIQ-015` (flash mint), `LIQ-029` (routes to GHO), `LIQ-070` (buy with GHO), `REP-018`, `REP-020`, `LIQ-061`/`LIQ-062` (permissionless funding), `WDR-030`.
- **Spec IDs:** `MKT-004`, `MKT-015` (GSM/Sky PSM primary routes), `LIQ-036`…`LIQ-038`, 2.11, 2.12, 2.13; proposal liquidation step 1.
- **Problem:** the GHO FlashMinter and the GSMs are on Ethereum mainnet. GHO on Base is a bridged token with thin DEX depth. Every Slipstream liquidation as specified needs a GHO flash mint and GHO routes; a permissionless liquidator needs GHO inventory on Base; the recovery floor is counted in GHO priced at Aave's fixed $1, so a bridged-GHO discount is a hidden loss to the waterfall. With no flash source, only keepers with GHO inventory can liquidate.
- **Fix:** make the settlement asset and flash source per chain parameters (`settlementAsset`, `flashSource`) with a priced oracle for the settlement asset unless it is the debt asset; on Base settle in USDC (or the debt asset) with an Aave V4 Hub flash loan or another audited flash source; size Base caps from measured route depth to that asset; otherwise launch Base only after an on-chain GHO flash facilitator exists.
- **Verification:** Base fork tests running `liquidate`, `liquidatePermissionless` and `repayWithCollateral` end to end at the stress size of `MKT-013`; Z3 model of the waterfall conservation with a settlement asset priced ≠ 1.

### AMMN-FLOW-03 — No L2 sequencer gate, and Base feed heartbeats fail the listing rule

- **Severity:** High
- **Failing step:** `LIQ-006`, `LIQ-007`, `BOR-006`, `WDR-007`, `DEP-010`; `MKT-005` at listing.
- **Spec IDs:** `MKT-005`, `MKT-006`, `REQ-ORACLE-006`…`REQ-ORACLE-014`, `LIQ-007` (grace), `Q-088`, `Q-128`.
- **Problem:** (1) No page reads a sequencer-uptime feed. After a Base outage, liquidations run on the first fresh prices while borrowers had no access; transactions forced in from L1 during the outage execute on stale answers. (2) Grace starts only after `Expired`, which a short outage never reaches. (3) `MKT-005` requires primary heartbeats ≤ 3,600 s; most Base USD feeds use 86,400 s, so no Slipstream market can list as written.
- **Fix:** add to the LPOracle and DebtOracle a per-chain `sequencerUptimeFeed`; while down: Expired; after restart: a grace window `sequencerGraceSeconds` during which only accounts below `graceHealthFactor` are liquidatable and borrowing is closed; make the heartbeat bound a per-chain listing parameter with matching `borrowPriceMaxAge`.
- **Verification:** Foundry unit tests with a mocked uptime feed (down, restart, restart + grace); Z3 model of the gate's state machine with the existing price-state model; Base fork check of each listed feed's heartbeat.

### AMMN-FLOW-04 — Pinned proxies have no migration flow, and the spec still uses a beacon

- **Severity:** High
- **Failing step:** `DEP-003`, `DEP-012`, `BOR-002`, `REP-012`, `REP-008` (a buggy pinned `repay`), migration M-1…M-7.
- **Spec IDs:** 2.5 (`ProxyManager` "the beacon of every PositionProxy", `BeaconProxy`, `REQ-PROXY-004`…`006`), `MKT-029` (`setProxyImplementation` changes every proxy at once), `DEP-003` ("the binding never changes"), `DEP-012` (record `proxy` never changes).
- **Problem:** the spec upgrades all proxies through a beacon; the proposal pins each proxy and leaves migration undefined. Aave V4 has no position transfer, so migration means repaying, withdrawing and re-borrowing; the re-borrow is new debt and is refused under `Paused`, `Frozen`, breakers, a full drawCap or 100 % utilisation, which are the states in which a proxy bug forces migration. A bug in a pinned `repay` or `withdrawCollateral` cannot be patched, so borrowers cannot repay and are liquidated. Collateralization records, seizure lists, `accountRescueUnits`, `isValidProxy` and `borrowNonce` are keyed by the old proxy.
- **Fix:** either keep a timelocked beacon with an immutable minimum surface (repay and withdraw paths never upgradeable) or specify `migrate`: one Adapter call under the Lock that flash-repays on `P`, moves VT through a Collateralization `rebindAccount(P, P')`, re-borrows on `P'` exempt from new-activity gates when the debt and health factor are unchanged or better, and updates `proxyOf` with an event Ponder follows; also let a third party repay directly to the Spoke for a proxy whose code fails.
- **Verification:** Foundry tests migrating an indebted account under `Paused`, `Frozen`, a tripped breaker and a full drawCap; invariant: debt, collateral, rescue units and backing gap identical before and after; Z3 model of the debt-neutral exemption.

### AMMN-FLOW-05 — Cross-Hub debt reserves split risk ownership between Hubs

- **Severity:** High
- **Failing step:** `BOR-008`, `BOR-017`, `LIQ-012`, `LIQ-049`, `DEF-005`, `DEF-013`, `DEF-015`, `WDR-030`, enableDebtReserve.
- **Spec IDs:** `DEF-002`, `DEF-008`, `DEF-013`, `DEF-016`, `DEF-018`, `MKT-013`, `MKT-054`, `REQ-HUB` purpose ("the Avana Stable LP Hub"); proposal "each debt reserve records its funding Hub".
- **Problem:** a Volatile CDP Spoke borrowing USDC from the Stable Hub is governed by the Volatile Hub's RiskModule, ParameterStore, LPVaultSwap and SettlementBudget, but its losses fall on the Stable Hub's USDC suppliers and Coverage Spoke. `DEF-013` sums exposure "on the Hub", which omits Spokes homed elsewhere; pending-settlement proceeds go to "the GHO Coverage Spoke" without naming which Hub; nothing requires the funding Hub's governance to consent. This undoes the isolation the three Hubs exist for.
- **Fix:** define a per `(funding Hub, asset)` exposure register listing every drawing Spoke on every Hub; require `enableDebtReserve` to be a joint operation (funding Hub's coverage allowlist and cap budget first); size each Coverage Spoke over all drawing Spokes; name the Coverage Spoke in `DebtReserveDef` and route `settlePending` proceeds by the reserve's funding Hub.
- **Verification:** Z3 model: Σ drawCaps over all Spokes of all Hubs ≤ credit line and ≤ coverage capacity; stateful test where a Volatile Spoke defaults on Stable-Hub USDC and coverage draws the right Coverage Spoke.

### AMMN-FLOW-06 — Credit lines across Hubs are enforced off-chain only

- **Severity:** Medium
- **Failing step:** `BOR-008`.
- **Spec IDs:** `BOR-008` ("the drawCaps … sum to at most each asset's credit line"), `MKT-031`, `DEF-011`.
- **Problem:** a "Stablecoin credit line" spanning Hubs is a sum of per-Spoke drawCaps on several Hubs set by separate AIPs; nothing on-chain checks the sum, and one market per Spoke multiplies the Spokes.
- **Fix:** a view on the funding Hub's MarketRegistry that sums drawCaps of every registered drawing Spoke; the RiskModule refuses borrowing on any Spoke while the sum exceeds the recorded credit line.
- **Verification:** Foundry test raising one Spoke's drawCap above the line and asserting `CreditLineExceeded`; Z3 inequality model.

### AMMN-FLOW-07 — One market per Spoke contradicts the multi-market spec

- **Severity:** High
- **Failing step:** `BOR-006`/`BOR-011` (every collateral market of the account), `LIQ-052`, `WDR-024` example, `MKT-016`, `MKT-042`.
- **Spec IDs:** 2.5 ("holds the supplied vault-token collateral of every market the account uses"), `MKT-016`, `MKT-042` ("at launch there is one Stable LP Borrow Spoke"), `LIQ-052`, 3.4 and 3.3 worked examples (markets A and B), proposal ("a vault can hold multiple approved markets").
- **Problem:** the spec puts many markets on one Borrow Spoke; the proposal puts one per Spoke and also says a vault holds several. Which one holds decides the seizure list keys, `spokeUserReservesLimit`, the drift checks, the multi-market liquidation order and whether a wallet has one or many health factors. With one market per Spoke a borrower cannot offset a falling market with another, and a rescue top-up must be in the same market.
- **Fix:** decide one market per CDP Spoke, with one LPVault and ledger per Spoke; remove multi-market loops and examples; state the user-facing cost (no cross-margin) in the docs; keep the per-account code generic over N = 1.
- **Verification:** spec grep for "every collateral market" and multi-market examples; conformance tests that a second market on the same Spoke is rejected at `approveSpoke`/`registerMarket`.

### AMMN-FLOW-08 — Full-range math is used for markets with a fixed bounded range

- **Severity:** High
- **Failing step:** `DEP-007`, `DEP-009`, `DEP-011` (pool share), `DEP-015` (`addCap`), `WDR-037`, `LIQ-027`, `REP-017`, every LPOracle read.
- **Spec IDs:** `SPEC-BACK-001`, `SPEC-ORC-005`…`SPEC-ORC-008`, `SPEC-CAP-005`, `MKT-003`, `MKT-007`, `MKT-010`, `MKT-014`, `MKT-017`; proposal pricing ("over the market's fixed range").
- **Problem:** value per unit `L`, vault-token decimals, `MAX_CREDITED_LIQUIDITY`, the `√x` depeg shock, the CF formula, `addCap` in whole tokens and the pool-share check all assume full range. A bounded range out of range holds one token, earns no fees, loses value in proportion to `x` on a depeg, and is not counted in the pool's in-range liquidity.
- **Fix:** launch both AMM protocols with full-range markets only (Slipstream supports them) and say so; for any bounded-range market later, add `LPPriceMath` range formulas, a range-specific shock table and pool-share check, and re-derive caps and CF.
- **Verification:** Z3 models of the range formulas (in range, below, above) against the full-range identity at the boundaries; fork tests of a bounded position crossing out of range.

### AMMN-FLOW-09 — Pool spot moves turn liquidation into a revert (drained or thin pools)

- **Severity:** High
- **Failing step:** `LIQ-020`/`LIQ-023` (removal at spot), `LIQ-030` (`RecoveryBelowFloor`), `REP-019`, `WDR-028`.
- **Spec IDs:** `LIQ-023` (zero per-token minimums), `LIQ-030`, `LIQ-076`, `MKT-009`, `SPEC-CAP-005`, `SPEC-BRK-002`.
- **Problem:** the unwind checks only `slot0.unlocked`. Anyone (including the borrower) who moves the pool spot before the removal makes the recovered mix worth less than `minGho` at oracle prices, so `liquidatePermissionless` reverts and keepers must pay a top-up. In a drained pool this is cheap and repeatable; nothing on-chain reacts to the `MKT-009` depth falling.
- **Fix:** before removal, compare the pool's spot `sqrtPriceX96` to the oracle-derived reference (`SPEC-ORC-009`); outside `twapToleranceTicks`, either skip conversion and settle in-kind automatically, or revert with a distinct `PoolSpotOff` that keepers can bundle with an arbitrage back to the reference; add a pool-depth breaker that lowers the market's caps when in-range liquidity falls below the `MKT-009` minimum.
- **Verification:** fork simulation of the attacker's cost per blocked block versus the debt at risk; Foundry test that a manipulated spot yields `PoolSpotOff` and that the bundle path succeeds.

### AMMN-FLOW-10 — Slipstream differs from Uniswap v3 in the calls the flows rely on

- **Severity:** High
- **Failing step:** `DEP-007` (`getPool(t0,t1,fee)`, `slot0.unlocked`), `WDR-028`, `LIQ-020`, `FEE-003`/`FEE-004`, `MKT-008` (`twapToleranceTicks ≥ pool fee + …`), `MKT-021`.
- **Spec IDs:** `DEP-007`, `MKT-003`, `MKT-008`, `MKT-021`, `REQ-ORACLE-014`, 2.2, 2.3.
- **Problem:** Slipstream factories key pools by `tickSpacing`, its NFPM returns `tickSpacing` where v3 returns `fee`, its `slot0` has a different field layout (decoding with the v3 ABI reads the wrong word for `unlocked`), its fee can be set by a dynamic fee module, and unstaked positions pay an `unstakedFee` share. Code written against the v3 interfaces either reverts or checks the wrong value.
- **Fix:** define an `IAmmPosition` interface (pool derivation, range check, liquidity read, lock check, removal, fee collection) with separate Uniswap v3 and Slipstream implementations inside each LPVault; read the pool fee live for the TWAP tolerance bound; refuse pools whose gauge or fee module can change the NFT's fee claim.
- **Verification:** mainnet and Base fork tests of each `IAmmPosition` call against real pools, including `unlocked` read during a swap callback; per-AMM conformance tests.

### AMMN-FLOW-11 — One vault token per pool blocks relisting, tiers and ranges

- **Severity:** Medium
- **Failing step:** `DEP-006`, `WDR-004`, `REP-014`, `MKT-020`, `MKT-041`, `MKT-042`.
- **Spec IDs:** `MKT-003`, `MKT-020` (CREATE3 salt = pool), `MKT-041`, `MKT-042`, `MKT-051`, `REQ-ADAPTER-068`.
- **Problem:** market identity is `tokenOfPool(pool)`. A pool cannot be listed twice (two ranges, two tiers) and, after offboarding, can never be relisted on a new CDP Spoke version, which a ledger or vault fix (FLOW-22) requires.
- **Fix:** key the factory by `(cdpSpoke, pool)` (salt includes the Spoke) and verify a token by `VT.spoke() == S` plus `factory.tokenOf(S, pool) == VT`.
- **Verification:** Foundry test listing the same pool on two Spokes and relisting after offboarding.

### AMMN-FLOW-12 — Aave-side halts and pauses stop repay, debt-free withdraw and liquidation

- **Severity:** High
- **Failing step:** `REP-008` (`H.restore`), `WDR-008` (`H.remove`), `LIQ-017`.
- **Spec IDs:** `EMG-052`, `EMG-064`, `Q-140`; decision "pause states never block liquidation, repay, debt-free withdraw or fees".
- **Problem:** the decision binds Avana's pause states only. A Hub halt of a CDP Spoke or an Aave pause of a VT reserve blocks all three. With one market per Spoke, halting the Spoke becomes the obvious per-market containment step for Aave governance, so the guarantee fails in the case it is meant for.
- **Fix:** state in the Aave payload agreement and the runbooks that containment of a CDP Spoke uses the reserve freeze and drawCap 0, never `haltSpoke` or `pauseReserve` while debt exists; add a monitoring alarm and a RiskModule drift reason for a halted Spoke; document the exception next to the decision.
- **Verification:** fork tests showing which flows each Aave flag blocks; runbook review.

### AMMN-FLOW-13 — Liquidation access depends on an undecided Spoke variant

- **Severity:** High
- **Failing step:** `LIQ-014`, `LIQ-017`, `LIQ-055`, `LIQ-056`, `BOR-007` (drift on `LIQUIDATION_MANAGER`), `MKT-023`, `MKT-026`, `DEF-001`.
- **Spec IDs:** `REQ-HUB-092`, `REQ-HUB-096`, `LIQ-064`…`LIQ-067`, `MKT-024`.
- **Problem:** 32 places in the contract pages assume the liquidation-manager variant. The proposed alternative (standard Spoke, transfer-restricted VT) holds only if every path that moves VT out of the Hub checks the recipient: `receiveShares` disabled, `liquidationFee = 0` (else the fee receiver gets VT shares), Hub `reinvestmentController = 0` for the VT asset, no other Spoke listed on the VT asset, no position-manager approvals on proxies, and VT rejecting zero-amount transfers to non-allowed recipients. If any is missed, a third party can seize collateral or trigger a deficit report outside LPVaultSwap.
- **Fix:** decide; if standard Spoke, write the recipient rule as a VT requirement (allowed: Hub, registered proxies, LPVaultSwap), add each Aave flag above to the drift check and the activation match check, and rewrite `LIQ-055`/`LIQ-056`/`DEF-001`.
- **Verification:** fork test of a foreign `liquidationCall` for every reserve flag combination and amount 0; invariant "no VT movement except via LPVaultSwap".

### AMMN-FLOW-14 — Non-GHO debt and non-stable collateral are routed through GHO

- **Severity:** High
- **Failing step:** `LIQ-070`, `LIQ-029`, `LIQ-071`, `REP-018`, `REP-020`.
- **Spec IDs:** `MKT-004`, `MKT-015`, `MKT-049`, `SPEC-LIQ-015`, `SPEC-LIQ-018`.
- **Problem:** an ETH debt against an ETH/LST market is liquidated by flash-minting GHO, buying ETH, seizing, selling ETH and LST for GHO and repaying: two swaps through GHO depth where none is needed. `MKT-015` defines routes only for stablecoins (GSM, PSM); Correlated and Volatile tokens have none, so their markets cannot list or liquidate at size.
- **Fix:** allow a route that converts pool tokens directly to the debt asset with a floor in the debt asset (`SPEC-LIQ` rewritten per settlement asset); size each market's debt cap by the measured depth of its own routes.
- **Verification:** Z3 model of the generalised floor and waterfall; fork simulations of ETH-debt liquidations at stress size.

### AMMN-FLOW-15 — Lend Spoke lenders bear uncovered deficits first-come

- **Severity:** Medium
- **Failing step:** lender withdraw on the funding Hub after `DEF-014`.
- **Spec IDs:** `DEF-014`, `DEF-009`, `DEF-012`.
- **Problem:** an uncovered `deficitRay` stays counted in the Hub's assets; lenders who withdraw first leave at full value and the last ones carry the loss. The spec says losses are borne "as stated in the Aave DAO's credit-line approval", which covered a DAO treasury, not public lenders on many assets.
- **Fix:** define the loss rule for public Lend Spoke supply (who absorbs, when it is realised) and publish per-reserve exposure by drawing Spoke and Hub in the Lens.
- **Verification:** fork test of a deficit followed by lender withdrawals; Lens conformance test.

### AMMN-FLOW-16 — A debt-free LP can fill every cap at no cost

- **Severity:** Medium
- **Failing step:** `DEP-011` (`marketUsdCap`, `tokenUsdCap`, `depositorUsdCap`, `poolShareMaxBps`).
- **Spec IDs:** `SPEC-CAP-005`, `SPEC-BACK-004`, `MKT-013`, `Q-157`.
- **Problem:** caps are charged at pledge. A whale (or sybil wallets, bypassing `depositorUsdCap`) pledges debt-free, keeps earning fees and blocks new borrowers; debt-free withdraw lets them leave at any time.
- **Fix:** reserve part of `marketUsdCap` for accounts with debt, or charge the regular budget only when an account first borrows; keep the pool-share cap on total credited liquidity.
- **Verification:** stateful test where debt-free pledges fill the cap and a borrower still opens within the reserved part.

### AMMN-FLOW-17 — Instance scope leaves components unassigned or singular

- **Severity:** Medium
- **Failing step:** `BOR-005` (receiver refusal list), `LIQ-015`, `DEF-015`, Lens reads.
- **Spec IDs:** `BOR-005`, `REQ-PROXY-017`, 2.1 purpose, 2.17, proposal instance table.
- **Problem:** the table omits DebtOracle, FlashMinter use, settlement and buy routes, Coverage Spokes per funding Hub, and the Lend Spoke; `BOR-005` names one Hub; the Lens per chain must read three Adapters and many Spokes.
- **Fix:** add each component with its scope; make the refusal list "every Avana Hub and CDP Spoke on the chain" read from a per-chain directory.
- **Verification:** spec review against a deployment manifest; Foundry test of borrow refusal to every Hub address.

### AMMN-FLOW-18 — A per-chain ProxyManager with several Adapters allows proxy squatting

- **Severity:** Medium
- **Failing step:** `DEP-003`, migration M-2.
- **Spec IDs:** 2.5 (`deployProxy` only from the Adapter), `REQ-PROXY-004`…`006`.
- **Problem:** with one Adapter per Hub, `deployProxy` must accept several callers. A faulty or compromised Adapter can deploy the CREATE2 address for `(W, S)` of another Hub's Spoke first; the legitimate pledge then reverts.
- **Fix:** include the calling Adapter in the salt and require `S`'s home Hub Adapter (from the Hub's MarketRegistry) to be `msg.sender`; or one ProxyManager per Hub.
- **Verification:** Foundry test of a cross-Hub `deployProxy` attempt.

### AMMN-FLOW-19 — Pause, freeze and Guardian are per Hub and per chain; shared code is not

- **Severity:** Medium
- **Failing step:** `EMG-040`, `EMG-067`, address freeze, `DEP-004`, `BOR-016`.
- **Spec IDs:** `EMG-040`, `EMG-067`, `REQ-ACCESS-013` (one AvanaTimelock), `Q-242`.
- **Problem:** a bug in the proxy implementation, VaultTokenFactory, LPPriceMath or ProxyManager affects every Hub on a chain, but each pause is one MarketRegistry call per Hub per chain, by Guardian Safes that must exist on both chains; an address frozen on one Hub keeps acting on the others; Aave-side actions on Base go through cross-chain governance with different latency, which `MKT-052` ordering assumes away.
- **Fix:** a per-chain emergency router the Guardian calls once to pause every Hub; a per-chain freeze list every RiskModule reads; state the Base governance path and its latency in `MKT-052`.
- **Verification:** Foundry test of the router pausing all Hubs in one call; governance runbook drill on a Base fork.

### AMMN-FLOW-20 — An oracle switch can halt liquidation

- **Severity:** Medium
- **Failing step:** `LIQ-006(a)`, `MKT-033`, `MKT-051`.
- **Spec IDs:** `LIQ-006`, `MKT-047`, `MKT-051`, `EMG-091`.
- **Problem:** `VT.lpOracle()` is immutable, so a new pricing model is an LPOracle upgrade, not a switch. If the Aave DAO points the CDP Spoke's AaveOracle at another source, `LIQ-006(a)` makes every liquidation of the market revert `StalePrice` with no Avana-side remedy.
- **Fix:** add the AaveOracle source to the drift and liquidation gate with a defined fallback (liquidate at Aave's served price within a bound), and document the oracle-switch procedure as a joint operation.
- **Verification:** fork test switching the AaveOracle source and running a liquidation.

### AMMN-FLOW-21 — Listing rules exclude the launch and planned markets

- **Severity:** Medium
- **Failing step:** `MKT-003`, `MKT-004`, `MKT-007`, `MKT-010`, `MKT-021`, `MKT-023`, deployCdpSpoke.
- **Spec IDs:** `MKT-003` (Uniswap v3, two USD stablecoins), `MKT-007`/`SPEC-ORC-005` (`d0 + d1` even), `MKT-010` (Core Hub token CFs), `MKT-023`.
- **Problem:** Slipstream pools fail the canonical-factory rule; WBTC/WETH and cbBTC/WETH (8 + 18) fail the decimals rule; tokenized stocks and many governance tokens have no Core Hub CF; and `deployCdpSpoke` cannot create an Aave Spoke or AaveOracle, which the Aave DAO deploys, so every new market under one market per Spoke needs its own AIP.
- **Fix:** per-AMM factory rule; vault-token decimals that allow odd sums (for example `d = max(d0, d1)` with a scaling factor in `LPPriceMath`); a CF source for tokens without a Core Hub CF; rename `deployCdpSpoke` to an Avana-side step that follows the Aave payload, and agree a batched AIP template.
- **Verification:** Z3 model of the decimals and price formula with odd sums; listing dry-runs for each planned pair.

### AMMN-FLOW-22 — Wind-down never ends, and immutable vaults have no exit

- **Severity:** Medium
- **Failing step:** `MKT-038`…`MKT-041`, `EMG-061`, `WDR-013`…`WDR-016`.
- **Spec IDs:** `MKT-039`, `MKT-040`, `MKT-041`, `EMG-061`.
- **Problem:** no force-close and CF > 0 while debt means a market with one dormant borrower keeps its feed, routes and keepers forever; with one market per Spoke that cost is per market. A bug in an immutable LPVault or ledger has no path to move NFTs out except each user's own withdraw.
- **Fix:** add a terminal step: after notice and a CF ramp, keepers may liquidate any remaining account at a fixed bonus once its health factor falls below a raised threshold; define a ledger-bug procedure (pause, users withdraw, relist on a new Spoke, which FLOW-11 enables).
- **Verification:** stateful test of the ramp closing a dormant account.

### AMMN-FLOW-23 — The proposal's "borrower surplus" does not exist in the waterfall

- **Severity:** Low
- **Failing step:** `LIQ-031`, `LIQ-032`.
- **Spec IDs:** `SPEC-LIQ-007`…`SPEC-LIQ-010`, `LIQ-047`.
- **Problem:** the spec pays the surplus after funding and Avana's fee to the caller; only in-kind settlement pays the borrower a remainder. Aave leaves the unseized collateral with the borrower.
- **Fix:** correct the proposal text, or specify a borrower share and re-prove conservation.
- **Verification:** Z3 conservation model either way.

### AMMN-FLOW-24 — Two-token and tokenId keys are baked into shared code

- **Severity:** Low
- **Failing step:** `LIQ-046`, `LIQ-047`, `WDR-028` (`amount0`, `amount1`), `WDR-037`, `DEP-012` (`tokenUsd[token0/1]`), Ponder and Lens keys.
- **Spec IDs:** 2.3, 2.11, 2.17, 2.18.
- **Problem:** fine for both launch AMM protocols, but the proposal says the shared ledger is generic; later Curve, Balancer and v2 positions have N tokens and no tokenId. Indexing by `tokenId` alone collides across NFPMs and chains.
- **Fix:** key records by `(positionManager, positionId)` and indexing by `(chainId, positionManager, positionId)`; keep token arrays in the AMM-specific layer.
- **Verification:** spec review; Ponder schema test.

### AMMN-FLOW-25 — Keeper floors multiply per Hub and chain

- **Severity:** Low
- **Failing step:** `LIQ-063`, `WDR-007`, `MKT-035`.
- **Spec IDs:** `LIQ-063`, `LIQ-077`, `keeperFloor` (3).
- **Problem:** each LPVaultSwap needs three active keepers or its Hub halts borrowing; three Hubs on two chains need six keeper sets holding the settlement asset on each chain.
- **Fix:** state the keeper floor per LPVaultSwap and fund the standby keeper on each chain before activation.
- **Verification:** activation check reads `activeKeeperCount ≥ keeperFloor` on the market's Hub.

### AMMN-FLOW-26 — Repay with collateral is refused under Paused

- **Severity:** Medium
- **Failing step:** `REP-015`.
- **Spec IDs:** `REP-015`, decision "pause states never block … repay".
- **Problem:** during a crash with `Paused(General)`, a borrower without outside funds cannot deleverage, while keepers can still liquidate the account at a bonus.
- **Fix:** allow `repayWithCollateral` under `Paused(General)` when it only reduces debt and raises the health factor; keep the refusal under `MintPathSuspect`.
- **Verification:** Foundry test under `Paused(General)` with the existing `hfAfter ≥ hfBefore` check.

---

## 4. Summary by severity

| Severity | Findings |
|---|---|
| Critical | 01, 02 |
| High | 03, 04, 05, 07, 08, 09, 10, 12, 13, 14 |
| Medium | 06, 11, 15, 16, 17, 18, 19, 20, 21, 22, 26 |
| Low | 23, 24, 25 |
