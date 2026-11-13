# Checklist: CoverageSpoke

Spec pages: 14-first-loss-reserve.md. CVL specs: CoverageSpoke.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (56: 0 verified, 0 failed, 43 not run, 13 unlinked)

- [~] `SPEC-FLR-001` (14-first-loss-reserve.md:113) **Coverage amount.** `amount = min(maxAmount, ceil(deficitRay / RAY), fundedBalance())`, read in the same call — PROP-039, TEST-094, TEST-128, TEST-199
- [~] `SPEC-FLR-002` (14-first-loss-reserve.md:117) **Funded balance.** `fundedBalance() = floor(addedShares_this × (A + 1e6) / (S + 1e6))` as returned by `HUB.ge — TEST-199, TEST-293
- [~] `SPEC-FLR-003` (14-first-loss-reserve.md:121) **Withdrawal.** A request `id` is executable only when `block.timestamp ≥ executableAt = requestTime + RESERVE — TEST-293
- [ ] `SPEC-FLR-004` (14-first-loss-reserve.md:125) **Reserve sizing against caps, per asset.** For each debt asset `a` and each underlying token `t`, with every  — checked outside contracts/: reserve sizing against caps is Aave DAO and risk-service-provider guidance with no on-chain enforcement (Q-249); the spec-stage models MATH-ST-76 and MATH-ST-90 check the formula
- [ ] `SPEC-FLR-005` (14-first-loss-reserve.md:129) **Tail coverage per asset.** For each debt asset `a`: `tail_a = max over non-GHO pool tokens t of min(⌈(tokenU — TEST-247 (only excluded checks: uses a stand-in for CoverageSpoke)
- [ ] `SPEC-FLR-006` (14-first-loss-reserve.md:131) **Loss order across the two layers.** For a covered Spoke whose recorded deficit is `d = ⌈deficitRay / RAY⌉`, 
- [~] `REQ-FLR-001` (14-first-loss-reserve.md:140) The First-Loss Reserve of an asset MUST be that asset held as the added shares of that asset's Coverage Spoke  — TEST-293
- [~] `REQ-FLR-002` (14-first-loss-reserve.md:141) Each Coverage Spoke MUST be funded by Avana Labs and controlled only by the Aave DAO through the roles in [Per — TEST-062, TEST-293
- [~] `REQ-FLR-003` (14-first-loss-reserve.md:142) A Coverage Spoke MUST NOT be upgradeable and MUST have no owner other than its AccessManager authority; a repl — TEST-293
- [~] `REQ-FLR-004` (14-first-loss-reserve.md:143) A Coverage Spoke MUST call only `Hub.add`, `Hub.remove` (from `executeWithdrawal`) and `Hub.eliminateDeficit`  — PROP-060, TEST-128, TEST-293
- [~] `REQ-FLR-005` (14-first-loss-reserve.md:144) The Coverage Spoke MUST hold no tokens between transactions, MUST check token amounts by the Hub's returned va — PROP-060, TEST-080, TEST-293
- [~] `REQ-FLR-006` (14-first-loss-reserve.md:145) Every state-changing function MUST be non-reentrant and follow checks-effects-interactions. (Source: Q-148) — TEST-293
- [~] `REQ-FLR-007` (14-first-loss-reserve.md:146) On its Hub, each Coverage Spoke MUST be registered only on its own asset with `drawCap = 0`, `addCap = MAX_ALL — TEST-002, TEST-293
- [~] `REQ-FLR-008` (14-first-loss-reserve.md:147) The constructor `constructor(hub, asset, assetId, authority, reserveWithdrawalDelay)` MUST revert `ZeroAddress — TEST-002, TEST-293
- [ ] `REQ-FLR-009` (14-first-loss-reserve.md:148) Aave Labs' confirmation of the coverage caller (the Coverage Spoke as `eliminateDeficit` caller, the `COVERAGE — checked outside contracts/: Aave Labs' confirmation of the coverage caller is recorded in each chain's deployment manifest before any CDP Spoke drawCap is raised above 0; the deployment check reads the manifest
- [~] `REQ-FLR-010` (14-first-loss-reserve.md:152) `fund(amount)` MUST revert `ZeroAmount` if `amount == 0`, MUST move exactly `amount` of `ASSET` from `msg.send — PROP-060, TEST-177, TEST-293
- [~] `REQ-FLR-011` (14-first-loss-reserve.md:153) Avana Labs MUST fund each Coverage Spoke with at least `firstLossReserveMinimum[asset]` of its asset before th — TEST-199, TEST-293
- [~] `REQ-FLR-012` (14-first-loss-reserve.md:154) A Coverage Spoke's asset MUST be Hub liquidity like any other added liquidity of that asset, so Avana borrower — TEST-128, TEST-293
- [~] `REQ-FLR-013` (14-first-loss-reserve.md:155) `firstLossReserveMinimum` MUST be stored in each Coverage Spoke, set to the value of the funding ARFC agreed w — TEST-293
- [~] `REQ-FLR-014` (14-first-loss-reserve.md:156) After `coverDeficit` or `executeWithdrawal`, if `fundedBalance() < firstLossReserveMinimum`, the call MUST emi — TEST-199, TEST-293
- [~] `REQ-FLR-015` (14-first-loss-reserve.md:157) The reserve's shares MUST accrue whatever supply yield the Hub's configuration of the asset pays; yield stays  — TEST-293
- [~] `REQ-FLR-038` (14-first-loss-reserve.md:158) Every Coverage Spoke's `fund` MUST accept the pending-settlement top-up from LPVaultSwap exactly as any other  — TEST-170, TEST-293
- [~] `REQ-FLR-016` (14-first-loss-reserve.md:162) `coverDeficit` MUST be callable only by `COVERAGE_ROLE` and MUST revert unless `allowedBorrowSpoke[borrowSpoke — PROP-039, TEST-062, TEST-094, TEST-128, TEST-199, TEST-293
- [~] `REQ-FLR-017` (14-first-loss-reserve.md:163) `setAllowedBorrowSpoke(spoke, true)` MUST revert `ZeroAddress` if `spoke == address(0)` and `BorrowSpokeNotLis — TEST-199, TEST-293
- [~] `REQ-FLR-018` (14-first-loss-reserve.md:164) `coverDeficit` MUST compute `amount` per `SPEC-FLR-001`, revert if the covered Spoke's `deficitRay` on `ASSET_ — PROP-039, TEST-094, TEST-128, TEST-199
- [~] `REQ-FLR-019` (14-first-loss-reserve.md:165) Coverage MUST NOT exceed the covered Spoke's recorded deficit on the instance's asset or the instance's funded — PROP-039, TEST-094, TEST-128, TEST-199
- [~] `REQ-FLR-020` (14-first-loss-reserve.md:166) The reserve MUST cover only deficits Aave has recorded on the Hub; it MUST NOT fund in-transaction settlement  — TEST-199
- [ ] `REQ-FLR-021` (14-first-loss-reserve.md:167) The `COVERAGE_ROLE` holder MUST cover every recorded deficit on an allowlisted CDP Spoke within `deficitCovera — TEST-228 (only excluded checks: uses a stand-in for CoverageSpoke)
- [~] `REQ-FLR-022` (14-first-loss-reserve.md:168) Coverage MUST keep working while the Coverage Spoke or the covered CDP Spoke is halted on the Hub. A Hub halt  — TEST-199
- [~] `REQ-FLR-023` (14-first-loss-reserve.md:172) `requestWithdrawal(amount, to)` MUST be callable only by `RESERVE_ADMIN_ROLE`, MUST revert `ZeroAmount` if `am — TEST-062, TEST-293
- [~] `REQ-FLR-024` (14-first-loss-reserve.md:173) `cancelWithdrawal(id)` MUST be callable only by `RESERVE_ADMIN_ROLE`, MUST revert `WithdrawalNotPending(id)` u — TEST-062, TEST-293
- [~] `REQ-FLR-025` (14-first-loss-reserve.md:174) `executeWithdrawal(id)` MUST be callable only by `RESERVE_ADMIN_ROLE`, MUST revert `WithdrawalNotPending(id)`  — TEST-062, TEST-293
- [~] `REQ-FLR-026` (14-first-loss-reserve.md:175) Unused reserve capital of an asset MUST return to Avana Labs only through the withdrawal path, after that (Hub — TEST-293
- [~] `REQ-FLR-027` (14-first-loss-reserve.md:179) A deficit larger than both loss layers of its (Hub, asset) MUST stay recorded as the CDP Spoke's `deficitRay`  — TEST-094, TEST-199
- [ ] `REQ-FLR-028` (14-first-loss-reserve.md:180) Before caps are approved, the Aave V4 risk service providers MUST size per-market, per-token and per-debt-asse — checked outside contracts/: the risk service providers size caps against SPEC-FLR-004 and SPEC-FLR-005 before approval; no contract reads the sizing (Q-249)
- [~] `REQ-FLR-039` (14-first-loss-reserve.md:181) Each Coverage Spoke MUST expose `ASSET()`, `HUB()` and `ASSET_ID()`; `enableDebtReserve` for any debt reserve, — TEST-002
- [~] `REQ-FLR-040` (14-first-loss-reserve.md:182) A Coverage Spoke MUST NOT eliminate a deficit recorded on any asset other than its own `ASSET_ID`, and no Avan — PROP-060, TEST-094, TEST-128, TEST-199, TEST-247, TEST-293
- [ ] `REQ-FLR-041` (14-first-loss-reserve.md:183) Each debt asset's reserve MUST be sized per asset: the Aave V4 risk service providers state, in every listing  — TEST-247 (only excluded checks: uses a stand-in for CoverageSpoke)
- [~] `REQ-FLR-042` (14-first-loss-reserve.md:184) Coverage scope MUST be per `(chain, Hub, debt asset)`: each chain's Coverage Spoke for `(h, a)` covers deficit — TEST-094, TEST-128, TEST-199
- [ ] `REQ-FLR-043` (14-first-loss-reserve.md:185) When cross-Hub credit lines are enabled on a chain, the cross-Hub lines MUST satisfy `crossHubLineTotal(fundin — TEST-273 (only excluded checks: uses a stand-in for CoverageSpoke)
- [~] `REQ-FLR-044` (14-first-loss-reserve.md:186) Avana MUST fund and the Aave DAO MUST control the launch instances on both chains under the same rules: each C — TEST-293
- [ ] `REQ-FLR-046` (14-first-loss-reserve.md:190) For each covered `(chain, Hub, debt asset)` the Aave DAO's listing payload that registers the Avana Umbrella M
- [ ] `REQ-FLR-047` (14-first-loss-reserve.md:191) The `DeficitOffsetSpoke` constructor MUST revert as the Coverage Spoke constructor does (`REQ-FLR-008`), then 
- [ ] `REQ-FLR-048` (14-first-loss-reserve.md:192) Loss order: `coverDeficit` on a DAO deficit offset MUST, after the allowlist and recorded-deficit checks and b
- [ ] `REQ-FLR-049` (14-first-loss-reserve.md:193) Accounting separation: each layer's capital MUST be its own Hub share position (the Hub's `getSpokeAddedShares
- [~] `REQ-FLR-029` (14-first-loss-reserve.md:199) `coverDeficit` for a Spoke not on the allowlist | The call reverts with `SpokeNotAllowlisted`; no state change — PROP-039, TEST-094, TEST-128, TEST-199
- [~] `REQ-FLR-030` (14-first-loss-reserve.md:200) `coverDeficit` when the Spoke's deficit on the instance's asset or the computed amount is 0 | The call reverts — PROP-039, TEST-094, TEST-199
- [~] `REQ-FLR-031` (14-first-loss-reserve.md:201) Funded balance smaller than the deficit | Covers the funded balance only; the remainder is covered by the DAO  — PROP-039, TEST-094, TEST-128, TEST-199
- [~] `REQ-FLR-032` (14-first-loss-reserve.md:202) Caller lacks the required role | The call reverts with the AccessManager's `AccessManagedUnauthorized` (Source — TEST-062, TEST-199
- [~] `REQ-FLR-033` (14-first-loss-reserve.md:203) `executeWithdrawal` before `executableAt`, or for a request that is not Pending | The call reverts with `Withd — TEST-293
- [~] `REQ-FLR-034` (14-first-loss-reserve.md:204) Hub liquidity of the asset below the withdrawal | The call reverts with the Hub's `InsufficientLiquidity`; the — TEST-293
- [~] `REQ-FLR-035` (14-first-loss-reserve.md:205) Coverage Spoke halted on the Hub | `fund` and `executeWithdrawal` revert with `SpokeHalted`; `coverDeficit` co — TEST-199, TEST-293
- [~] `REQ-FLR-036` (14-first-loss-reserve.md:206) Coverage Spoke deactivated on the Hub | Every Hub call reverts with `SpokeNotActive`; deficits stay recorded a — TEST-199, TEST-293
- [~] `REQ-FLR-037` (14-first-loss-reserve.md:207) `fund` of less than one share's value, or (only on a finite `addCap`, which the listing never sets, `REQ-FLR-0 — TEST-293
- [~] `REQ-FLR-045` (14-first-loss-reserve.md:208) `executeWithdrawal` while an allowlisted Spoke has a recorded deficit on the asset | The call reverts with `De — TEST-293
- [ ] `REQ-FLR-050` (14-first-loss-reserve.md:209) `coverDeficit` on a DAO deficit offset while its Avana Umbrella's `fundedBalance()` is above 0 | The call reve

## TEST rows (11: 0 verified, 0 failed, 9 not run, 2 unlinked)

- [~] `TEST-170` [unit] Pending-settlement proceeds to the Coverage Spoke of the market's `(Hub, debt asset)`: `LPVaultSwap.settlePend
- [~] `TEST-199` [unit] Per-asset coverage: a liquidation that leaves an account with no collateral and USDC debt reports the deficit 
- [~] `TEST-293` [unit] Coverage Spoke on the real local Aave V4 Hub (2.14): the constructor fails closed (zero addresses, a Hub asset
- [ ] `TEST-298` [unit, fuzz] DAO deficit offset on the real local Aave V4 Hub (2.14 `REQ-FLR-046` to `REQ-FLR-050`, `SPEC-FLR-006`, `INV-10
- [ ] `TEST-299` [integration] Loss order and the residual on the real local Aave V4 Hub (2.14 `REQ-FLR-027`, 3.9 `DEF-014`, `ATTACK-198`): l
- [~] `TEST-094` [invariant] Deficits: a deficit in a debt reserve is recorded only when the account has no collateral left in any market, 
- [~] `TEST-211` [invariant] Accounts and multi-asset accounting: handlers pledge, borrow, repay and liquidate on two Borrow Spokes, severa
- [~] `TEST-216` [invariant] Solvency per debt asset (`INV-074`) across arbitrary sequences of the `TEST-215` handlers, run once with GHO a
- [~] `TEST-128` [fork] Deficit coverage per asset: for the GHO reserve and a USDC reserve, `COVERAGE_ROLE` calls `coverDeficit(borrow
- [~] `TEST-154` [hostile] Regression for Quint counterexample C-QNT-1: a hostile LPVaultSwap installed through the timelock seizes 315 u
- [~] `TEST-280` [unit] Pending settlement and payout asset: recovered value from pending settlement goes to the Coverage Spoke of the

## PROP rows (2: 2 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-039` [Certora] A Coverage Spoke's `coverDeficit(borrowSpoke, maxAmount)` invokes `Hub.eliminateDeficit(ASSET_ID, amount, borr — CoverageSpoke job 6c2c483a5deb4928b4a05800c9db65d0
- [x] `PROP-060` [Certora] Per-asset coverage: a Coverage Spoke changes only the deficit of its own `(HUB(), ASSET_ID())` and spends only — CoverageSpoke job 6c2c483a5deb4928b4a05800c9db65d0

## INV (12: 5 verified, 0 failed, 5 not run, 2 unlinked)

- [x] `INV-001` For every market `m`: `vaultToken[m].totalSupply() ≤ Σ r.credited + pending[vaultToken[m]].units`, the sum tak — PROP-001, PROP-045, PROP-054, PROP-065, TEST-010, TEST-083, TEST-092, TEST-151, TEST-153, TEST-154, TEST-186, TEST-241, TEST-247 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [x] `INV-058` Reconcile on exit. In `release` (withdrawal), `releasePartial` (partial removal), `releaseForDeleverage` (dele — PROP-045, PROP-051, TEST-020, TEST-150, TEST-151, TEST-153, TEST-154 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [~] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin — TEST-031, TEST-107, TEST-130, TEST-133, TEST-195
- [~] `INV-036` The Avana fee in routed mode is `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)` with `avanaFeeShareBps` 2,000 bps ( — PROP-015, PROP-069, TEST-051, TEST-198, TEST-240
- [x] `INV-042` For each covered `(Hub, asset)`, `Hub.eliminateDeficit(assetId, amount, borrowSpoke)` for Avana deficits is ca — PROP-039, PROP-060, TEST-002, TEST-094, TEST-128, TEST-170, TEST-199, TEST-293 — CoverageSpoke job 6c2c483a5deb4928b4a05800c9db65d0
- [x] `INV-071` Per-asset coverage. A deficit recorded in debt reserve `r` is covered only by the Coverage Spoke registered on — PROP-060, TEST-094, TEST-128, TEST-199, TEST-293 — CoverageSpoke job 6c2c483a5deb4928b4a05800c9db65d0
- [~] `INV-053` No Avana function transfers vault tokens or a recorded NFT except through the flows in `INV-007`, `INV-009` an — PROP-051, TEST-032
- [x] `INV-085` Address freeze bounds. `freezeAddress` never covers the protected set (the AvanaTimelock, the Aave governance  — PROP-071, TEST-229 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [~] `INV-074` Solvency per debt asset. For each debt asset `a`, after every transaction: `Σ_acct min(Debt_acct,a, Realizable — TEST-218
- [ ] `INV-079` Settlement-asset conservation across sequences, per asset. For each settlement asset `a` (each debt asset, GHO
- [~] `INV-057` Draw gate, per debt asset. No borrow completes that leaves a CDP Spoke's `drawn + premium + deficit` on its fu — TEST-274
- [ ] `INV-094` Cross-Hub credit lines. A debt reserve on a CDP Spoke whose funding Hub `F` is not the Spoke's home Hub draws 

## ATTACK (4: 0 verified, 0 failed, 2 not run, 2 unlinked)

- [~] `ATTACK-090` Coverage spent on deficits outside Avana or in another asset — TEST-199
- [~] `ATTACK-130` Exhausting one asset's First-Loss Reserve or covering it with another asset — TEST-199
- [ ] `ATTACK-163` Cross-Hub credit line drawn past the funding Hub's limit — TEST-273 (only excluded checks: uses a stand-in for CoverageSpoke)
- [ ] `ATTACK-173` Cross-Hub debt reserve whose losses land on another Hub

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
