# Foundry test inventory

Counted on 2026-11-10 from `contracts/test/` by matching function declarations (no build).

| Folder | Files | test_ | testFuzz_ | invariant_ | check_ |
|---|---|---|---|---|---|
| `unit/` | 39 | 522 | 65 | 0 | 0 |
| `fuzz/` | 7 | 1 | 49 | 0 | 0 |
| `integration/` | 1 | 4 | 0 | 0 | 0 |
| `invariant/` | 3 | 0 | 0 | 11 | 0 |
| `differential/` | 4 | 1 | 21 | 0 | 0 |
| `halmos/` | 17 | 0 | 0 | 0 | 95 |
| **All** | **71** | **528** | **135** | **11** | **95** |

Property harnesses in `invariant/echidna/` (run by Echidna, Medusa and hevm): 19 harnesses, 68 `property_` functions.

## Per contract

| Contract | Test files | test_ | testFuzz_ | invariant_ | check_ | Properties harness |
|---|---|---|---|---|---|---|
| AvanaRoles | 1 | 5 | 1 | 0 | 0 | `AvanaRolesProperties` |
| Lock | 2 | 19 | 6 | 0 | 6 | `LockProperties` |
| AvanaTimelock | 4 | 41 | 6 | 5 | 7 | `AvanaTimelockProperties` |
| LPPriceMath | 4 | 40 | 32 | 0 | 6 | `LPPriceMathProperties` |
| SettlementMath | 4 | 20 | 22 | 0 | 14 | `SettlementMathProperties` |
| ParameterStore | 7 | 62 | 6 | 0 | 8 | `ParameterStoreProperties` |
| MarketRegistry | 11 | 67 | 5 | 0 | 2 | `MarketRegistryProperties` |
| VaultToken | 4 | 27 | 6 | 0 | 7 | `VaultTokenProperties` |
| VaultTokenFactory | 3 | 20 | 4 | 0 | 4 | `VaultTokenFactoryProperties` |
| Collateralization | 6 | 54 | 4 | 0 | 5 | `CollateralizationProperties` |
| AaveV3FlashSource | 3 | 32 | 7 | 0 | 8 | `AaveV3FlashSourceProperties` |
| PositionProxy | 2 | 13 | 8 | 0 | 6 | `PositionProxyProperties` |
| ProxyManager | 3 | 15 | 5 | 3 | 3 | `ProxyManagerProperties` |
| DexPathRoute | 2 | 31 | 3 | 0 | 4 | `DexPathRouteProperties` |
| PegModuleRoute | 2 | 12 | 1 | 0 | 4 | `PegModuleRouteProperties` |
| WrapperThenDexRoute | 2 | 9 | 1 | 0 | 3 | `WrapperThenDexRouteProperties` |
| PayoutEscrow | 3 | 27 | 6 | 3 | 4 | `PayoutEscrowProperties` |
| CoverageSpoke | 3 | 26 | 6 | 0 | 4 | `CoverageSpokeProperties` |

Shared suites, not counted per contract: `fuzz/RouteMath.fuzz.t.sol`, `fuzz/SwapRoutes.fuzz.t.sol` and `differential/RouteMath.differential.t.sol` (the three swap routes), `differential/Reference.differential.t.sol` (the Python reference against OpenZeppelin `mulDiv`), `unit/AaveV4Fixture.unit.t.sol` (the local Aave V4 deployment).

## Files

