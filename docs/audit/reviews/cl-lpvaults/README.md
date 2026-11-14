# Concentrated-liquidity LPVaults review (Uniswap v3 and Slipstream)

| Item | Value |
|---|---|
| Date | 2026-11-11 |
| Contracts | `src/amm/uniswap-v3/UniswapV3Integration.sol`, `src/amm/slipstream/SlipstreamIntegration.sol`, the shared base `src/amm/concentrated-liquidity/` (`ClLPVaultBase`, `ClLPVaultCustody`, `ClLPVaultMarkets`, `ClPriceMath`) and their interfaces |
| Spec | [2.2 LP Vault](../../../spec/02-contracts/02-lp-vault.md), [2.19](../../../spec/02-contracts/19-amm-integration-interface.md), [2.20](../../../spec/02-contracts/20-uniswap-v3-integration.md), [2.21](../../../spec/02-contracts/21-aerodrome-slipstream-integration.md), [2.22](../../../spec/02-contracts/22-amm-integration-readiness.md); `INV-005`, `INV-007`, `INV-044`, `INV-045`, `INV-052`, `INV-091`; `ATTACK-001`, `-003`, `-006`, `-007`, `-008`, `-015`, `-016`, `-017` |
| Method | Independent adversarial review from the spec and the code only; one PoC test per demonstrable finding, run against the code as reviewed |
| Result | No Critical, High or Medium. 2 Low, 3 Informational, 9 spec points. Custody, principal and fee separation, Lock enforcement and stray handling held under every attack tried |

One folder covers both LPVaults: four of the five findings sit in the shared base or apply to both.

## Findings

| ID | Severity | Title | Location | Description | PoC | Recommendation |
|---|---|---|---|---|---|---|
| CL-01 | Low | The 2^64 saturation of the oracle square-root price overvalues a full-range market by up to ~2^32 | `ClPriceMath._rawOracleSqrt`, `oracleSqrtPrice` (L121–L140, L249–L258); `ClLPVaultMarkets.composition` | When the raw ratio `p0·10^d1 / (p1·10^d0)` reaches 2^64, `oracleSqrtPrice` returns `MAX_SQRT_RATIO − 1` (≈ 2^160) instead of the true root (≈ 2^128 to 2^160). For a range whose upper tick lies above ~443,636 (every full-range market), the clamp to `sb` then values the units as all token1 at the top of the range, far more token1 than they hold. Both LPVaults (and the LPOracle, which compiles the same function) are affected. Details below | `test_POC_CL01_saturatedOracleSqrtOvervaluesAFullRangeMarket` (both suites) | Compute the root above 2^64 instead of saturating: `s = isqrt(mulDiv(num, 2^128, den)) << 32` while `num < 2^128 · den`, saturate only at `s ≥ MAX_SQRT_RATIO`. Fix `SPEC-ORC-009` and its Z3 model (`MATH-UO-10`/`11`) first; correct the claim in `REQ-ORACLE-104` |
| CL-02 | Info | Slipstream pledge never compares the key's generation with the market's pinned generation | `SlipstreamIntegration._isEncumbered` / `ClLPVaultBase._checkPosition` (L215–L227) | 2.21's function table and `REQ-AMM-SLIP-001`/`-007` say `receivePosition` requires the key's generation to equal the market's. The code relies only on `getPool` of the key's generation factory returning a different pool. That holds for the four Base factories (each NPM's positions live in its own factory's pools), so no loss follows today; a factory that resolved another generation's pool would let an NFT of generation `g` be credited in a market pinned to generation `G` | `test_POC_CL02_crossGenerationKeyIsNotCheckedAgainstTheMarketGeneration` | Add `if (_positionManager(positionKey) != m.cfg.positionManager) revert PoolMismatch();` (with the CL-03 check, measured +106 bytes; see CL-05), or change the spec text to say the refusal comes from the pool derivation |
| CL-03 | Low | Slipstream accepts any factory-enabled tick spacing, so `REQ-AMM-SLIP-014`'s 2^120 − 1 market bound is not enforced for spacings ≥ 6,932 | `SlipstreamIntegration._validatePool` (L215–L236) | `maxLiquidityPerTick(s) > 2^120 − 1` for every `s ≥ 6,932` (`FINDING-003`); `bindMarket` stores that value and never checks it. If Aerodrome enables such a spacing and a market is listed on it, records each below Collateralization's per-record bound can together exceed the market bound. Uniswap v3 is safe through `_standardSpacing`. Reaching 2^120 liquidity is economically out of reach, so the effect is a spec rule without an on-chain guard | `test_POC_CL03_largeSpacingBindsAboveTheCreditedLiquidityBound` (spacing 8,000: `maxLiquidityPerTick = 1.54 × 10^36`) | In `_validatePool` refuse `cfg.tickSpacing > 6931` (or `maxLiquidityPerTick(s) > type(uint120).max`) with `InvalidPool`; state the bound in `REQ-AMM-SLIP-008` and say what "standard tick spacing" in `TEST-139` means for Slipstream |
| CL-04 | Info | `collectFees` accepts LPVaultSwap as the Lock holder | `ClLPVaultCustody.collectFees` (L128) via `_onlyCustodyCaller` (`ClLPVaultBase` L168) | `REQ-VAULT-064` requires the Lock held by the AaveAdapter; the LPVault checks only `holder() != 0`. Collateralization enforces the AaveAdapter, so no path reaches it today; the LPVault-level check is weaker than its own spec. Fees still go only to the depositor of record | `test_POC_CL04_collectFeesAcceptsLPVaultSwapAsHolder` (both suites) | Either check `LOCK.holder() == LOCK.AAVE_ADAPTER()` in `collectFees`, or relax `REQ-VAULT-064` to "held by a Lock member" and cite Collateralization's check |
| CL-05 | Info | Slipstream runtime code has 140 bytes of EIP-170 margin, too little for the fixes above | `SlipstreamIntegration` build | Runtime 24,436 bytes at 10,000 optimizer runs. Measured: CL-02 + CL-03 checks → 24,542 (34 left); adding the CL-01 fix → 24,598 (22 bytes over the limit). At 1,000 runs the current code is 22,510 bytes (2,066 left) | `forge build --sizes src/amm` | Options at review time: a lower `optimizer_runs` for this file through `compilation_restrictions`, or the views (`riskMetadata`, `riskStatus`, `consistencyDeviation`) moved to a smaller footprint; the fix used 1,000 runs (see Fix status) |

