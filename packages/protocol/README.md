# protocol

`@avana/protocol` holds the ABIs the indexer and the keeper decode and call with, and the ABI hash they compare with each release manifest at startup (`TEST-149`). It is an npm workspace package; the services link it with `file:` and never fetch it from a registry.

| Path | Contents |
|---|---|
| `src/abis/<contract>.ts` | One typed `as const` ABI per contract, generated from the Foundry build |
| `src/abis/index.ts` | Every ABI export, `ABI_ARTIFACTS` (the artifact each ABI comes from) and `ABI_HASH` |
| `scripts/generate-abis.mjs` | Writes `src/abis/` from the build, or checks that the committed files match it |
| `test/` | Checks that `ABI_HASH` matches the committed ABIs and that each ABI is well formed |

Import path: `@avana/protocol/abis`.

## ABIs

| Export | Artifact | Build |
|---|---|---|
| `aaveAdapterAbi`, `collateralizationAbi`, `debtOracleAbi`, `flashLiquidatorAbi`, `lensAbi`, `lpOracleAbi`, `lpVaultAbi`, `lpVaultSwapAbi`, `marketRegistryAbi`, `parameterStoreAbi`, `payoutEscrowAbi`, `proxyManagerAbi`, `riskModuleAbi`, `vaultTokenAbi`, `vaultTokenFactoryAbi` | The contract's interface (`IAaveAdapter`, `ICollateralization`, ...), which carries its functions, events and errors | `contracts/out` |
| `avanaTimelockAbi` | `AvanaTimelock`: `IAvanaTimelock` declares only what the timelock adds to OpenZeppelin's `TimelockController`, so the contract's own ABI supplies `CallScheduled`, `CallExecuted`, `Cancelled` and the role events | `contracts/out` |
| `coverageSpokeAbi` | `CoverageSpoke`: `ICoverageSpoke` does not inherit `ICoverageSpokeAdmin`, so the contract's own ABI supplies `BorrowSpokeAllowlistUpdated` and `FirstLossReserveMinimumUpdated` | `contracts/out` |
| `aaveV4SpokeAbi`, `aaveV4HubAbi` | Aave's `ISpoke` and `IHub` at the pinned Aave V4 commit, not Avana's minimal interfaces, so every Spoke and Hub event decodes | `contracts/out-aave` |

The ERC-1967 `Upgraded` and AccessControl role events of upgradeable contracts are added by the indexer (`services/indexer/src/config/abis.ts`), since the interfaces do not declare them.

## ABI hash

```
ABI_HASH = keccak256(utf8(JSON.stringify({ <artifact>: <abi>, ... })))
```

with the artifacts in ascending order of name, each ABI exactly as Foundry wrote it, and no whitespace. Example: if the build changes one event of `IMarketRegistry`, the regenerated `marketRegistry.ts` and `ABI_HASH` both change; a service built from it then refuses every manifest recorded with the old hash until the release manifest carries the new one.

## Regenerating

From the repository root, after building the contracts with both Foundry profiles:

```bash
(cd contracts && forge build && FOUNDRY_PROFILE=aave forge build)
node packages/protocol/scripts/generate-abis.mjs           # write src/abis/
node packages/protocol/scripts/generate-abis.mjs --check   # exit 1 if a committed file differs from the build
```

`--out <dir>` and `--out-aave <dir>` read the artifacts from other build folders. The script needs `viem` from the workspace install (`npm ci` at the repository root). A change to an interface under `contracts/src/` that the services use is committed together with its regenerated ABIs.

## Addresses

The package holds no addresses. Every address and start block the services use comes from the verified release manifest named in their configuration (`AVANA_MANIFEST`), read through the `ServiceManifest` view in `@avana/services-common`; no deployment is recorded yet, so there is no manifest to bundle.

## Build and test

```bash
npm ci --ignore-scripts                   # at the repository root
npm run typecheck -w packages/protocol
npm run test -w packages/protocol
```