```
differential/LPPriceMath.differential.t.sol
differential/Reference.differential.t.sol
differential/RouteMath.differential.t.sol
differential/SettlementMath.differential.t.sol
differential/utils/DifferentialTest.sol
fuzz/AaveV3FlashSource.fuzz.t.sol
fuzz/Collateralization.fuzz.t.sol
fuzz/LPPriceMath.fuzz.t.sol
fuzz/RouteMath.fuzz.t.sol
fuzz/SettlementMath.FlashRepayment.fuzz.t.sol
fuzz/SwapRoutes.fuzz.t.sol
fuzz/VaultTokenFactory.fuzz.t.sol
halmos/AaveV3FlashSource.halmos.t.sol
halmos/AvanaTimelock.halmos.t.sol
halmos/Collateralization.halmos.t.sol
halmos/CoverageSpoke.halmos.t.sol
halmos/DexPathRoute.halmos.t.sol
halmos/LPPriceMath.halmos.t.sol
halmos/Lock.halmos.t.sol
halmos/MarketRegistry.halmos.t.sol
halmos/ParameterStore.halmos.t.sol
halmos/PayoutEscrow.halmos.t.sol
halmos/PegModuleRoute.halmos.t.sol
halmos/PositionProxy.halmos.t.sol
halmos/ProxyManager.halmos.t.sol
halmos/SettlementMath.halmos.t.sol
halmos/VaultToken.halmos.t.sol
halmos/VaultTokenFactory.halmos.t.sol
halmos/WrapperThenDexRoute.halmos.t.sol
integration/VaultToken.AaveV4.integration.t.sol
invariant/AvanaTimelock.invariant.t.sol
invariant/PayoutEscrow.invariant.t.sol
invariant/ProxyManager.invariant.t.sol
invariant/echidna/AaveV3FlashSourceProperties.sol
invariant/echidna/AvanaRolesProperties.sol
invariant/echidna/AvanaTimelockProperties.sol
invariant/echidna/CollateralizationProperties.sol
invariant/echidna/CoverageSpokeProperties.sol
invariant/echidna/DexPathRouteProperties.sol
invariant/echidna/LPPriceMathProperties.sol
invariant/echidna/LockProperties.sol
invariant/echidna/LockSlotProperties.sol
invariant/echidna/MarketRegistryProperties.sol
invariant/echidna/ParameterStoreProperties.sol
invariant/echidna/PayoutEscrowProperties.sol
invariant/echidna/PegModuleRouteProperties.sol
invariant/echidna/PositionProxyProperties.sol
invariant/echidna/ProxyManagerProperties.sol
invariant/echidna/SettlementMathProperties.sol
invariant/echidna/VaultTokenFactoryProperties.sol
invariant/echidna/VaultTokenProperties.sol
invariant/echidna/WrapperThenDexRouteProperties.sol
invariant/handlers/EscrowHandler.sol
invariant/handlers/ProxyManagerHandler.sol
invariant/handlers/TimelockHandler.sol
unit/AaveV3FlashSource.unit.t.sol
unit/AaveV4Fixture.unit.t.sol
unit/AvanaRoles.unit.t.sol
unit/AvanaTimelock.Edges.unit.t.sol
unit/AvanaTimelock.unit.t.sol
unit/Collateralization.Exit.unit.t.sol
unit/Collateralization.Pledge.unit.t.sol
unit/Collateralization.Seizure.unit.t.sol
unit/Collateralization.Views.unit.t.sol
unit/CoverageSpoke.PerAsset.unit.t.sol
unit/CoverageSpoke.unit.t.sol
unit/DexPathRoute.unit.t.sol
unit/LPPriceMath.unit.t.sol
unit/Lock.unit.t.sol
unit/MarketRegistry.AaveSpoke.unit.t.sol
unit/MarketRegistry.Access.unit.t.sol
unit/MarketRegistry.Activation.unit.t.sol
unit/MarketRegistry.Breakers.unit.t.sol
unit/MarketRegistry.DebtReserve.unit.t.sol
unit/MarketRegistry.Freeze.unit.t.sol
unit/MarketRegistry.Hubs.unit.t.sol
unit/MarketRegistry.Listing.unit.t.sol
unit/MarketRegistry.Pause.unit.t.sol
unit/MarketRegistry.Routes.unit.t.sol
unit/ParameterStore.Access.unit.t.sol
unit/ParameterStore.Admin.unit.t.sol
unit/ParameterStore.Listing.unit.t.sol
unit/ParameterStore.Loosen.unit.t.sol
unit/ParameterStore.Tighten.unit.t.sol
unit/ParameterStore.Timelock.unit.t.sol
unit/PayoutEscrow.unit.t.sol
unit/PegModuleRoute.unit.t.sol
unit/PositionProxy.unit.t.sol
unit/ProxyManager.unit.t.sol
unit/SettlementMath.unit.t.sol
unit/VaultToken.Transfers.unit.t.sol
unit/VaultToken.unit.t.sol
unit/VaultTokenFactory.unit.t.sol
unit/WrapperThenDexRoute.unit.t.sol
```