## Fix status

All five findings and the nine spec points were fixed on 2026-11-11 (approved by Josue the same day). Each fix has a regression test that fails on the code as reviewed and passes on the fixed code.

| ID | Status | Fix | Regression tests |
|---|---|---|---|
| CL-01 | Fixed | `ClPriceMath._rawOracleSqrt`: for `2^64·den ≤ num < 2^128·den` the root is `isqrt(mulDiv(num, 2^128, den)) << 32`, clamped only at `MAX_SQRT_RATIO`; `MAX_SQRT_RATIO − 1` only from `num ≥ 2^128·den` (tested as `num >> 128 ≥ den`). `SPEC-ORC-009` rewritten with three branches and checked by `MATH-UO-11a`–`11k`, `MATH-UO-12e` (monotone and continuous at 2^64, within 2^32 below the exact root, never above it); `REQ-ORACLE-104` corrected | `SlipstreamIntegrationMarketsUnitTest.test_TEST_279_fullRangeQuoteStaysFairAboveTheTwoTo64Ratio`, `UniswapV3IntegrationMarketsUnitTest.test_TEST_279_fullRangeQuoteStaysFairAboveTheTwoTo64Ratio` (the PoC market quotes within 1 ppm of its fair $2.24, never above), `ClPriceMathUnitTest.test_TEST_279_oracleSqrtPriceAboveTwoTo64IsTheRootNotASaturation`, `testFuzz_TEST_279_oracleSqrtPriceIsMonotoneAndNeverAboveTheRoot`, `ClPriceMathDifferentialTest.testFuzz_TEST_037_oracleSqrtPriceMatchesReferenceOverTheLibraryBounds` |
| CL-02 | Fixed | `ClLPVaultBase._checkPosition` refuses with `PoolMismatch` unless the key's position manager is the market's pinned one, at the pool check | `SlipstreamIntegrationCustodyUnitTest.test_TEST_265_theKeysGenerationMustBeTheMarketsEvenIfItsFactoryResolvesThePool`; Certora `LPVault.spec` `receivePositionKeepsTheMarketsPositionManager` |
| CL-03 | Fixed | `SlipstreamIntegration._validatePool` refuses `tickSpacing > 6,931` with `InvalidPool` (`maxLiquidityPerTick(6,931) ≤ 2^120 − 1 < maxLiquidityPerTick(6,932)`, `AMM-A5e`) | `SlipstreamIntegrationMarketsUnitTest.test_TEST_265_bindMarketRefusesSpacingsAboveTheCreditedLiquidityBound`, `ClPriceMathUnitTest.test_TEST_279_spacing6931IsTheLargestBelowTheCreditBound` |
| CL-04 | Fixed | `ClLPVaultCustody.collectFees` requires `LOCK.holder() == LOCK.AAVE_ADAPTER()` (`LockNotHeld`), per `REQ-VAULT-064` | `test_TEST_017_collectFeesNeedsTheAaveAdapterAsLockHolder` in `SlipstreamIntegrationCustodyUnitTest` and `UniswapV3IntegrationCustodyUnitTest`; Certora `collectFeesNeedsTheAaveAdapterLock` |
| CL-05 | Fixed | Both LPVault files compile at 1,000 optimizer runs (`compilation_restrictions` in `foundry.toml`); the four Certora confs of these contracts use `solc_optimize` 1000. Runtime after every fix: Slipstream 22,936 bytes (1,640 of margin), Uniswap v3 21,744 bytes (2,832). Re-checked 2026-11-14: `foundry.toml` now compiles both at 200 runs; the build of 2026-11-13 gives Slipstream 23,167 bytes (1,409 of margin) and Uniswap v3 22,105 bytes (2,471) | `forge build --sizes`, `script/check-file-size.sh` |
| S1 | Fixed | 2.19 `SPEC-AMM-CORE-002`: four generations | — |
| S2 | Fixed | 2.21 `REQ-AMM-SLIP-020`: fee collection dropped from the `PoolLocked` row; it reverts with the pool's own upstream error (`REQ-VAULT-066`) | — |
| S3 | Fixed | 2.21 Dependencies: the LPVault never reads `fee` and stores 0; `ClMarketConfig.fee` comment corrected | — |
| S4 | Fixed | 2.21 Events: `MarketBound` carries no generation; indexers read `clMarket(marketId)` and the key's high byte | — |
| S5 | Fixed | 2.21 function table and `REQ-AMM-SLIP-001`: the generation check now exists (CL-02) | as CL-02 |
| S6 | Fixed | 2.2 `REQ-VAULT-064`, `REQ-VAULT-150`, Permissions and Dependencies; 2.19 and 2.21 Permissions (CL-04) | as CL-04 |
| S7 | Fixed | 2.21 `REQ-AMM-SLIP-008`, `-014`, `-017`, differences table; 5.1 `TEST-139` states what a standard spacing is per AMM protocol | as CL-03 |
| S8 | Fixed | 2.10 `SPEC-ORC-009`, `REQ-ORACLE-104` (CL-01) | as CL-01 |
| S9 | Fixed | 2.20 `REQ-VAULT-147` in the code's order: every check, then the custody write, then the pull, the owner check and the units read | — |

