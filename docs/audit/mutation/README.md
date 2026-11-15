# Mutation testing

## What it proves

Mutation testing changes the code (flipped conditions, removed checks, swapped operators) and requires a test or rule to fail for each change. A surviving mutant is a behavior no check pins down.

| Kind | Tool | Target |
|---|---|---|
| Foundry suite | `slither-mutate` | Each contract's unit, fuzz and invariant tests |
| Formal rules | `certoraMutate` | Each contract whose Certora rules verify |

## How to run

```bash
cd contracts
.venv/bin/slither-mutate src/lock/lock/Lock.sol --test-cmd 'forge test --match-path "test/unit/Lock.unit.t.sol"'
.venv/bin/certoraMutate certora/conf/Lock.conf
```

Both tools are installed in `contracts/.venv/bin/`. `certoraMutate` reads the conf's `mutations` section, generates the mutants with Gambit and runs the prover on each.

## Scope

Every contract of the layer at each layer gate.

## How often it runs

Layer gate (2.1 … 2.6), both kinds (decided 2026-11-10), and every push to `main` in CI (`mutation-gate.yml`; by hand for one layer or all six). Each target runs in its own job of at most 4 hours: `slither-mutate` per contract and mutator group (three groups that together test every mutant), Gambit per contract, Necessist per test file and `certoraMutate` per Certora conf (with the `CERTORAKEY` secret; without it each job passes with a "certoraMutate not run" warning). `mutation-summary` passes only when every job passed. `certoraMutate` reads the conf's `mutations` section, which every conf of Avana code has: Gambit mutants of each `src/` implementation file the verified contract is built from, with the per-file count of `security/mutation-layers.json` (10 in layer 2.1 and outside the layers, 20 in layers 2.2 to 2.6). `Hub.conf` verifies the unmodified Aave V4 Hub, so it has no mutants and its rules run only in the `certora` job. [contracts/certora/README.md](../../../contracts/certora/README.md#mutation-testing-certoramutate) lists the rules and how to check a conf without a key. `AaveAdapter.conf`, `AaveAdapterGates.conf` and `LPVaultSwap.conf` name `AaveAdapter.sol` and `LPVaultSwap.sol`, which are not in `src/` yet, so their jobs fail with the secret set until those files exist. At the Lock gate a hand-made mutation (two checks swapped) was caught by the Halmos checks.

## Latest result

`mutation-gate` 43653570827 on `main` (commit `48864ef`, dispatched 2026-11-14), recorded as its jobs finish: [results/README.md](results/README.md) (per contract mutants, killed, survived, timed out, not compiled and kill rate; the Necessist table) and [results/survivors.md](results/survivors.md) (every surviving mutant and every removal that left the tests passing). `certoraMutate` did not run (`CERTORA_ENABLED` off); the Certora mutants run with the local Prover through `contracts/script/certora-mutate-local.sh`. In this run the mutants of the LPOracleCL contracts, LPOracleCalls, ParameterStore, ClPriceMath and AaveAdapter ran without some of their own test suites (the `tests` globs of `security/mutation-layers.json`, fixed after the run), so their survivors are marked inflated until the re-dispatch of layers 2.1, 2.2 and 2.5.

### Second triage pass (2026-11-15, at `6805212`)

Every survivor of run 43492416937 now has a class in [contracts/security/slither-mutate-triage.json](../../../contracts/security/slither-mutate-triage.json); each group is a row of [findings-register.md](../findings-register.md) section 2.2.

| Class | Mutants |
|---|---|
| real test gap, test added and passing | 386 |
| real test gap, test to write | 2 |
| equivalent or harmless | 1,020 |
| noise | 52 |
| superseded (the line changed after `aa340fb`) | 4 |
| test set fixed; needs the next mutation-gate run | 227 |
| not triaged | 0 |
| **All** | **1,691** |

