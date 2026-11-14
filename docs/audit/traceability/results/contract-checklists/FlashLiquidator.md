# Checklist: FlashLiquidator

Spec pages: 11-lpvaultswap.md#Flash liquidation helper. CVL specs: none.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (13: 0 verified, 0 failed, 13 not run, 0 unlinked)

- [~] `REQ-HELPER-001` (11-lpvaultswap.md:413) The helper MUST hold the immutables `POOL` (the chain's Aave V3 Pool, its only lender, `REQ-HELPER-015`), `LP_ — PROP-036, TEST-174, TEST-288, TEST-290, TEST-292
- [~] `REQ-HELPER-002` (11-lpvaultswap.md:414) Source rule. The constructor MUST revert with `FlashSourceIsHub` if `MarketRegistry.isRecordedHub(POOL)` is tr — PROP-096, TEST-118, TEST-174, TEST-285, TEST-288, TEST-292
- [~] `REQ-HELPER-003` (11-lpvaultswap.md:415) Request checks. `flashLiquidate(request)` MUST, in order, revert with `ContextActive` while a context of this  — TEST-052, TEST-174, TEST-289, TEST-292
- [~] `REQ-HELPER-004` (11-lpvaultswap.md:416) Bound context. Before calling the Pool, the helper MUST record a single-use context in transient storage: the  — TEST-046, TEST-174, TEST-289, TEST-290, TEST-292
- [~] `REQ-HELPER-005` (11-lpvaultswap.md:417) Callback binding. `executeOperation(assets, amounts, premiums, initiator, params)` MUST revert with `InvalidFl — PROP-036, TEST-046, TEST-052, TEST-174, TEST-292
- [~] `REQ-HELPER-006` (11-lpvaultswap.md:418) Liquidation inside the callback. The callback MUST `forceApprove` LPVaultSwap for exactly `X + params.maxShort — TEST-174, TEST-267, TEST-289, TEST-292
- [~] `REQ-HELPER-007` (11-lpvaultswap.md:419) Repayment. With `owed = F + φ` and `held = keeperOut + u`, if `held < owed` the callback MUST pull `topUp = ow — PROP-036, TEST-174, TEST-267, TEST-289, TEST-292
- [~] `REQ-HELPER-008` (11-lpvaultswap.md:420) Caller payout. After the loan returns and the context is checked, the helper MUST compute `payout` as the rise — PROP-036, TEST-174, TEST-176, TEST-267, TEST-289, TEST-292
- [~] `REQ-HELPER-009` (11-lpvaultswap.md:421) Quotes, the same for every debt asset, GHO included: `maxFlashLoan(asset)` MUST return 0 unless the Pool's res — TEST-052, TEST-289, TEST-292
- [~] `REQ-HELPER-010` (11-lpvaultswap.md:422) Public instance. The public helper takes its payer and payout recipient from `msg.sender`, so a caller can pul — TEST-174, TEST-288, TEST-289
- [~] `REQ-HELPER-011` (11-lpvaultswap.md:423) Operator variant. An operator's helper MUST refuse every caller except `SIGNER` (`NotSigner`), accept `F = 0`  — PROP-036, TEST-174, TEST-267, TEST-288, TEST-289, TEST-292
- [~] `REQ-HELPER-012` (11-lpvaultswap.md:424) The helper MUST NOT take a swap step, a route, a recipient other than its payer or the bound Safe, or executab — TEST-174, TEST-288, TEST-289, TEST-290
- [~] `REQ-HELPER-015` (11-lpvaultswap.md:425) One lender. The helper MUST borrow every debt asset, GHO included, from `POOL` and from no other lender: it ho — PROP-036, TEST-289, TEST-292

## TEST rows (9: 0 verified, 0 failed, 9 not run, 0 unlinked)

- [~] `TEST-046` [access-control] Callbacks: the core flash source's `executeOperation` reverts unless `msg.sender` is the Aave V3 Pool, `initia
- [~] `TEST-052` [unit] Flash premium bound, for `deleverage` and the flash liquidation helper (`liquidate` takes no loan and never re
- [~] `TEST-118` [fork] Flash paths on the Ethereum and Base forks: the core `IFlashSource` implementation, used only by `deleverage`,
- [~] `TEST-267` [fork] Flash paths on both forks. Core source, `deleverage` only: LPVaultSwap calls `IFlashSource.flashLoan(asset, am
- [~] `TEST-285` [unit] Flash source that borrows from a Hub (`ATTACK-195`): a mock flash source whose own address is a Spoke but whos
- [~] `TEST-288` [unit] Flash liquidation helper has nothing to administer or hold (2.11 `REQ-HELPER-001`): the public helper and the 
- [~] `TEST-289` [unit] Public helper instance (2.11 `REQ-HELPER-010`): the payer and the payout recipient are `msg.sender` of `flashL
- [~] `TEST-290` [unit] Helper takes no route or call data (2.11 `REQ-HELPER-012`): the `params` LPVaultSwap receives from the helper 
- [~] `TEST-292` [unit, fork] GHO-debt liquidations through the flash liquidation helper (2.11 `REQ-HELPER-015`, `REQ-FLASH-010`): GHO is bo

## PROP rows (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## INV (11: 5 verified, 0 failed, 5 not run, 1 unlinked)

- [~] `INV-037` No settlement budget (Q-397). No Avana contract holds funds to close a liquidation's settlement gap, and no LP — PROP-020, PROP-053, TEST-059, TEST-093, TEST-200
- [x] `INV-040` Flash and swap callbacks. `liquidate` takes no flash loan and has no flash callback (Q-404). The core flash so — PROP-036, PROP-053, PROP-080, TEST-046, TEST-052, TEST-055, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [~] `INV-062` One liquidation entry point (Q-404). `LPVaultSwap.liquidate` is the only liquidation entry point and admits an — PROP-022, PROP-053, TEST-174
- [~] `INV-070` Settlement in the debt asset, with no buy leg. For every debt reserve, LPVaultSwap pulls `debtToCover` of the  — PROP-059, TEST-048, TEST-092
- [x] `INV-095` Flash source rules. No liquidation takes a flash loan inside LPVaultSwap (Q-404): `liquidate` calls no lender, — PROP-080, PROP-096, PROP-097, TEST-046, TEST-052, TEST-055, TEST-267, TEST-285, TEST-287, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [~] `INV-046` An account with HF < 1 whose seized collateral market and repaid debt reserve pass `INV-030`, with no Aave pau — PROP-057, PROP-066, TEST-193, TEST-218
- [x] `INV-047` Every ParameterStore setter for `slippageAllowanceBps`, `graceHealthFactor`, `graceDuration`, `consistencyTole — PROP-042, TEST-064, TEST-225 — ParameterStore job 5cf1a73b625f4624b65c99923de6cb24
- [x] `INV-054` Every external state-changing entry point of the AaveAdapter and LPVaultSwap either acquires the Lock (outer c — PROP-037, PROP-075, TEST-046, TEST-060, TEST-179 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `INV-065` Implementation changes only by timelock; proxy code never changes. A PositionProxy's code is fixed at creation — PROP-010, PROP-058, TEST-025, TEST-062, TEST-063, TEST-089, TEST-130, TEST-168, TEST-172, TEST-191
- [x] `INV-085` Address freeze bounds. `freezeAddress` never covers the protected set (the AvanaTimelock, the Aave governance  — PROP-071, TEST-229 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [ ] `INV-079` Settlement-asset conservation across sequences, per asset. For each settlement asset `a` (each debt asset, GHO

## ATTACK (5: 0 verified, 0 failed, 2 not run, 3 unlinked)

- [ ] `ATTACK-068` Oversized flash loan whose cost is billed to Avana
- [ ] `ATTACK-119` Stale pending liquidation executed late
- [ ] `ATTACK-127` Oversized `debtToCover` or helper loan that turns funding into a cost for others
- [~] `ATTACK-195` Flash source that borrows from a Hub of the chain — TEST-285
- [~] `ATTACK-197` Transfer fee on a debt asset breaks the flash path — TEST-228, TEST-287

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