## Details

### CL-01

PoC numbers (Slipstream market on the full range of a spacing-100 pool; the Uniswap v3 suite repeats it on the full range of the 0.3% tier with the same result): token0 has 6 decimals, token1 18. Listed at $1 / $1, the raw ratio is 10^12, and a 100× shock gives 10^14, so the `TEST-139` listing guard ("raw ratio below 2^64 under a 100× shock") passes. token1 then falls to 5 × 10^−8 USD (`p1 = 5`, a valid 8-decimal answer above a `minAnswer` of 1), and the raw ratio is 2 × 10^19 ≥ 2^64.

| | token0 | token1 | value8 |
|---|---|---|---|
| `composition(5 × 10^15 units)` (saturated) | 0 | 9.19 × 10^34 | 459,494,190,594,405,080 ($4.59 × 10^9) |
| Fair amounts at the true oracle ratio (`√r = 4.47 × 10^9`) | 1,118,034 | 2.24 × 10^25 | 223,606,698 ($2.24) |

The same units held $10,000 at listing. The quote is about 2 × 10^9 times the fair value; at exactly `r = 2^64` the factor is 2^31. The excess is `L·(sb − s)²/sb` for any price `s` used in place of the true one below `sb`, so a quote at a price above the true price always overvalues an in-range holding.

