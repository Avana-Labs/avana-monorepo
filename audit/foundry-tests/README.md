# Foundry tests: unit, fuzz, invariant, differential

## What it proves

Every `TEST-NNN` row of [5.1 Test Requirements](../../spec/05-verification/01-test-requirements.md) is a Foundry test that runs the contract on the local Aave V4 deployment of the pinned release (`AaveV4Fixture`; Aave V4 is never mocked). Unit tests check each function's happy path, rejections, access control and boundaries; fuzz tests check every formula, rounding direction and bound; invariant suites check global invariants of [4.1](../../spec/04-security/01-global-invariants.md) after every call of a fuzzed sequence; differential tests compare the math libraries with an exact Python reference (stdlib integers and `fractions.Fraction`). Each test carries a `// TEST-NNN verifies: <IDs>` tag that `trace.py` links to the rules it checks.

## How to run

From `contracts/`, Foundry 1.9.0:

| Purpose | Command |
|---|---|
| Local suite (unit, fuzz at 1,000 runs, integration, invariant at 64 × 64) | `forge test` |
| One contract or one row | `forge test --match-path 'test/unit/Lock.unit.t.sol'`, `forge test --match-test 'TEST_057_'` |
| CI depth (fuzz 10,000 runs, invariant 10,000 × 100, `TEST-007`) | `FOUNDRY_PROFILE=ci forge test` |
| Deep invariant campaign (2,000 × 400) | `FOUNDRY_PROFILE=invariant forge test` |
| Differential against the Python reference (FFI, 2,000 runs) | `FOUNDRY_PROFILE=differential forge test` |

Configuration: `contracts/foundry.toml` profiles `default`, `ci`, `invariant`, `differential`; layout, naming and the full `TEST`/`INV` maps in [`contracts/test/README.md`](../../contracts/test/README.md).

## Scope

Contracts with an implementation and a suite on 2026-11-10: AvanaRoles, Lock, AvanaTimelock, LPPriceMath, SettlementMath, ParameterStore, MarketRegistry, VaultToken, VaultTokenFactory, Collateralization, AaveV3FlashSource, PositionProxy, ProxyManager, the three swap routes (DexPathRoute, PegModuleRoute, WrapperThenDexRoute), PayoutEscrow and CoverageSpoke. Per-contract counts are in [results/test-inventory-2026-11-10.md](results/test-inventory-2026-11-10.md): 71 test files, 528 `test_`, 135 `testFuzz_`, 11 `invariant_` functions and 95 Halmos `check_` functions. Hostile-component tests (`TEST-130`…`TEST-133`, `TEST-210`) and the multi-actor sequence suite (`TEST-215`) need the AaveAdapter, RiskModule and LPVaultSwap and land with them (layer 2.5). Fork tests are in [fork-tests](../fork-tests/).

## How often it runs

| Tier | What runs |
|---|---|
| Contract gate | `forge build --force -D warnings` and `forge test` green; unit and fuzz at 1,000 runs, the contract's math at 10,000 runs; the differential profile for the math libraries |
| CI | `tests (ci profile)`, `deep invariant campaign` and `FFI differential` jobs of `.github/workflows/contracts.yml` |
| Layer gate | Integration tests across the layer's contracts on the local Aave V4 fixture |

## Latest result

Recorded at each contract's gate (progress log of the build):

| Date | Contract | Result |
|---|---|---|
| 2026-11-10 | Phase 0 (fixtures, differential harness) | `forge test` 6/6; differential profile 1/1 (256 runs) |
| 2026-11-10 | AvanaRoles | 6 unit and fuzz tests |
| 2026-11-10 | Lock | 24 unit tests; the swapped-check mutation is caught |
| 2026-11-10 | AvanaTimelock | 47 unit and fuzz tests, `TEST-212` invariant suite |
| 2026-11-10 | LPPriceMath, SettlementMath, VaultToken | Tests, differential and fuzz at 10,000 runs pass |
| 2026-11-10 | ParameterStore | 258 tests pass across the repository |

The contracts merged after the ParameterStore (MarketRegistry, VaultTokenFactory, Collateralization, the flash source, the proxies, the routes, the PayoutEscrow and the CoverageSpoke) passed the same contract gate before their independent review ([reviews](../reviews/)). The full suite runs again at the layer 2.1 gate.

## Results folder

- [`test-inventory-2026-11-10.md`](results/test-inventory-2026-11-10.md): test files and test functions per folder and per contract.
