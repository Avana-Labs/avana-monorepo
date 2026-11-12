# Upgrade safety

## What it proves

`slither-check-upgradeability` checks every deployable `src/` contract that inherits `Initializable` or `UUPSUpgradeable`: initializer presence and protection, no constructor state, storage-layout and function-ID collisions, missing calls to parent initializers. Each upgradeable contract also has a unit test that `_disableInitializers` runs in the constructor and that `_authorizeUpgrade` requires `APPLICATION_ADMIN`. From CI onward, every UUPS contract also gets OpenZeppelin Upgrades validation and a storage-layout diff against the last release (decided 2026-11-10).

## How to run

```bash
cd contracts && script/security-fast.sh build upgradeability
```

`script/security-list-upgradeable.py` finds the targets in the build, so a new upgradeable contract is checked on the next run. Triage: `contracts/security/slither-upgradeability-triage.json`, gate at Informational.

## Scope

Every upgradeable contract in the build. On 2026-11-10 these were the MarketRegistry and the ParameterStore; the AaveAdapter, RiskModule, LPVaultSwap, LPOracle and DebtOracle had no implementation on that date.

## How often it runs

Fast tier on every push; the OpenZeppelin validation and layout diff run in CI, with the layout of the first release as the baseline.

## Latest result

2026-11-10 21:46 and 21:49: MarketRegistry 1 finding, ParameterStore 1 finding, both `initialize-target` (the contract must be initialized by `initialize(address)`), accepted: `initialize` runs atomically in the `ERC1967Proxy` constructor (`REQ-PSTORE-001`, `REQ-CONFIG-002`, `REQ-MREG-005`) and the implementation's constructor calls `_disableInitializers`; covered by `TEST-242`. 0 blocking.

## Results folder

- [`MarketRegistry.json`](results/MarketRegistry.json), [`MarketRegistry.log`](results/MarketRegistry.log), [`ParameterStore.json`](results/ParameterStore.json), [`ParameterStore.log`](results/ParameterStore.log), [`slither-upgradeability-triage.json`](results/slither-upgradeability-triage.json).
