# Checklist: Lock

Spec pages: 16-lock.md. CVL specs: Lock.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (30: 0 verified, 0 failed, 30 not run, 0 unlinked)

- [~] `REQ-LOCK-001` (16-lock.md:96) The Lock MUST be immutable: no owner, no admin, no setters, no upgrade proxy, no pause, no `selfdestruct`. Its — TEST-060, TEST-270
- [~] `REQ-LOCK-002` (16-lock.md:97) The lock state MUST be a single address held in transient storage (EIP-1153) at the constant `HOLDER_SLOT`; th — TEST-060
- [~] `REQ-LOCK-003` (16-lock.md:98) Every function MUST revert with `DelegateCallNotAllowed` when `address(this) != SELF`, so the Lock's transient — TEST-060
- [~] `REQ-LOCK-004` (16-lock.md:99) `acquire()` MUST revert with `NotMember(msg.sender)` unless `msg.sender` is `AAVE_ADAPTER` or `LP_VAULT_SWAP`. — TEST-060, TEST-270
- [~] `REQ-LOCK-005` (16-lock.md:100) `acquire()` MUST revert with `LockHeld(currentHolder)` if the lock is held by any address, including `msg.send — TEST-060
- [~] `REQ-LOCK-006` (16-lock.md:101) On success `acquire()` MUST write `msg.sender` to `HOLDER_SLOT`. (Source: Q-148) — TEST-060
- [~] `REQ-LOCK-007` (16-lock.md:102) Every outer entry point listed in "Use by Avana contracts" MUST call `acquire()` before any external call othe — TEST-010, TEST-060, TEST-152, TEST-170, TEST-239
- [~] `REQ-LOCK-008` (16-lock.md:103) `release()` MUST revert with `NotHolder(msg.sender)` unless the lock is held and `msg.sender` is its holder, s — TEST-060
- [~] `REQ-LOCK-009` (16-lock.md:104) `holder()` MUST return the address in `HOLDER_SLOT` and `isLocked()` MUST return `holder() != address(0)`; bot — TEST-060
- [~] `REQ-LOCK-010` (16-lock.md:105) Every inner-call callee listed in "Inner calls that check the lock" MUST revert unless `msg.sender` is its nam — PROP-037, TEST-060, TEST-152, TEST-270, TEST-272
- [~] `REQ-LOCK-011` (16-lock.md:106) A callee acting for an account MUST also check that the record or position it acts on belongs to the account i — TEST-018
- [~] `REQ-LOCK-012` (16-lock.md:107) Because transient storage is cleared at the end of every transaction, the lock MUST be free at the start of ev — TEST-060
- [~] `REQ-LOCK-013` (16-lock.md:108) A revert anywhere in an outer call MUST leave the lock free, which follows from EIP-1153 rolling back transien — TEST-060
- [~] `REQ-LOCK-014` (16-lock.md:109) If an outer entry point returns without releasing, every later Avana entry point in the same transaction MUST  — TEST-060
- [~] `REQ-LOCK-015` (16-lock.md:110) No Avana or Aave role, and no member, can set the holder to any address other than itself or clear it on behal — TEST-060, TEST-270
- [~] `REQ-LOCK-016` (16-lock.md:111) Read-only views that external integrators rely on for consistent state (the Lens, [2.17](17-lens.md); Collater — PROP-037, TEST-028, TEST-060, TEST-236
- [~] `REQ-LOCK-017` (16-lock.md:112) Checks-effects-interactions remains required in every Avana contract: state updates (record status, counters,  — TEST-018, TEST-237
- [~] `REQ-LOCK-018` (16-lock.md:113) `acquire()` and `release()` MUST have a bounded cost that does not depend on the lock's history or on the numb — TEST-060
- [~] `REQ-LOCK-026` (16-lock.md:114) A repay with collateral MUST run as one call tree under the AaveAdapter's lock: the Adapter acquires the lock, — TEST-060
- [~] `REQ-LOCK-027` (16-lock.md:115) No pause state, breaker, address freeze or breaker recording MUST be able to hold or block the Lock: a liquida — TEST-060
- [~] `REQ-LOCK-028` (16-lock.md:116) Every Collateralization and LPVault function that moves a position, a token or a ledger amount, other than the — TEST-060, TEST-270
- [~] `REQ-LOCK-029` (16-lock.md:117) The constructor MUST revert with `InvalidMembers()` if `aaveAdapter` or `lpVaultSwap` is `address(0)` or the t — TEST-270
- [~] `REQ-LOCK-030` (16-lock.md:118) A member MUST call `release()` only as the last step of one of its outer entry points, after every inner call  — TEST-060, TEST-062, TEST-270
- [~] `REQ-LOCK-019` (16-lock.md:124) `acquire()` from a non-member | revert `NotMember(caller)` (Source: Q-148) — TEST-270
- [~] `REQ-LOCK-020` (16-lock.md:125) `acquire()` while held (reentry, nested entry point, second outer call in one call tree) | revert `LockHeld(ho — TEST-060
- [~] `REQ-LOCK-021` (16-lock.md:126) `release()` by an address that is not the holder | revert `NotHolder(caller)` (Source: Q-148) — TEST-060
- [~] `REQ-LOCK-022` (16-lock.md:127) Any function reached through `delegatecall` | revert `DelegateCallNotAllowed()` (Source: Q-148) — TEST-060
- [~] `REQ-LOCK-023` (16-lock.md:128) Inner call from the wrong caller or with the wrong holder | The callee reverts with its own error and no state — PROP-037, TEST-060, TEST-152, TEST-179, TEST-208, TEST-239, TEST-270
- [~] `REQ-LOCK-024` (16-lock.md:129) Membership changes after deployment, or a CDP Spoke, market, Hub or LPVault is added | Not possible and not ne — TEST-060, TEST-270
- [~] `REQ-LOCK-025` (16-lock.md:130) A PositionProxy, the ProxyManager, Collateralization, an LPVault, a vault token, the IFlashSource implementati — TEST-270

## TEST rows (2: 0 verified, 0 failed, 2 not run, 0 unlinked)

- [~] `TEST-060` [unit] Lock: every outer entry point of the AaveAdapter and LPVaultSwap acquires the immutable Lock, whose only membe
- [~] `TEST-270` [access-control] Lock membership: the Lock's members are exactly the AaveAdapter and LPVaultSwap, fixed at construction; every 

## PROP rows (3: 3 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-037` [Certora] Lock: any Avana function reachable only from inside the fixed set reverts unless the Lock is held and `msg.sen — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [x] `PROP-043` [SMTChecker] The immutable contracts (every LPVault, Collateralization, vault token, VaultTokenFactory, ProxyManager, Posit — Lock job 0f0bbe338f844d87ba9968713df8b185
- [x] `PROP-075` [Certora (`Lock.spec`)] Lock membership: the Lock's members are exactly the AaveAdapter and LPVaultSwap, fixed at construction; every  — Lock job 0f0bbe338f844d87ba9968713df8b185

## INV (9: 6 verified, 0 failed, 3 not run, 0 unlinked)

- [x] `INV-001` For every market `m`: `vaultToken[m].totalSupply() ≤ Σ r.credited + pending[vaultToken[m]].units`, the sum tak — PROP-001, PROP-045, PROP-054, PROP-065, TEST-010, TEST-083, TEST-092, TEST-151, TEST-153, TEST-154, TEST-186, TEST-241, TEST-247 — Collateralization job 8a8379652a2f4faaacd36ef1e8a3c13a
- [x] `INV-010` Only the AaveAdapter burns vault tokens (`burn(from, amount)`, from any holder without an allowance); this aut — PROP-005, PROP-007, PROP-055, TEST-022, TEST-088, TEST-130, TEST-208 — test/halmos/VaultToken.halmos.t.sol:VaultTokenHalmosTest.check_PROP_005_supplyChangesOnlyThroughAdapter
- [~] `INV-014` In every LPVaultSwap liquidation of proxy `p` in market `m`, with `S0` and `T0` Collateralization's own snapsh — PROP-004, PROP-011, TEST-056, TEST-208, TEST-269
- [x] `INV-040` Flash and swap callbacks. `liquidate` takes no flash loan and has no flash callback (Q-404). The core flash so — PROP-036, PROP-053, PROP-080, TEST-046, TEST-052, TEST-055, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_onlyLPVaultSwapBorrows
- [x] `INV-061` PayoutEscrow conservation. For every credited account `a` (the borrower, `feeRecipient` or the liquidation's c — PROP-052, TEST-080, TEST-173, TEST-179, TEST-286 — PayoutEscrow job 3f8731c0a94045939591ca3eb7b4a5f7
- [~] `INV-044` The depositor of any open record, including one at 0 credited units, can collect fees with `AaveAdapter.collec — PROP-057, TEST-017, TEST-060, TEST-099, TEST-132, TEST-151, TEST-193
- [~] `INV-052` The vault tokens, VaultTokenFactory, every LPVault (one per AMM protocol per chain), Collateralization (one pe — PROP-099, TEST-108, TEST-166
- [x] `INV-054` Every external state-changing entry point of the AaveAdapter and LPVaultSwap either acquires the Lock (outer c — PROP-037, PROP-075, TEST-046, TEST-060, TEST-179 — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [x] `INV-091` The Lock has exactly two members: the chain's AaveAdapter and LPVaultSwap, fixed as immutables at the Lock's d — PROP-037, PROP-075, TEST-011, TEST-060, TEST-270 — Lock job 0f0bbe338f844d87ba9968713df8b185

## ATTACK (1: 0 verified, 0 failed, 1 not run, 0 unlinked)

- [~] `ATTACK-169` Lock that cannot admit vaults and ledgers added later — TEST-060

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
