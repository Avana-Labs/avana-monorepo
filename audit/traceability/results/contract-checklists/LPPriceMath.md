# Checklist: LPPriceMath

Spec pages: 10-lp-oracle.md#LPPriceMath. CVL specs: none.

Run results: none given (links only); recorded prover results and Halmos logs are read. [x] verified (ran and passed), [!] failed, [~] not run (linked, no result), [ ] unlinked (no counting check).

## REQ / SPEC on the page (14: 0 verified, 0 failed, 14 not run, 0 unlinked)

- [~] `SPEC-ORC-001` (10-lp-oracle.md:212) **Leg normalisation.** For a raw answer `a` (the signed `int256` of `latestRoundData()`) with `f` decimals: `n — TEST-037, TEST-038, TEST-070, TEST-219
- [~] `SPEC-ORC-002` (10-lp-oracle.md:213) **Route value and timestamp.** One leg: `r = n`. Two legs `A` (token in intermediate `X`, raw `aA`, `fA` decim — TEST-037, TEST-070, TEST-219, TEST-276
- [~] `SPEC-ORC-019` (10-lp-oracle.md:214) **Feed age limit.** For each leg: `feedMaxAge = feedHeartbeat + heartbeatMargin`, where `feedHeartbeat` is the — TEST-040, TEST-219, TEST-250, TEST-276
- [~] `SPEC-ORC-005` (10-lp-oracle.md:215) **Vault-token unit.** One vault-token base unit is one unit of the position measure the AMM integration credit — TEST-036, TEST-062, TEST-139, TEST-264
- [~] `SPEC-ORC-007` (10-lp-oracle.md:216) **Fair composition is the minimum over pool prices.** For a price vector `x`, let `V(a) = Σ_i a_i · x_i / 10^( — TEST-217, TEST-279
- [~] `SPEC-ORC-008` (10-lp-oracle.md:217) **Price of one whole vault token.** With `a = composition(10^d, v)` (raw units, each floored by the pricing mo — PROP-023, PROP-024, TEST-036, TEST-037, TEST-070, TEST-217, TEST-219, TEST-230
- [~] `SPEC-ORC-011` (10-lp-oracle.md:218) **USD band.** For a market whose tokens are all USD-pegged stables, the market is in band iff `usdBandLow^⊗n ≤ — TEST-037, TEST-043, TEST-251
- [~] `SPEC-ORC-012` (10-lp-oracle.md:219) **Fresh price and served timestamp.** If the market is not failed: `fresh = price8(v)` (`SPEC-ORC-008`) and `s — PROP-074, TEST-037, TEST-038, TEST-040, TEST-219, TEST-231
- [~] `SPEC-ORC-015` (10-lp-oracle.md:220) **Age limits of the served price.** When the market is not failed, let `Λ` be the legs of each token's route i — PROP-074, TEST-037, TEST-219, TEST-250, TEST-276
- [~] `SPEC-ORC-017` (10-lp-oracle.md:221) **Served price by state.** Let `A = accepted.answer`, `fresh` as in `SPEC-ORC-012`, and, for a disagreement, ` — PROP-074, TEST-037, TEST-038, TEST-039, TEST-044, TEST-219, TEST-230, TEST-294
- [~] `SPEC-ORC-020` (10-lp-oracle.md:222) **Second-source agreement.** For token *i* with quote `q_i` and second-source value `s_i` (8-decimal USD per w — PROP-026, PROP-100, TEST-037, TEST-039, TEST-219, TEST-250, TEST-276, TEST-294
- [~] `SPEC-ORC-021` (10-lp-oracle.md:223) **Sequencer gate.** On a chain whose `sequencer.feed ≠ address(0)`, read `(answer, startedAt)` from its `lates — TEST-037, TEST-275, TEST-276
- [~] `SPEC-ORC-022` (10-lp-oracle.md:224) **Observation buffer per chain.** For a consistency check over window `W` on a pool that writes at most one ob — TEST-037, TEST-139, TEST-250, TEST-264, TEST-265
- [~] `SPEC-ORC-023` (10-lp-oracle.md:225) **Gas guard for external reads.** Each external read `k` of an evaluation (legs, previous-phase lookups, secon — TEST-037, TEST-038, TEST-042, TEST-219, TEST-275

## TEST rows (1: 0 verified, 0 failed, 1 not run, 0 unlinked)

- [~] `TEST-217` [fuzz] Conservative LP value (`INV-078`): pool liquidity 10⁴ to 10¹⁵, Chainlink answers 0.01 to 2.0 per leg, pool spo

## PROP rows (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## INV (0: 0 verified, 0 failed, 0 not run, 0 unlinked)


## ATTACK (1: 0 verified, 0 failed, 1 not run, 0 unlinked)

- [~] `ATTACK-055` Oracle rounding and normalisation edge cases — TEST-038, TEST-070, TEST-219

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
