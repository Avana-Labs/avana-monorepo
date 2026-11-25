# contracts/test

Foundry tests for the Avana core. Run from `contracts/` with `forge test -j 2`.

## Layout

| Folder | Contents | Profile |
|---|---|---|
| `unit/` | One file per contract (`<Contract>[.<Area>].unit.t.sol`) | `default`, `ci` |
| `fuzz/` | Property fuzzing per contract (`<Contract>[.<Area>].fuzz.t.sol`) | `default`, `ci` |
| `integration/` | Real Aave V4, Uniswap v3/v4 and deploy-script runs; golden vectors | `default`, `ci` |
| `invariant/` | Stateful invariants: balances, LPVault credit, the Uniswap v2 LP record, LiquidationModule, FirstLossReserve | `invariant` |
| `invariant/handlers/` | Invariant handlers and reach counters | — |
| `invariant/echidna/`, `invariant/medusa/` | Echidna and Medusa property harnesses ([README](invariant/echidna/README.md)) | slow tier |
| `halmos/` | Halmos `check_` proofs (`FloorCreditMath`) | slow tier |
| `symbolic/` | hevm notes ([README](symbolic/README.md)) | slow tier |
| `fork/` | Ethereum and Base forks at pinned blocks | `fork` |
| `differential/` | FFI against the exact Python reference in `differential/reference/` | `differential` |
| `utils/` | Base tests, fixtures, harnesses, mocks | — |

## Fixtures

| Fixture | Provides |
|---|---|
| `utils/fixtures/AaveV4Fixture.sol` | Local Aave V4 Hub, Spokes and oracle at the pinned release |
| `utils/fixtures/ClPoolFixture.sol` | Local Uniswap v3 pools and position manager |
| `utils/fixtures/UniswapV4WorldFixture.sol` | Local Uniswap v4 PoolManager and position manager |
| `utils/fixtures/CoverageHubFixture.sol`, `FirstLossReserveFixture.sol` | Hub with First-Loss layers |
| `utils/fixtures/ForkConstants.sol` | Pinned fork blocks and addresses |
| `utils/AaveAdapterTestBase.sol`, `LiquidationModuleTestBase.sol`, `FlashloanRepayTestBase.sol` | Wired core per flow |

Harnesses in `utils/harness/` expose internals for tests and Certora. Hostile tokens and reentrancy helpers are in `utils/mocks/hostile/`.

## Conventions

- Names: `test_<behavior>`, `testFuzz_<behavior>`, `invariant_<property>`, `check_<property>` (Halmos).
- One behavior per test; revert tests assert the exact custom error.
- Fuzz inputs are bounded with `bound`, not `vm.assume`, unless the rejected share is tiny.
- A slow test is split into smaller tests, never left running long (see [certora/README.md](../certora/README.md#proof-rule)).
- Invariant suites built on `HandlerReach` assert a floor on each selector's success rate and each target's reach.

## Commands

```bash
forge test -j 2                                         # default profile
forge test --match-path 'test/unit/**'                  # one folder
forge test --match-contract LiquidationModule           # one contract
FOUNDRY_PROFILE=ci forge test                           # CI depth
FOUNDRY_PROFILE=invariant forge test                    # deep invariants
FOUNDRY_PROFILE=fork forge test                         # RPC_MAINNET, RPC_BASE
FOUNDRY_PROFILE=differential forge test                 # Python reference
script/check-coverage.sh                                # per-file branch coverage, 80% floor
```
