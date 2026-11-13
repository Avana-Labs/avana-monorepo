# Coverage

## What it proves

`forge coverage` measures line and branch coverage of `contracts/src/` by the unit, fuzz, integration and hostile suites, with the optimizer and via-IR off for exact source maps. CI enforces a branch-coverage minimum per file of at least 80 % (`floor` in `contracts/security/coverage-thresholds.json`, decided 2026-11-12; a file's minimum may be higher, never lower), so a file whose branches are not tested to 80 % fails the build. A branch that cannot be reached leaves a file's count only through the file's `unreachable` entries, each with the function, the branch, the reason and the tests of the reachable side.

## How to run

```bash
cd contracts && FOUNDRY_PROFILE=coverage forge coverage --report lcov
```

Configuration: `contracts/foundry.toml` `[profile.coverage]` (64 fuzz runs; no fork, Halmos or invariant suites).

## Scope

Every implementation under `contracts/src/`.

## How often it runs

CI, per contract.

## Latest result

No run is recorded in this folder; the per-file branch minimums are in `contracts/security/coverage-thresholds.json`. On 2026-11-12 every minimum below 80 was raised to the floor; the 21 files below it at their last measured value (whole percent, rounded down) fail the gate until their tests reach 80 %:

| File | Last measured branch coverage |
|---|---:|
| `contracts/src/oracle/lp-oracle/LPOracleStorage.sol` | 0 % |
| `contracts/src/lens/lens/Lens.sol` | 25 % |
| `contracts/src/custody/collateralization/CollateralizationViews.sol` | 30 % |
| `contracts/src/oracle/debt-oracle/DebtOracleReads.sol` | 31 % |
| `contracts/src/lens/lens/LensPositions.sol` | 38 % |
| `contracts/src/lens/lens/LensPrice.sol` | 40 % |
| `contracts/src/oracle/debt-oracle/DebtOracleRecovery.sol` | 47 % |
| `contracts/src/lens/lens/LensPreview.sol` | 48 % |
| `contracts/src/lens/lens/LensBase.sol` | 54 % |
| `contracts/src/liquidation/lp-vault-swap/LPVaultSwapPendingLogic.sol` | 58 % |
| `contracts/src/lens/lens/LensLiquidation.sol` | 58 % |
| `contracts/src/lens/lens/LensMarket.sol` | 59 % |
| `contracts/src/lens/lens/LensAccount.sol` | 60 % |
| `contracts/src/oracle/lp-oracle/LPOracleRecovery.sol` | 61 % |
| `contracts/src/liquidation/lp-vault-swap/LPVaultSwapLiquidationLogic.sol` | 62 % |
| `contracts/src/liquidation/lp-vault-swap/LPVaultSwapDeleverageLogic.sol` | 63 % |
| `contracts/src/lens/lens/LensMarkets.sol` | 71 % |
| `contracts/src/custody/collateralization/CollateralizationLedger.sol` | 73 % |
| `contracts/src/oracle/lp-oracle/LPOracleListing.sol` | 74 % |
| `contracts/src/custody/collateralization/CollateralizationBase.sol` | 75 % |
| `contracts/src/oracle/debt-oracle/DebtOracle.sol` | 79 % |