When it applies: a pair whose raw ratio grows past 2^64 with the falling token's feed still valid, and a market range above tick ~443,636 (the full range of every spacing). The listing guard only guarantees that this takes a relative move of more than 100×; a 6-decimal token0 against an 18-decimal token1 listed at par needs about 1.8 × 10^7. A pair with equal decimals near par (every launch stablecoin pair) cannot reach it. The LPOracle reports `PRICE_CLAMPED` (Drifting), which blocks new pledges and debt, but liquidation and the HF still use the quote: once the ratio crosses 2^64, open positions in the market look healthy again and are not liquidated, and LPVaultSwap's minimum-recovery check built from `composition` cannot be met. A full-range position's fair value falls with the square root of the ratio, so at the crossing it has lost between `√100` = 10× (a pair listed at the guard's edge) and about 4,000× (the par-listed 6/18 pair) of its listing value; the additional loss is the residual value of positions not liquidated before the crossing, bounded by the market's caps. `REQ-ORACLE-104`'s sentence "the composition already values that holding correctly" holds for the range clamp of `SPEC-ORC-006` but not for this clamp of `SPEC-ORC-009`.

The fix measured in CL-05: for `num ≥ 2^64·den`, `raw = isqrt(mulDiv(num, 2^128, den)) << 32` (fits: `num ≤ 10^30 < 2^128·den`), flagged high only when `raw ≥ MAX_SQRT_RATIO`. Its error is below `2^32` in Q64.96, against prices above `2^128`.

### CL-02

The PoC registers market 1's pool (generation 2) under generation 0's factory for the same pair and spacing, mints a generation-0 NFT on `[−50, 50]` and pledges it into market 1: `receivePosition` returns its units, `marketOfPosition` is market 1, custody sits on generation 0's manager, and `clMarket(1).positionManager` is generation 2's. On Base each manager computes its pools from its own factory, so `getPool` of another generation's factory never returns the market's pool for a real NFT; the finding is the gap between the stated rule and the mechanism that enforces it.

## Spec points

| # | Pages | Point | Suggested change |
|---|---|---|---|
| S1 | 2.19 `SPEC-AMM-CORE-002` | Says Slipstream has "three" position manager and factory pairs on Base; 2.21, `generationCount()` and the constructor use four | "four" |
| S2 | 2.21 `REQ-AMM-SLIP-020` vs 2.2 `REQ-VAULT-066`, 2.20 `REQ-AMM-V3-003` | `REQ-AMM-SLIP-020` says fee collection reverts `PoolLocked` while `unlocked == false`; the other two (which 2.21 inherits) and the code rely on the pool's own lock, so the error is the pool's upstream revert | Drop "fee collection" from `REQ-AMM-SLIP-020`, or name the upstream error |
| S3 | 2.21 Dependencies vs Storage and `REQ-AMM-SLIP-005` | Dependencies says CLPool `fee` is "stored at listing as information"; Storage says `fee` is always 0 and `REQ-AMM-SLIP-005` forbids a fixed fee. The code never calls `pool.fee()` and stores 0 (the `ClMarketConfig` field comment still says "Fee tier at listing, pips") | Remove `fee` from the CLPool call list or say "not read by the LPVault" |
| S4 | 2.21 Events | Names a `MarketRegistered` event that "carries the pinned position manager in its shape decoding"; the LPVault emits `MarketBound(marketId, pool, poolId, tickLower, tickUpper)` with no generation, so an indexer reads the generation only from `clMarket(marketId)` | Replace the sentence, or add the manager to the event (bytes: see CL-05) |
| S5 | 2.21 function table, `REQ-AMM-SLIP-001`, `-007` | "receivePosition requires the key's generation to be the market's"; no such check exists (CL-02) | Per CL-02 |
| S6 | 2.2 `REQ-VAULT-064` vs `REQ-VAULT-150` | Fee collection needs the AaveAdapter as holder; the LPVault checks any member (CL-04) | Per CL-04 |
| S7 | 5.1 `TEST-139`, 2.21 `REQ-AMM-SLIP-008`, `-014` | `TEST-139` requires a "standard tick spacing"; Slipstream accepts any enabled spacing, and `REQ-AMM-SLIP-014`'s bound holds only below 6,932 (CL-03) | Per CL-03 |
| S8 | 2.10 `SPEC-ORC-009`, `REQ-ORACLE-104` | The saturation value and the claim that clamped compositions are valued correctly (CL-01) | Per CL-01 |
| S9 | 2.20 `REQ-VAULT-147` vs 2.19 `REQ-AMM-CORE-005` | `REQ-VAULT-147` orders the pool and range checks after `transferFrom` and the custody writes after the liquidity read; `REQ-AMM-CORE-005` and the code run every check and write custody before the pull. The outcome is the same (the call reverts as a whole) | Align `REQ-VAULT-147` with the code's checks-effects-interactions order |

