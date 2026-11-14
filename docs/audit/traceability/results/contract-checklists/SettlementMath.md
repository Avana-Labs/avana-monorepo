# Checklist: SettlementMath

Spec pages: 11-lpvaultswap.md#Settlement math. CVL specs: none.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (22: 1 verified, 0 failed, 20 not run, 1 unlinked)

- [~] `SPEC-LIQ-001` (11-lpvaultswap.md:258) **Net bonus.** `bNet = 10⁴ + ⌊(b − 10⁴) × (10⁴ − lf) / 10⁴⌋` bps, with `b` and `lf` read before `liquidationCa — PROP-017, TEST-050, TEST-069, TEST-113, TEST-198
- [~] `SPEC-LIQ-002` (11-lpvaultswap.md:259) **No cost term.** A liquidation has no cost paid outside `R`: LPVaultSwap takes no flash loan (`REQ-SWAP-012`) — PROP-017, TEST-198
- [~] `SPEC-LIQ-003` (11-lpvaultswap.md:260) **Effective slippage.** `s = min(slippageAllowanceBps, ⌊10⁴ × (bNet − 10⁴) / bNet⌋)` if `bNet > 10⁴`, else `s  — PROP-017, PROP-018, PROP-059, TEST-050, TEST-069, TEST-078, TEST-113, TEST-198
- [~] `SPEC-LIQ-004` (11-lpvaultswap.md:261) **Seized oracle value.** `V = mulDiv(c × Pc, 10^dd, 10^dv × Pdebt)`, rounded down. Units: debt units; `c` in v — PROP-018, TEST-048, TEST-050, TEST-051, TEST-069, TEST-072, TEST-074, TEST-078, TEST-115, TEST-198, TEST-202, TEST-247, TEST-284
- [~] `SPEC-LIQ-005` (11-lpvaultswap.md:262) **Recovery floor.** `U = Σᵢ ⌈pᵢ × 10^dd / (10^dᵢ × Pdebt)⌉` over the `n` released tokens (one raw unit of each — PROP-018, PROP-048, PROP-059, TEST-048, TEST-051, TEST-069, TEST-072, TEST-078, TEST-081, TEST-161, TEST-198, TEST-216, TEST-232, TEST-246, TEST-281
- [~] `SPEC-LIQ-006` (11-lpvaultswap.md:263) **Recovered amount.** `R = T balance after the last route call − T balance immediately before LPVaultSwap call — TEST-047, TEST-048, TEST-051, TEST-053, TEST-074, TEST-170, TEST-232
- [~] `SPEC-LIQ-007` (11-lpvaultswap.md:264) **No flash premium on the debt.** The term `φD` does not exist in a liquidation (`Q-404`): the oracle gain `G` — PROP-018, PROP-059, TEST-052, TEST-198
- [~] `SPEC-LIQ-008` (11-lpvaultswap.md:265) **Realized surplus.** `S = max(0, R_f − D)`, with `R_f = max(R, minRec) = R + max(0, minRec − R)`, the recover — PROP-015, PROP-069, TEST-051, TEST-078, TEST-198, TEST-233
- [~] `SPEC-LIQ-009` (11-lpvaultswap.md:266) **Avana fee.** `A = min(⌊G × avanaFeeShareBps / 10⁴⌋, S)` with the oracle gain `G = max(0, V − D)`. Units: deb — PROP-015, PROP-069, TEST-051, TEST-062, TEST-069, TEST-078, TEST-198, TEST-240
- [~] `SPEC-LIQ-010` (11-lpvaultswap.md:267) **Caller payout and conservation.** `keeperOut = (Kf + R') − (D + A + B)`, with `R' = R + shortfall` and `B` f — PROP-015, PROP-059, TEST-048, TEST-051, TEST-069, TEST-078, TEST-093, TEST-104, TEST-170, TEST-174, TEST-198, TEST-216, TEST-233, TEST-246
- [~] `SPEC-LIQ-011` (11-lpvaultswap.md:268) **No in-kind cap.** Replaces the in-kind cap (`Q-401`). Every liquidation pays the caller in the debt asset by — TEST-198
- [ ] `SPEC-LIQ-012` (11-lpvaultswap.md:269) **No in-kind valuation.** Replaces the in-kind oracle value (`Q-401`). Released tokens are valued only by the  — TEST-072 (only excluded checks: tag on a test named for another row)
- [~] `SPEC-LIQ-013` (11-lpvaultswap.md:270) **No in-kind split.** Replaces the in-kind split (`Q-401`). When both routes of a token into the debt asset ar — TEST-053, TEST-119, TEST-232
- [~] `SPEC-LIQ-014` (11-lpvaultswap.md:271) **Pending-settlement floor.** For the tokens `aᵢ` released by `Collateralization.settlePending`, valued in the — PROP-018, TEST-170, TEST-198, TEST-232
- [x] `SPEC-LIQ-015` (11-lpvaultswap.md:272) **Flash pre-loan bound.** Applies to `deleverage` and to the flash liquidation helper, never to `liquidate`, w — PROP-036, PROP-080, TEST-046, TEST-052, TEST-174, TEST-198, TEST-239, TEST-267, TEST-292 — test/halmos/AaveV3FlashSource.halmos.t.sol:AaveV3FlashSourceHalmosTest.check_PROP_080_completedLoanRepaidWithinCap
- [~] `SPEC-LIQ-016` (11-lpvaultswap.md:273) **Listing liveness.** A liquidation needs `minLB × (10⁴ − slippageAllowanceMinBps) ≥ 10⁸` for every market on  — TEST-113, TEST-198
- [~] `SPEC-LIQ-017` (11-lpvaultswap.md:274) **Leftover debt asset.** `leftover = Kf − D` stays in LPVaultSwap's `T` balance and returns to the caller insi — PROP-059, TEST-048, TEST-051, TEST-174, TEST-198, TEST-240, TEST-289
- [~] `SPEC-LIQ-018` (11-lpvaultswap.md:275) **Per-leg minimum output.** For each released token `i ≠ T` with `aᵢ > 0` that a call swaps, LPVaultSwap passe — PROP-018, PROP-059, TEST-053, TEST-072, TEST-161, TEST-170, TEST-198, TEST-227, TEST-232, TEST-233, TEST-239
- [~] `SPEC-LIQ-019` (11-lpvaultswap.md:276) **Caller shortfall top-up.** With the call's `maxShortfall`, every leg runs at `sLeg = min(9,999, s + min(maxS — PROP-015, PROP-019, TEST-078, TEST-174, TEST-198, TEST-233, TEST-246, TEST-289
- [~] `SPEC-LIQ-020` (11-lpvaultswap.md:277) **Repay-with-collateral sizing.** For `deleverage` of `units` of market `m` against debt reserve `r`: `V = mul — TEST-198, TEST-239
- [~] `SPEC-LIQ-021` (11-lpvaultswap.md:278) **Liquidation throughput.** For a market with `N` liquidation calls queued after a price drop (accounts liquid — TEST-093, TEST-218, TEST-277
- [~] `SPEC-LIQ-022` (11-lpvaultswap.md:279) **Keeper reward and borrower surplus.** With `S` from `SPEC-LIQ-008`, `G = max(0, V − D)` and `A` from `SPEC-L — PROP-015, TEST-048, TEST-051, TEST-078, TEST-170, TEST-198, TEST-240

## TEST rows (1: 0 verified, 0 failed, 1 not run, 0 unlinked)

- [~] `TEST-198` [fuzz] Debt-asset settlement arithmetic: for debt assets of 6 and 18 decimals and `Pdebt` across `[0.5e8, 5,000e8]`, 

## PROP rows (1: 1 verified, 0 failed, 0 not run, 0 unlinked)

- [x] `PROP-044` [SMTChecker] LPOracle (with the pricing library of each AMM protocol), LPVaultSwap (with SettlementMath), each AMM integrat — ParameterStore job 5cf1a73b625f4624b65c99923de6cb24

## INV (2: 0 verified, 0 failed, 2 not run, 0 unlinked)

- [~] `INV-038` The loss a liquidation can leave its caller below the debt it funded is bounded. With `s` as in `INV-034` and  — PROP-019, PROP-047, TEST-051, TEST-078, TEST-081, TEST-093, TEST-100, TEST-104, TEST-160, TEST-161, TEST-198, TEST-246
- [~] `INV-086` Avana fee bounded and independent of routing. In every routed liquidation `A ≤ S = max(0, R_f − D)` with `R_f  — PROP-069, TEST-048, TEST-198, TEST-240

## ATTACK (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


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
