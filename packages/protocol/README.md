# protocol

`@avana/protocol` holds the ABIs the indexer and the keeper decode and call with, and the ABI hash they compare with each release manifest at startup (`TEST-149`); the contract addresses of every verified deployment, generated from `deployments/verified/`; and the calldata builders of the AaveAdapter user actions the web app sends. It is an npm workspace package; the services link it with `file:` and never fetch it from a registry.

| Path | Contents |
|---|---|
| `src/abis/<contract>.ts` | One typed `as const` ABI per contract, generated from the Foundry build |
| `src/abis/index.ts` | Every ABI export, `ABI_ARTIFACTS` (the artifact each ABI comes from) and `ABI_HASH` |
| `scripts/generate-abis.mjs` | Writes `src/abis/` from the build, or checks that the committed files match it |
| `src/addresses/` | `generated.ts` (written by `cli.ts` from `deployments/verified/`, never by hand), `getAddresses`, the `AvanaAddresses` type |
| `src/calldata/` | Typed calldata builders for the AaveAdapter user actions |
| `src/manifest/` | Release manifest schema, producer, verification and contract table (`npm run manifest`) |
| `test/` | Checks that `ABI_HASH` matches the committed ABIs and that each ABI is well formed; the address library and the calldata builders |

Import paths: `@avana/protocol/abis`, `@avana/protocol/addresses`, `@avana/protocol/calldata`, `@avana/protocol/manifest`.

## ABIs

| Export | Artifact | Build |
|---|---|---|
| `aaveAdapterAbi`, `collateralizationAbi`, `debtOracleAbi`, `flashLiquidatorAbi`, `lensAbi`, `lpOracleAbi`, `lpVaultAbi`, `lpVaultSwapAbi`, `marketRegistryAbi`, `parameterStoreAbi`, `payoutEscrowAbi`, `proxyManagerAbi`, `riskModuleAbi`, `vaultTokenAbi`, `vaultTokenFactoryAbi` | The contract's interface (`IAaveAdapter`, `ICollateralization`, ...), which carries its functions, events and errors | `contracts/out` |
| `avanaTimelockAbi` | `AvanaTimelock`: `IAvanaTimelock` declares only what the timelock adds to OpenZeppelin's `TimelockController`, so the contract's own ABI supplies `CallScheduled`, `CallExecuted`, `Cancelled` and the role events | `contracts/out` |
| `firstLossReserveAbi` | `AvanaFirstLossReserve`: `IAvanaFirstLossReserve` does not inherit `IAvanaFirstLossReserveAdmin`, so the contract's own ABI supplies `BorrowSpokeAllowlistUpdated` and `FirstLossReserveMinimumUpdated` | `contracts/out` |
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

`src/addresses/generated.ts` lists every verified deployment by chain ID and release tag: the Avana contracts (AaveAdapter, LPVaultSwap, MarketRegistry, ParameterStore, RiskModule, timelock, ProxyManager, Collateralization, VaultTokenFactory, PayoutEscrow, Lock, Lens, flash source and liquidator), the LPVaults, markets (vault token, LPOracle, pool, Spoke and reserve), debt reserves, Aave V4 Hubs and Spokes and the Aave V3 Pool, with the release, commit, ABI hash and start block. It is written from `deployments/verified/<network>-<release>.json`, each file checked against the manifest schema and its name; nothing is entered by hand. No deployment is verified yet, so the library is empty.

```ts
import { getAddresses } from "@avana/protocol/addresses";
const a = getAddresses(8453);            // the newest verified release on Base, or undefined
const b = getAddresses(8453, "v1.0.0");  // one release
```

After `npm run manifest -- publish` adds a verified manifest, regenerate and commit the file with it; the `services` workflow fails while it is stale:

```bash
npm run addresses -w packages/protocol        # write src/addresses/generated.ts
npm run check-addresses -w packages/protocol  # exit 1 if it differs from deployments/verified/
```

The services keep reading their manifest at runtime (`AVANA_MANIFEST`, through `ServiceManifest` in `@avana/services-common`).

## Calldata

`@avana/protocol/calldata` encodes the AaveAdapter user actions with `aaveAdapterAbi`: `encodeBorrow`, `encodeRepay`, `encodeRepayAll` (`repay` with `repayAll` true), `encodeRepayWithCollateral`, `encodePledge`, `encodeRecredit`, `encodeWithdraw` (the whole position), `encodeRemoveLiquidity` (part of it, as pool tokens), `encodeRepayAllAndWithdraw` and `encodeCollectFees`. Arguments are named; amounts, IDs, deadlines and health factors are `bigint`, integration IDs `number`. `aaveAdapterCall(to, data)` gives `{ to, data, value: 0n }` and `decodeAaveAdapterCall` decodes any Adapter calldata.

```ts
import { aaveAdapterCall, encodeBorrow } from "@avana/protocol/calldata";
const call = aaveAdapterCall(a.contracts.aaveAdapter, encodeBorrow({ marketId, debtReserveId, amount, receiver, deadline, minHealthFactor, expectedNonce }));
```

## Build and test

```bash
npm ci --ignore-scripts                   # at the repository root
npm run typecheck -w packages/protocol
npm run test -w packages/protocol
```