## Checked and holding

- Custody: per-token approvals and NPM `permit` die on the pull (`transferFrom` clears the operator; the LPVault has no `isValidSignature` and no selector `0x1626ba7e`); a stray NFT can never become a record (`owner == address(this)` refused); a re-pledge of a custodied NFT fails the owner check; `onERC721Received` accepts only the allowlisted managers, records nothing and cannot be spoofed by another caller; `returnStray` evaluates the stray condition at execution and resolves unknown-generation keys to `UnsupportedNft`.
- Principal and fee separation: the collect is capped at the removal's own `(a0, a1)` back to back under the Lock, so pre-pledge `tokensOwed` and accrued fees stay with the NFT; a both-zero removal skips the collect, which both managers would reject; `SafeCast` on the caps cannot fail for pool amounts.
- Composition reads no pool state; the range clamp, the −1 reduction and `ClPriceMath` (`sqrtRatioAtTick`, `tickAtSqrtRatio`, `amountsForLiquidity`, `meanTick`, harmonic-mean liquidity) match Uniswap v3-core and periphery, apart from CL-01.
- Pool locks: `receivePosition`, `unwind`, `releaseToDepositor` and `unitsOf` under the Lock check `unlocked` with the right `slot0` layout (7 fields v3, 6 fields Slipstream); `collectFees` and the NPM calls hit the pool's own lock.
- Listing: v3 pool by factory, `getPool` and CREATE2 address with the standard spacings; Slipstream pool by EIP-1167 clone code hash before any pool call, `factory()`, `nft()`, enabled spacing and `getPool`; a self-deployed, self-initialized clone fails `getPool`.
- Donations: ERC-20 or ETH sent to the LPVault changes nothing (no `receive`, no balance read); liquidity added to a custodied NFT is live but never removed or moved except with the NFT to its depositor.

## Not settled

- How the LPOracle, RiskModule and LPVaultSwap react to a CL-01 quote (Drifting state, quote-change cap, USD band, value-based caps) was not reviewed; the PoC stops at the LPVault's `composition`.
- Real Slipstream managers of the four generations were not run (no Base RPC in the workspace); behaviour of `collect` and `decreaseLiquidity` on the Gauge Caps, Gauges V3 and Aero managers is taken from 2.21's recorded fork reads.

## PoC tests

[`poc/ClLPVaults.Review.unit.t.sol`](poc/ClLPVaults.Review.unit.t.sol), run with `forge test -j 2 --match-path test/unit/ClLPVaults.Review.unit.t.sol` in the review workspace: 6 passed.

- `SlipstreamReviewPoC`: `test_POC_CL01_saturatedOracleSqrtOvervaluesAFullRangeMarket`, `test_POC_CL02_crossGenerationKeyIsNotCheckedAgainstTheMarketGeneration`, `test_POC_CL03_largeSpacingBindsAboveTheCreditedLiquidityBound`, `test_POC_CL04_collectFeesAcceptsLPVaultSwapAsHolder`
- `UniswapV3ReviewPoC`: `test_POC_CL01_saturatedOracleSqrtOvervaluesAFullRangeMarket`, `test_POC_CL04_collectFeesAcceptsLPVaultSwapAsHolder`

The PoC file imports the fixtures at their review-time paths (`test/utils/fixtures/`); the Uniswap v3 suite uses `UniswapV3IntegrationHarness`, which differs from the deployed contract only in the pool init code hash.
