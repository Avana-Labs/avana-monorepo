# Checklist: PayoutEscrow

Spec pages: 18-payout-escrow.md. CVL specs: PayoutEscrow.spec.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (19: 0 verified, 0 failed, 19 not run, 0 unlinked)

- [~] `REQ-ESCROW-001` (18-payout-escrow.md:70) The PayoutEscrow MUST be immutable: no proxy, no `delegatecall`, no `selfdestruct`, no owner, no role, no sett — TEST-032, TEST-179
- [~] `REQ-ESCROW-002` (18-payout-escrow.md:71) `deposit` MUST revert with `NotLPVaultSwap` unless `msg.sender == LP_VAULT_SWAP`, with `NotLocked` unless `LOC — PROP-037, TEST-173, TEST-177, TEST-179
- [~] `REQ-ESCROW-003` (18-payout-escrow.md:72) `deposit` MUST request `amount` of `token` from `LP_VAULT_SWAP` with `SafeERC20.safeTransferFrom`, measure `re — PROP-052, TEST-061, TEST-173, TEST-179
- [~] `REQ-ESCROW-004` (18-payout-escrow.md:73) `claim(token, recipient)` MUST revert with `LockHeld` while `LOCK.isLocked()` is true, so a claim never runs i — PROP-052, TEST-061, TEST-173, TEST-177, TEST-179
- [~] `REQ-ESCROW-005` (18-payout-escrow.md:74) A credit MUST be claimable only by the account it was credited to, as `msg.sender`; the escrow has no claim-on — PROP-052, TEST-173, TEST-179
- [~] `REQ-ESCROW-006` (18-payout-escrow.md:75) For every token, `totalClaimable[token]` MUST equal the sum of `claimable[token][b]` over all credited account — PROP-052, TEST-080, TEST-173, TEST-179
- [~] `REQ-ESCROW-007` (18-payout-escrow.md:76) `deposit` and `claim` MUST hold a transient reentrancy flag for their whole duration and revert with `Reentran — TEST-179
- [~] `REQ-ESCROW-008` (18-payout-escrow.md:77) The escrow MUST NOT check prices, price states, the application pause state or its reason, circuit breakers, t — TEST-179, TEST-229
- [~] `REQ-ESCROW-017` (18-payout-escrow.md:79) A borrower surplus that LPVaultSwap could not deliver is deposited and credited to the borrower's wallet: `dep — TEST-179
- [~] `REQ-ESCROW-018` (18-payout-escrow.md:80) Avana's fee, a route residue or dust leg owed to the caller, and the residue of `settlePending` that LPVaultSw — TEST-179, TEST-229
- [~] `REQ-ESCROW-019` (18-payout-escrow.md:101) Constructor with a zero `lpVaultSwap` or `lock`, a `lock` without code, or a `lock` whose `LP_VAULT_SWAP()` is — TEST-179
- [~] `REQ-ESCROW-009` (18-payout-escrow.md:102) `deposit` from any caller other than LPVaultSwap, or while the Lock is not held by LPVaultSwap | reverts with  — PROP-037, TEST-179
- [~] `REQ-ESCROW-010` (18-payout-escrow.md:103) `deposit` with `amount == 0` or `account == address(0)` | reverts with `ZeroAmount` or `InvalidAccount` (Sourc — PROP-037, TEST-177, TEST-179
- [~] `REQ-ESCROW-011` (18-payout-escrow.md:104) Escrow balance did not rise in `deposit` or the token refuses the transfer to the escrow; in `claim`, the escr — PROP-052, TEST-179
- [~] `REQ-ESCROW-012` (18-payout-escrow.md:105) `claim` while the Lock is held | reverts with `LockHeld` (Source: Q-148, Q-214) — PROP-052, TEST-179
- [~] `REQ-ESCROW-013` (18-payout-escrow.md:106) `claim` with no credit for the caller and token | reverts with `NothingToClaim` (Source: Q-214, Q-217) — PROP-052, TEST-177, TEST-179
- [~] `REQ-ESCROW-014` (18-payout-escrow.md:107) `claim` to `address(0)` or to the escrow itself | reverts with `InvalidRecipient` (Source: Q-214) — PROP-052, TEST-179
- [~] `REQ-ESCROW-015` (18-payout-escrow.md:108) The token refuses the transfer to the claim's `recipient` | reverts with the token's error; the credit is unch — TEST-173, TEST-179
- [~] `REQ-ESCROW-016` (18-payout-escrow.md:109) Reentry into `deposit` or `claim` during either call | reverts with `Reentrancy` (Source: Q-148, Q-214) — TEST-179

## TEST rows (7: 0 verified, 0 failed, 6 not run, 1 unlinked)

- [~] `TEST-179` [unit] Payout escrow: with a borrower that reverts on receipt, a debt asset that blocklists the borrower, a token tra
- [~] `TEST-173` [invariant] Escrow conservation: with the handlers of `TEST-082` driving routed liquidations whose borrower-surplus, Avana
- [ ] `TEST-215` [invariant] Multi-actor invariant suite (Foundry invariant test with handlers, extending `TEST-082`). Actors: borrowers wi (only excluded checks: tag on a test named for another row)
- [~] `TEST-221` [fork] Token edge cases. A fee-on-transfer mock pool token is rejected at listing; a fee switched on after listing on
- [~] `TEST-223` [fork] LP journeys on one fork, end to end, with the Lens asserted at every step against execution: deposit → borrow 
- [~] `TEST-229` [unit] Address freeze: a frozen wallet's new pledge (non-rescue), borrow (as caller or receiver), withdraw-with-debt,
- [~] `TEST-286` [fork] Blocked payout never reverts a liquidation (`ATTACK-196`): on a fork, USDC blocklists `feeRecipient`, then the

## PROP rows (3: 3 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-037` [Certora] Lock: any Avana function reachable only from inside the fixed set reverts unless the Lock is held and `msg.sen — test/halmos/PegModuleRoute.halmos.t.sol:PegModuleRouteHalmosTest.check_PROP_037_swapOnlyForLPVaultSwapUnderLock
- [x] `PROP-043` [SMTChecker] The immutable contracts (every LPVault, Collateralization, vault token, VaultTokenFactory, ProxyManager, Posit — Lock job 0f0bbe338f844d87ba9968713df8b185
- [x] `PROP-052` [Certora] PayoutEscrow (the payout escrow): for every credited account `a` (a borrower's wallet, `feeRecipient` or a liq — PayoutEscrow job 3f8731c0a94045939591ca3eb7b4a5f7

## INV (9: 2 verified, 0 failed, 6 not run, 1 unlinked)

- [~] `INV-020` In a borrow of debt reserve `r`, `r`'s asset moves from `r`'s funding Hub (the CDP Spoke's home Hub, or anothe — TEST-027, TEST-106
- [x] `INV-021` At the end of every transaction: (a) every ERC-20 allowance an Avana contract granted during the transaction i — PROP-016, PROP-068, PROP-080, TEST-021, TEST-054, TEST-080, TEST-092, TEST-177, TEST-232 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_donationNeverForwarded
- [~] `INV-036` The Avana fee in routed mode is `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)` with `avanaFeeShareBps` 2,000 bps ( — PROP-015, PROP-069, TEST-051, TEST-198, TEST-240
- [~] `INV-039` No in-kind settlement (Q-401). Every liquidation, through the one entry point `liquidate` (`INV-062`), settles — PROP-019, PROP-021
- [x] `INV-061` PayoutEscrow conservation. For every credited account `a` (the borrower, `feeRecipient` or the liquidation's c — PROP-052, TEST-080, TEST-173, TEST-179, TEST-286 — PayoutEscrow job 3f8731c0a94045939591ca3eb7b4a5f7
- [~] `INV-081` Stops never reach exits or liquidation. The application pause state and reason, the market and debt breakers a — PROP-066, TEST-218, TEST-228, TEST-229
- [~] `INV-052` The vault tokens, VaultTokenFactory, every LPVault (one per AMM protocol per chain), Collateralization (one pe — PROP-099, TEST-108, TEST-166
- [~] `INV-053` No Avana function transfers vault tokens or a recorded NFT except through the flows in `INV-007`, `INV-009` an — PROP-051, TEST-032
- [ ] `INV-079` Settlement-asset conservation across sequences, per asset. For each settlement asset `a` (each debt asset, GHO

## ATTACK (1: 0 verified, 0 failed, 1 not run, 0 unlinked)

- [~] `ATTACK-118` Payout escrow claim by the wrong person — PROP-052, TEST-173, TEST-179

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