- The first pass's gap tests (14 files) pass in targeted `forge test` runs.
- The 52 first-pass gaps marked "not written" now have tests, except 8 shown equivalent: `SM-072` (with feeds that follow the Chainlink round rules, a both-stale interval found after a poke that was not failed always ends after the stored `recoveredAt`), part of `SM-020` (a failed read already falls back to the stored value) and part of `SM-029` (`e.quote` is 0 whenever the market is failed).
- The 393 survivors that pass did not reach (418 by exact text; 25 already matched an entry by the truncated mutant text) were triaged against the source at `6805212`: 214 real gaps, each with a test in a file inside its contract's `mutation-layers.json` test glob, 178 equivalent and 1 noise.
- The tests were run one targeted file set at a time. Kills are confirmed by the next `mutation-gate` run on `main`, which also triages the 227 `LPOracleCL*` and `LPOracleCalls` survivors against their own tests.
- A full parse of the run's logs (multi-line mutants included, matched to the entries by contract, mutator and normalized text) found 13 survivors the first parse had missed, all in `MarketRegistryDebtChecks`, `MarketRegistryOracleChecks` and `MarketRegistryRouteChecks` (`SM-298` to `SM-305`): 2 noise, 9 equivalent or harmless and 2 real gaps whose tests are still to write (a cross-Hub debt reserve with funding-Hub consent accepted; a failed `getOracleConfig` refused even when `checkConfig` returns 0).
- The pass found one defect in `DebtOracle._recordSeen` (`MUT-01` in the register), fixed in [pull request 74](https://github.com/Avana-Labs/avana-monorepo/pull/74).

### Triage of the earlier run 43492416937

`mutation-gate.yml` run 43492416937 on `main` at `aa340fb` (dispatched 2026-11-13) stalled in the queue: 151 `slither-mutate` jobs finished, all of layer 2.1 (three mutator groups per contract), and 243 never ran; the Necessist jobs are in [../necessist/README.md](../necessist/README.md). `slither-mutate` survivors are report-only in CI.

The finished jobs left 1,678 uncaught mutants by the first parse (1,691 by the full parse of the second pass). `survivors.txt` lists 1,617 distinct lines because `grep UNCAUGHT` keeps only the last line of a mutant that spans several lines; the triage reads each contract's log instead.

Triage, at `fda9bed`: [contracts/security/slither-mutate-triage.json](../../../contracts/security/slither-mutate-triage.json). Each entry gives the file, function, line at `aa340fb` and at `fda9bed`, the mutator, the original and mutated text, a fingerprint, the class and the reason; `approval` is `pending`.

| Class | Mutants |
|---|---|
| real test gap | 220 (52 now killed by tests added in this triage, 168 recorded with the missing test described) |
| equivalent or harmless | 778 |
| noise (no-op mutants, an unused constant, error arguments in the out-of-gas path) | 49 |
| superseded (the line changed after `aa340fb`) | 4 |
| not triaged | 400 |
| test set fixed; needs the next mutation-gate run | 227 |

Liquidation and the LPOracle router were triaged in full: `LPVaultSwapDeleverageLogic` 55 (18 real gaps, all now tested), `LPVaultSwapPendingLogic` 23 (4, tested), `LPVaultSwapLiquidationLogic` 14 (5, 4 tested), `LPVaultSwap` 18, `LPVaultSwapStorage` 13 and `SettlementMath` 5 (no gap), `LPPriceMath` 43 (1 gap, tested), `LPOracle` 55 (21 gaps, 18 tested), `LPOracleRecovery` 144 (99 gaps in the recovery-evidence bookkeeping, 6 tested, the rest described). `DebtOracle` 53 (27 gaps described, 18 equivalent, 8 left) `DebtOracleRecovery` 45 (32 gaps described), `DebtOracleEvaluation` 52 (2 gaps described, 36 equivalent or harmless, 14 left) and `DebtOracleReads` 6 (5 gaps described). Tests added: `LPVaultSwap.Deleverage`, `.DeleverageGho`, `.SettlePending`, `.PriceGates`, `.Funding`, `.Shortfall`, `LPPriceMath`, `LPOracle.Access` and `LPOracle.RecoveryEdges` unit files. They have not yet been run: the shared forge gate was held for another run when this triage was written, so the next step is one `forge test --match-path` per file and, if one fails, correcting that test before the 52 mutants are counted as killed.

Not triaged in this pass (400): `LPOracleConfig` 60, `LPOracleReads` 47, `LPOracleViews` 36, `LPOracleEval` 32, `LPOraclePoke` 27, `LPOracleListingLogic` 16, `DebtOracle` 8, `DebtOracleEvaluation` 14, `ParameterStoreRisk` 36, `ParameterStoreAdminRiskLogic` 23, `ParameterStoreListingLogic` 17, `ParameterStoreViews` 8, `ParameterStore` 3, `ParameterStoreAdminOracleLogic` 5, `ParameterStoreStorage` 4, `ParameterStoreSpeedRules` 2, `ParameterStoreLoosenLogic` 1, `ParameterStoreTightenLogic` 1, `AvanaTimelock` 29, `TimelockSelectors` 3, `MarketRegistryActivationLogic` 9, `MarketRegistryListingLogic` 7, `MarketRegistry` 3, `MarketRegistryDebtChecks` 3, `MarketRegistryDriftView` 3, `MarketRegistryOracleChecks` 3.

Test set fixed; needs the next mutation-gate run (227): `LPOracleCL`, `LPOracleCLInitLogic`, `LPOracleCLListingLogic`, `LPOracleCLModule`, `LPOracleCLModuleCaller`, `LPOracleCLModuleLogic`, `LPOracleCLPool`, `LPOracleCLViewLogic` and `LPOracleCalls` ran at `aa340fb` against `test/{unit,fuzz}/LPOracle.*` only, so their own tests never ran against these mutants. `security/mutation-layers.json` now runs every `LPOracle*` file against all `test/{unit,fuzz}/LPOracle*` suites, and the `lp-vault-swap` entry includes `AaveAdapter.LPVaultSwap*`; these survivors are triaged after the re-run.
