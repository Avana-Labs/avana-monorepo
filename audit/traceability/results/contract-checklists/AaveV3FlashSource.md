# Checklist: AaveV3FlashSource

Spec pages: 11-lpvaultswap.md#Flash source. CVL specs: FlashSource.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (10: 6 verified, 0 failed, 3 not run, 1 unlinked)

- [x] `REQ-FLASH-001` (11-lpvaultswap.md:226) `AaveV3FlashSource` MUST hold the immutables `LENDER` (the chain's Aave V3 Pool), `LP_VAULT_SWAP` and `PARAMET — PROP-080, TEST-032, TEST-046, TEST-052, TEST-061, TEST-080, TEST-108, TEST-118, TEST-177, TEST-267, TEST-285 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [x] `REQ-FLASH-002` (11-lpvaultswap.md:227) Before calling `flashLoan`, LPVaultSwap MUST revert with `FlashLiquidityShort(available, F)` if `F > flashSour — PROP-080, TEST-046, TEST-052, TEST-118, TEST-198, TEST-239 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_completedLoanLeavesSourceEmpty
- [x] `REQ-FLASH-003` (11-lpvaultswap.md:228) `AaveV3FlashSource.executeOperation(assets, amounts, premiums, initiator, params)` MUST revert with `InvalidFl — PROP-036, PROP-080, TEST-046, TEST-052, TEST-080, TEST-177, TEST-287 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_036_callbackOutsideContextRefused
- [x] `REQ-FLASH-004` (11-lpvaultswap.md:229) LPVaultSwap's `onFlashLoan` checks are `REQ-SWAP-013`; the premium it accepts is the one the Pool reports in t — PROP-080, TEST-046, TEST-052 — FlashSource job ff2175f568234aca99b9fe4be2fbdecf
- [x] `REQ-FLASH-005` (11-lpvaultswap.md:230) On every `deleverage` call LPVaultSwap MUST revert with `FlashSourceIsHub()` if `MarketRegistry.isRecordedHub( — PROP-080, TEST-046, TEST-118, TEST-239, TEST-285 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_neverTheLiquidatedHub
- [~] `REQ-FLASH-006` (11-lpvaultswap.md:231) The chain's flash source is recorded on the MarketRegistry: `MarketRegistry.setFlashSource(newSource)` is call — TEST-032, TEST-046, TEST-239, TEST-285
- [~] `REQ-FLASH-007` (11-lpvaultswap.md:232) The deployment payload of each chain requests, by AIP on that chain's Aave V3 market, the `FLASH_BORROWER` rol — TEST-052, TEST-118, TEST-239, TEST-289
- [ ] `REQ-FLASH-008` (11-lpvaultswap.md:233) `enableDebtReserve` on a chain sizes the reserve's `drawCap` so that the largest single liquidation the market — TEST-289 (only excluded checks: tag on a test named for another row)
- [x] `REQ-FLASH-009` (11-lpvaultswap.md:234) The flash source MUST NOT be named by any caller: `deleverage` reads only `MarketRegistry.flashSource()`, and  — PROP-080, TEST-046, TEST-052 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [~] `REQ-FLASH-010` (11-lpvaultswap.md:235) Neither the core flash source nor the flash liquidation helper uses the GHO flash minter: `deleverage` and the — TEST-118, TEST-289, TEST-292

## TEST rows (6: 0 verified, 0 failed, 6 not run, 0 unlinked)

- [~] `TEST-046` [access-control] Callbacks: the core flash source's `executeOperation` reverts unless `msg.sender` is the Aave V3 Pool, `initia
- [~] `TEST-052` [unit] Flash premium bound, for `deleverage` and the flash liquidation helper (`liquidate` takes no loan and never re
- [~] `TEST-118` [fork] Flash paths on the Ethereum and Base forks: the core `IFlashSource` implementation, used only by `deleverage`,
- [~] `TEST-267` [fork] Flash paths on both forks. Core source, `deleverage` only: LPVaultSwap calls `IFlashSource.flashLoan(asset, am
- [~] `TEST-285` [unit] Flash source that borrows from a Hub (`ATTACK-195`): a mock flash source whose own address is a Spoke but whos
- [~] `TEST-287` [fork] Transfer fee on a debt asset (`ATTACK-197`): on a fork with a USDT debt reserve, Tether's `basisPointsRate` is

## PROP rows (2: 2 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-036` [Certora] The core flash source's callback (`executeOperation`, checked on `FlashSource.spec`) succeeds only if `msg.sen — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_036_callbackOutsideContextRefused
- [x] `PROP-080` [Certora (`FlashSource.spec`)] Flash source, `deleverage` only: LPVaultSwap requests a flash loan only inside `deleverage`, after reading ava — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows

## INV (9: 4 verified, 0 failed, 3 not run, 2 unlinked)

- [~] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe — TEST-027, TEST-106
- [ ] `INV-022` Calldata built by `packages/protocol` asks a user for only two kinds of approval: an approval of exactly one p
- [~] `INV-035` For every `liquidate` call, in the settlement asset `T` of the liquidation (the debt asset repaid): `Kf + R +  — PROP-015, PROP-059, TEST-051, TEST-078, TEST-092, TEST-093, TEST-104, TEST-198, TEST-216
- [x] `INV-040` Flash and swap callbacks. `liquidate` takes no flash loan and has no flash callback (Q-404). The core flash so — PROP-036, PROP-053, PROP-080, TEST-046, TEST-052, TEST-055, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [x] `INV-095` Flash source rules. No liquidation takes a flash loan inside LPVaultSwap (Q-404): `liquidate` calls no lender, — PROP-080, PROP-096, PROP-097, TEST-046, TEST-052, TEST-055, TEST-267, TEST-285, TEST-287, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [x] `INV-054` Every external state-changing entry point of the AaveAdapter and LPVaultSwap either acquires the Lock (outer c — PROP-037, PROP-075, TEST-046, TEST-060, TEST-179 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [~] `INV-065` Implementation changes only by timelock; proxy code never changes. A PositionProxy's code is fixed at creation — PROP-010, PROP-058, TEST-025, TEST-062, TEST-063, TEST-089, TEST-130, TEST-168, TEST-172, TEST-191
- [x] `INV-085` Address freeze bounds. `freezeAddress` never covers the protected set (the AvanaTimelock, the Aave governance  — PROP-071, TEST-229 — MarketRegistry job 82741daf7f694336b3b4eab5a93165c6
- [ ] `INV-079` Settlement-asset conservation across sequences, per asset. For each settlement asset `a` (each debt asset, GHO

## ATTACK (2: 0 verified, 0 failed, 2 not run, 0 unlinked)

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
