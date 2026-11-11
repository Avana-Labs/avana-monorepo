# Checklist: CoverageSpoke

Spec pages: 14-first-loss-reserve.md. CVL specs: CoverageSpoke.spec.

## REQ / SPEC on the page (49)

- [x] `SPEC-FLR-001` (14-first-loss-reserve.md:108) **Coverage amount.** `amount = min(maxAmount, ceil(deficitRay / RAY), fundedBalance())`, read in the same call — PROP-039, TEST-199
- [x] `SPEC-FLR-002` (14-first-loss-reserve.md:112) **Funded balance.** `fundedBalance() = floor(addedShares_this × (A + 1e6) / (S + 1e6))` as returned by `HUB.ge — TEST-199, TEST-288
- [x] `SPEC-FLR-003` (14-first-loss-reserve.md:116) **Withdrawal.** A request `id` is executable only when `block.timestamp ≥ executableAt = requestTime + RESERVE — TEST-288
- [ ] `SPEC-FLR-004` (14-first-loss-reserve.md:120) **Reserve sizing against caps, per asset.** For each debt asset `a` and each underlying token `t`, with every 
- [ ] `SPEC-FLR-005` (14-first-loss-reserve.md:124) **Tail coverage per asset.** For each debt asset `a`: `tail_a = max over non-GHO pool tokens t of min(⌈(tokenU
- [ ] `REQ-FLR-001` (14-first-loss-reserve.md:130) The First-Loss Reserve of an asset MUST be that asset held as the added shares of that asset's Coverage Spoke 
- [x] `REQ-FLR-002` (14-first-loss-reserve.md:131) Each Coverage Spoke MUST be funded by Avana Labs and controlled only by the Aave DAO through the roles in [Per — TEST-062, TEST-288
- [x] `REQ-FLR-003` (14-first-loss-reserve.md:132) A Coverage Spoke MUST NOT be upgradeable and MUST have no owner other than its AccessManager authority; a repl — TEST-288
- [x] `REQ-FLR-004` (14-first-loss-reserve.md:133) A Coverage Spoke MUST call only `Hub.add`, `Hub.remove` (from `executeWithdrawal`) and `Hub.eliminateDeficit`  — PROP-060, TEST-288
- [x] `REQ-FLR-005` (14-first-loss-reserve.md:134) The Coverage Spoke MUST hold no tokens between transactions, MUST check token amounts by the Hub's returned va — PROP-060, TEST-080, TEST-288
- [x] `REQ-FLR-006` (14-first-loss-reserve.md:135) Every state-changing function MUST be non-reentrant and follow checks-effects-interactions. (Source: Q-148) — TEST-288
- [x] `REQ-FLR-007` (14-first-loss-reserve.md:136) On its Hub, each Coverage Spoke MUST be registered only on its own asset with `drawCap = 0`, `addCap = firstLo — TEST-002
- [x] `REQ-FLR-008` (14-first-loss-reserve.md:137) The constructor `constructor(hub, asset, assetId, authority, reserveWithdrawalDelay)` MUST revert `ZeroAddress — TEST-002, TEST-288
- [ ] `REQ-FLR-009` (14-first-loss-reserve.md:138) Aave Labs' confirmation of the coverage caller (the Coverage Spoke as `eliminateDeficit` caller, the `COVERAGE
- [x] `REQ-FLR-010` (14-first-loss-reserve.md:142) `fund(amount)` MUST revert `ZeroAmount` if `amount == 0`, MUST move exactly `amount` of `ASSET` from `msg.send — PROP-060, TEST-177, TEST-288
- [x] `REQ-FLR-011` (14-first-loss-reserve.md:143) Avana Labs MUST fund each Coverage Spoke with at least `firstLossReserveMinimum[asset]` of its asset before th — TEST-199
- [x] `REQ-FLR-012` (14-first-loss-reserve.md:144) A Coverage Spoke's asset MUST be Hub liquidity like any other added liquidity of that asset, so Avana borrower — TEST-288
- [x] `REQ-FLR-013` (14-first-loss-reserve.md:145) `firstLossReserveMinimum` MUST be stored in each Coverage Spoke, set to the value of the funding ARFC agreed w — TEST-288
- [x] `REQ-FLR-014` (14-first-loss-reserve.md:146) After `coverDeficit` or `executeWithdrawal`, if `fundedBalance() < firstLossReserveMinimum`, the call MUST emi — TEST-199, TEST-288
- [x] `REQ-FLR-015` (14-first-loss-reserve.md:147) The reserve's shares MUST accrue whatever supply yield the Hub's configuration of the asset pays; yield stays  — TEST-288
- [x] `REQ-FLR-038` (14-first-loss-reserve.md:148) Every Coverage Spoke's `fund` MUST accept the pending-settlement top-up from LPVaultSwap exactly as any other  — TEST-288
- [x] `REQ-FLR-016` (14-first-loss-reserve.md:152) `coverDeficit` MUST be callable only by `COVERAGE_ROLE` and MUST revert unless `allowedBorrowSpoke[borrowSpoke — PROP-039, TEST-062, TEST-199, TEST-288
- [x] `REQ-FLR-017` (14-first-loss-reserve.md:153) `setAllowedBorrowSpoke(spoke, true)` MUST revert `ZeroAddress` if `spoke == address(0)` and `BorrowSpokeNotLis — TEST-199, TEST-288
- [x] `REQ-FLR-018` (14-first-loss-reserve.md:154) `coverDeficit` MUST compute `amount` per `SPEC-FLR-001`, revert if the covered Spoke's `deficitRay` on `ASSET_ — PROP-039, TEST-199
- [x] `REQ-FLR-019` (14-first-loss-reserve.md:155) Coverage MUST NOT exceed the covered Spoke's recorded deficit on the instance's asset or the instance's funded — PROP-039, TEST-199
- [ ] `REQ-FLR-020` (14-first-loss-reserve.md:156) The reserve MUST cover only deficits Aave has recorded on the Hub; it MUST NOT fund in-transaction settlement 
- [ ] `REQ-FLR-021` (14-first-loss-reserve.md:157) The `COVERAGE_ROLE` holder MUST cover every recorded deficit on an allowlisted CDP Spoke within `deficitCovera
- [x] `REQ-FLR-022` (14-first-loss-reserve.md:158) Coverage MUST keep working while the Coverage Spoke or the covered CDP Spoke is halted on the Hub. A Hub halt  — TEST-199
- [x] `REQ-FLR-023` (14-first-loss-reserve.md:162) `requestWithdrawal(amount, to)` MUST be callable only by `RESERVE_ADMIN_ROLE`, MUST revert `ZeroAmount` if `am — TEST-062, TEST-288
- [x] `REQ-FLR-024` (14-first-loss-reserve.md:163) `cancelWithdrawal(id)` MUST be callable only by `RESERVE_ADMIN_ROLE`, MUST revert `WithdrawalNotPending(id)` u — TEST-062, TEST-288
- [x] `REQ-FLR-025` (14-first-loss-reserve.md:164) `executeWithdrawal(id)` MUST be callable only by `RESERVE_ADMIN_ROLE`, MUST revert `WithdrawalNotPending(id)`  — TEST-062, TEST-288
- [ ] `REQ-FLR-026` (14-first-loss-reserve.md:165) Unused reserve capital of an asset MUST return to Avana Labs only through the withdrawal path, after that (Hub
- [x] `REQ-FLR-027` (14-first-loss-reserve.md:169) A deficit larger than its asset's funded balance MUST stay recorded as the CDP Spoke's `deficitRay` on that as — TEST-199
- [ ] `REQ-FLR-028` (14-first-loss-reserve.md:170) Before caps are approved, the Aave V4 risk service providers MUST size per-market, per-token and per-debt-asse
- [x] `REQ-FLR-039` (14-first-loss-reserve.md:171) Each Coverage Spoke MUST expose `ASSET()`, `HUB()` and `ASSET_ID()`; `enableDebtReserve` for any debt reserve, — TEST-002
- [x] `REQ-FLR-040` (14-first-loss-reserve.md:172) A Coverage Spoke MUST NOT eliminate a deficit recorded on any asset other than its own `ASSET_ID`, and no Avan — PROP-060, TEST-199, TEST-288
- [ ] `REQ-FLR-041` (14-first-loss-reserve.md:173) Each debt asset's reserve MUST be sized per asset: the Aave V4 risk service providers state, in every listing 
- [x] `REQ-FLR-042` (14-first-loss-reserve.md:174) Coverage scope MUST be per `(chain, Hub, debt asset)`: each chain's Coverage Spoke for `(h, a)` covers deficit — TEST-199
- [x] `REQ-FLR-043` (14-first-loss-reserve.md:175) When cross-Hub credit lines are enabled on a chain, the cross-Hub lines MUST satisfy `crossHubLineTotal(fundin — TEST-273
- [ ] `REQ-FLR-044` (14-first-loss-reserve.md:176) Avana MUST fund and the Aave DAO MUST control the launch instances on both chains under the same rules: the Et
- [x] `REQ-FLR-029` (14-first-loss-reserve.md:182) `coverDeficit` for a Spoke not on the allowlist | The call reverts with `SpokeNotAllowlisted`; no state change — PROP-039, TEST-199
- [x] `REQ-FLR-030` (14-first-loss-reserve.md:183) `coverDeficit` when the Spoke's deficit on the instance's asset or the computed amount is 0 | The call reverts — PROP-039, TEST-199
- [x] `REQ-FLR-031` (14-first-loss-reserve.md:184) Funded balance smaller than the deficit | Covers the funded balance only; the remainder stays recorded per `RE — PROP-039, TEST-199
- [x] `REQ-FLR-032` (14-first-loss-reserve.md:185) Caller lacks the required role | The call reverts with the AccessManager's `AccessManagedUnauthorized` (Source — TEST-062, TEST-199
- [x] `REQ-FLR-033` (14-first-loss-reserve.md:186) `executeWithdrawal` before `executableAt`, or for a request that is not Pending | The call reverts with `Withd — TEST-288
- [x] `REQ-FLR-034` (14-first-loss-reserve.md:187) Hub liquidity of the asset below the withdrawal | The call reverts with the Hub's `InsufficientLiquidity`; the — TEST-288
- [x] `REQ-FLR-035` (14-first-loss-reserve.md:188) Coverage Spoke halted on the Hub | `fund` and `executeWithdrawal` revert with `SpokeHalted`; `coverDeficit` co — TEST-199, TEST-288
- [x] `REQ-FLR-036` (14-first-loss-reserve.md:189) Coverage Spoke deactivated on the Hub | Every Hub call reverts with `SpokeNotActive`; deficits stay recorded a — TEST-199, TEST-288
- [x] `REQ-FLR-037` (14-first-loss-reserve.md:190) `fund` beyond `firstLossReserveAddCap` of the asset | The call reverts with the Hub's `AddCapExceeded`; the DA — TEST-288

## TEST rows (8)

- [ ] `TEST-170` [unit] Pending-settlement proceeds to the Coverage Spoke of the market's `(Hub, debt asset)`: `LPVaultSwap.settlePend
- [x] `TEST-199` [unit] Per-asset coverage: a liquidation that leaves an account with no collateral and USDC debt reports the deficit 
- [ ] `TEST-094` [invariant] Deficits: a deficit in a debt reserve is recorded only when the account has no collateral left in any market, 
- [ ] `TEST-211` [invariant] Accounts and multi-asset accounting: handlers pledge, borrow, repay and liquidate on two Borrow Spokes, severa
- [ ] `TEST-216` [invariant] Solvency per debt asset (`INV-074`) across arbitrary sequences of the `TEST-215` handlers, run once with GHO a
- [ ] `TEST-128` [fork] Deficit coverage per asset: for the GHO reserve and a USDC reserve, `COVERAGE_ROLE` calls `coverDeficit(borrow
- [ ] `TEST-154` [hostile] Regression for Quint counterexample C-QNT-1: a hostile LPVaultSwap installed through the timelock seizes 315 u
- [ ] `TEST-280` [unit] Pending settlement and payout asset: recovered value from pending settlement goes to the Coverage Spoke of the

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

## PROP rows (2)

- [x] `PROP-039` [Certora] A Coverage Spoke's `coverDeficit(borrowSpoke, maxAmount)` invokes `Hub.eliminateDeficit(ASSET_ID, amount, borr
- [x] `PROP-060` [Certora] Per-asset coverage: a Coverage Spoke changes only the deficit of its own `(HUB(), ASSET_ID())` and spends only

## INV (12)

- [x] `INV-001` For every market `m`: `vaultToken[m].totalSupply() ≤ Σ r.credited + pending[vaultToken[m]].units`, the sum tak
- [x] `INV-058` Reconcile on exit. In `release` (withdrawal), `releasePartial` (partial removal), `releaseForDeleverage` (dele
- [ ] `INV-018` Blast radius of upgradeable contracts. (a) AaveAdapter implementation faulty or hostile (one per chain, servin
- [x] `INV-036` The Avana fee in routed mode is `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)` with `avanaFeeShareBps` 2,000 bps (
- [x] `INV-042` For each covered `(Hub, asset)`, `Hub.eliminateDeficit(assetId, amount, borrowSpoke)` for Avana deficits is ca
- [x] `INV-071` Per-asset coverage. A deficit recorded in debt reserve `r` is covered only by the Coverage Spoke registered on
- [x] `INV-053` No Avana function transfers vault tokens or a recorded NFT except through the flows in `INV-007`, `INV-009` an
- [x] `INV-085` Address freeze bounds. `freezeAddress` never covers the protected set (the AvanaTimelock, the Aave governance 
- [ ] `INV-074` Solvency per debt asset. For each debt asset `a`, after every transaction: `Σ_acct min(Debt_acct,a, Realizable
- [ ] `INV-079` Settlement-asset conservation across sequences, per asset. For each settlement asset `a` (each debt asset, GHO
- [ ] `INV-057` Draw gate, per debt asset. No borrow completes that leaves a CDP Spoke's `drawn + premium + deficit` on its fu
- [ ] `INV-094` Cross-Hub credit lines. A debt reserve on a CDP Spoke whose funding Hub `F` is not the Spoke's home Hub draws 

## ATTACK (4)

- [x] `ATTACK-090` Coverage spent on deficits outside Avana or in another asset
- [x] `ATTACK-130` Exhausting one asset's First-Loss Reserve or covering it with another asset
- [x] `ATTACK-163` Cross-Hub credit line drawn past the funding Hub's limit
- [ ] `ATTACK-173` Cross-Hub debt reserve whose losses land on another Hub
17 IDs without a link from contracts/: SPEC-FLR-004, SPEC-FLR-005, REQ-FLR-001, REQ-FLR-009, REQ-FLR-020, REQ-FLR-021, REQ-FLR-026, REQ-FLR-028, REQ-FLR-041, REQ-FLR-044, TEST-170, TEST-094, TEST-211, TEST-216, TEST-128, TEST-154, TEST-280
