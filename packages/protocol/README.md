# protocol

`@avana/protocol` holds the ABIs the indexer and the keeper decode and call with, and the ABI hash they compare with each release manifest at startup; the contract addresses of every verified deployment, generated from `contracts/deployments/verified/`; and the calldata builders of the AaveAdapter user actions the web app sends. It is an npm workspace package; the services link it with `file:` and never fetch it from a registry.

| Path | Contents |
|---|---|
| `src/abis/<contract>.ts` | One typed `as const` ABI per contract, generated from the Foundry build |
| `src/abis/index.ts` | Every ABI export, `ABI_ARTIFACTS` (the artifact each ABI comes from) and `ABI_HASH` |
| `scripts/generate-abis.mjs` | Writes `src/abis/` from the build, or checks that the committed files match it |
| `src/addresses/` | `generated.ts` (written by `cli.ts` from `contracts/deployments/verified/`, never by hand), `getAddresses`, the `AvanaAddresses` type |
| `src/calldata/` | Typed calldata builders for the AaveAdapter user actions |
| `src/manifest/` | Release manifest schema, producer, verification and contract table (`npm run manifest`) |
| `test/` | Checks that `ABI_HASH` matches the committed ABIs and that each ABI is well formed; the address library and the calldata builders |

Import paths: `@avana/protocol/abis`, `@avana/protocol/addresses`, `@avana/protocol/calldata`, `@avana/protocol/manifest`.

## ABIs

| Export | Artifact | Build |
|---|---|---|
| `aaveAdapterAbi`, `riskModuleAbi`, `lpVaultAbi`, `vaultTokenAbi`, `lpOracleAbi`, `liquidationModuleAbi`, `firstLossReserveAbi` | The seven core contracts' interfaces (`IAaveAdapter`, `IRiskModule`, ...), with their functions, events and errors | `contracts/out` |
| `flashloanRepayAbi` | `IFlashloanRepay`, the repay-with-collateral periphery | `contracts/out` |
| `accessManagerAbi` | OpenZeppelin's `IAccessManager`, Avana's one AccessManager per chain | `contracts/out` |
| `flashLiquidatorAbi` | `IFlashLiquidator` of `packages/liquidator/` | `packages/liquidator/out` |
| `aaveV4SpokeAbi`, `aaveV4HubAbi` | Aave's `ISpoke` and `IHub` at the pinned Aave V4 commit, so every Spoke and Hub event decodes | `contracts/out-aave` |

A file left in `src/abis/` from a contract no longer listed is stale: `--check` fails on it and a write removes it.

The ERC-1967 `Upgraded` event of the Aave Hubs and Spokes is added by the indexer (`services/indexer/src/config/abis.ts`); Avana's core contracts are not upgradeable.

## ABI hash

```
ABI_HASH = keccak256(utf8(JSON.stringify({ <artifact>: <abi>, ... })))
```

with the artifacts in ascending order of name, each ABI exactly as Foundry wrote it, and no whitespace. Example: if the build changes one event of `IRiskModule`, the regenerated `riskModule.ts` and `ABI_HASH` both change; a service built from it then refuses every manifest recorded with the old hash until the release manifest carries the new one.

## Regenerating

From the repository root, after building the contracts with both Foundry profiles:

```bash
(cd contracts && forge build -j 2 && FOUNDRY_PROFILE=aave forge build -j 2) && (cd liquidator && forge build -j 2)
node packages/protocol/scripts/generate-abis.mjs           # write src/abis/
node packages/protocol/scripts/generate-abis.mjs --check   # exit 1 if a committed file differs from the build
```

`--out <dir>`, `--out-aave <dir>` and `--out-liquidator <dir>` read the artifacts from other build folders. The script needs `viem` from the workspace install (`npm ci` at the repository root). A change to an interface under `contracts/src/` that the services use is committed together with its regenerated ABIs.

## Addresses

`src/addresses/generated.ts` lists every verified deployment by chain ID and release tag: the AccessManager, each integration's core stack (LPVault, RiskModule, LiquidationModule, AaveAdapter, FlashloanRepay), the flash liquidators with their operators, the markets (two per pool, Full range and Custom range, with band and LTV), the debt reserves with their First-Loss Reserves, and the Aave V4 Hubs and Spokes and the Aave V3 Pool, with the release, commit, ABI hash and start block. It is written from `contracts/deployments/verified/<network>-<release>.json`, each file checked against the manifest schema (schema 2) and its name; nothing is entered by hand. No deployment is verified yet, so the library is empty.

```ts
import { getAddresses } from "@avana/protocol/addresses";
const a = getAddresses(8453);            // the newest verified release on Base, or undefined
const b = getAddresses(8453, "v1.0.0");  // one release
```

After `npm run manifest -- publish` adds a verified manifest, regenerate and commit the file with it; the `services` workflow fails while it is stale:

```bash
npm run addresses -w packages/protocol        # write src/addresses/generated.ts
npm run check-addresses -w packages/protocol  # exit 1 if it differs from contracts/deployments/verified/
```

The services keep reading their manifest at runtime (`AVANA_MANIFEST`, through `ServiceManifest` in `@avana/services-common`).

## Calldata

`@avana/protocol/calldata` encodes the AaveAdapter user actions with `aaveAdapterAbi`: `encodePledge` (the position key only: the Adapter routes it to the pool's Full range or Custom range market), `encodeAddLiquidity`, `encodeWithdraw` (part of a position, or the whole NFT with liquidity 0), `encodeBorrow`, `encodeRepay`, `encodeRepayAll` (`type(uint256).max`), `encodeCollectFees`, and `encodeRepayWithCollateral` (`allowWithdraw` to the FlashloanRepay with its `RepayParams`; `encodeRepayParams` gives that data alone). `aaveAdapterCall(to, data)` gives `{ to, data, value: 0n }` and `decodeAaveAdapterCall` decodes any Adapter calldata.

```ts
import { aaveAdapterCall, encodeBorrow } from "@avana/protocol/calldata";
const call = aaveAdapterCall(a.integrations[0].aaveAdapter, encodeBorrow({ marketId, reserveId, amount, recipient }));
```

## Build and test

```bash
npm ci --ignore-scripts                   # at the repository root
npm run typecheck -w packages/protocol
npm run test -w packages/protocol
```
