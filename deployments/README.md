# deployments

Release manifests of Avana's deployments, one per chain and release, and the public contract table of each final deployment.

A release manifest names every contract of one deployment: each Avana contract with its runtime code hash and deployment block, each ERC-1967 proxy with its implementation and the logic contracts that implementation delegates to, the PositionProxy creation-code hash, the governance role table, the fee recipient, and every third-party contract the deployment relies on (Aave V4 Hubs, Spokes and oracles, the Aave V3 Pool, Uniswap v3, Aerodrome Slipstream, tokens, price feeds). The keeper and the indexer start only from a manifest (`AVANA_MANIFEST`) and refuse one whose ABI hash differs from the ABIs they were built with.

## Layout

| Path | Contents |
|---|---|
| `release-manifest.schema.json` | JSON Schema (draft 2020-12) of a manifest, written from `packages/protocol/src/manifest/schema.ts` by `npm run manifest -- schema`. |
| `<network>/<release>.json` | The manifest of a deployment as produced, before review (`ethereum`, `base`, `sepolia`, `base-sepolia`). |
| `verified/<network>-<release>.json` | A manifest that passed every deployment check and was approved by the governance Safe's signers; the only manifests the services and the web app load in production. |
| `<network>/README.md` | The public contract table of the network's final deployment: every contract with its address, proxy and implementation, runtime code hash and explorer link. |

Local rehearsals (anvil) write their outputs and manifests to `contracts/deployments-local/<network>/`, which git ignores. They are learning deployments and are never published: `publish` refuses a manifest of anvil or of a release tagged `-local`, `-test` or `-learn`.

## Stages

1. **Local (anvil).** `contracts/script/e2e/e2e-local.sh` deploys the whole world on a fresh anvil node: Avana's own Aave V4 (three Hubs, CDP Spokes per AMM protocol and risk tier, Lend Spokes), Uniswap v3, Aerodrome Slipstream, test tokens and movable feeds, dozens of pools, then Avana, its first two timelock operations, the manifest and its verification, the keeper and the indexer, and the scenarios. Each step is recorded as pass, fail or not-run in `contracts/deployments-local/anvil/e2e-status.json`.
2. **Sepolia.** Avana redeploys its own Aave V4, Uniswap v3 and Aerodrome Slipstream with `AVANA_NETWORK=sepolia`; the deployer signs with a keystore account or a Ledger, and the governance Safe signs the timelock operations from the JSON files the scripts write.
3. **Ethereum and Base.** Aave V4 is the Aave DAO's: steps 01, 02 and the execution of 06 do not run; `03_DeployAvana` reads the DAO's addresses from `contracts/script/deploy/config/<network>.json`, and `06_AaveDeploymentPayload` writes the AIP draft only.

Every stage uses the same scripts and differs only in `contracts/script/deploy/config/<network>.json` and the environment (`contracts/.env.example`): RPC URLs and keys are never written in a file.

## Producing, checking and publishing a manifest

From `packages/protocol`:

```bash
# After the deploy scripts have run on <network>:
npm run manifest -- produce --network sepolia --rpc-env RPC_SEPOLIA --release v1.0.0
# Deployment checks against the chain: code hashes, ERC-1967 implementation and admin slots, runtime code against the
# release build with immutables masked (TEST-134), role snapshot from RoleGranted/RoleRevoked (TEST-214), timelock
# settings and immutable wiring (REQ-ACCESS-027). Exit 1 on any failed check; pending checks are listed.
npm run manifest -- verify --manifest ../../deployments/sepolia/v1.0.0.json --rpc-env RPC_SEPOLIA
# Final deployment only: verify, copy to verified/ and write the public table <network>/README.md.
npm run manifest -- publish --manifest ../../deployments/sepolia/v1.0.0.json --rpc-env RPC_SEPOLIA
```

A check is pending, not passed, while the operation that completes it has not executed (for example the guardian roles before the `guardian-roles` operation) or while a contract is not deployed (the concentrated-liquidity LPOracle implementation). `publish` refuses a manifest with any failed or pending check. A newly verified manifest is committed together with the regenerated address library of `@avana/protocol` (`npm run addresses -w packages/protocol`, which writes `packages/protocol/src/addresses/generated.ts` from `verified/`); the `services` workflow fails while that file is stale. The live-configuration checks of `TEST-135` (reserve flags, caps, credit lines, First-Loss Reserve funding) extend `verify` as markets are listed.

## Test-network stand-ins

On anvil and Sepolia the world Avana runs against is built from pinned sources where they are vendored and from stand-ins where they are not. Every stand-in is marked `standIn: true` in the manifest and "(test-network stand-in)" in the contract table. Pinned commits of every vendored third-party source are in [`contracts/external/README.md`](../contracts/external/README.md).

| Contract | Source |
|---|---|
| Aave V4 (AccessManager, configurators, TreasurySpoke, Hubs, Spokes, AaveOracles, interest-rate strategies, `LiquidationLogic`) | Pinned release a3ef63e, built by the `aave` profile; real |
| Uniswap v3 factory and pools, NonfungiblePositionManager, SwapRouter | Core 5ea68a7 and periphery 24ccf01 with OpenZeppelin 3.4.2-solc-0.7, built by the `univ3` profile; real |
| Aerodrome Slipstream CLFactory, CLPool, NonfungiblePositionManager, SwapRouter | Tag v1.0.0 (37eead2) for position-manager generations 0–2 and main f8717fa for generation 3, built by the `slipstream-v1` and `slipstream-main` profiles; real code, four separate instances standing for the four Base generations of 2.21 |
| Aerodrome AERO, VotingEscrow, Voter, FactoryRegistry, Minter, RewardsDistributor, v2 PoolFactory, gauge and rewards factories; Slipstream CLGauge and CLGaugeFactory per generation | Aerodrome contracts v1.0 (1e08fb9, `aerodrome` profile) and the Slipstream gauges of each generation; every Slipstream pool gets its gauge from `Voter.createGauge`, as on Base; real |
| Aave V3 market: PoolAddressesProvider and registry, Pool and PoolConfigurator proxies, ACLManager, AaveOracle, `DefaultReserveInterestRateStrategyV2`, aToken and variable-debt-token implementations, Collector, RewardsController | Aave V3 origin v3.7.0 (cff15de), `aave-v3` profile, deployed by `02_DeployWorld` (`script/deploy/lib/WorldAaveV3.sol`) through Aave's own setup, pool, periphery, getters and tokens batches, with BorrowLogic, FlashLoanLogic, LiquidationLogic, PoolLogic and SupplyLogic deployed first and linked into the pool batch; every token listed with its primary feed as oracle source, flash loans enabled (premium 5 bps) and $50,000,000 supplied per token, then every market role handed to the network's Aave DAO account, which grants `FLASH_BORROWER` in step 06; real |
| Multicall3 at `0xcA11bde05977b3631167028862bE2a173976CA11` | mds1/multicall v3.1.0 (a1fa064) pinned as source; on anvil the runtime of [`contracts/external/multicall3/`](../contracts/external/multicall3/README.md) is placed with `anvil_setCode` and its code hash checked; the public networks have the deployed contract. The runtime is Ethereum's deployed code at that address, code hash `0xd5c1…0891` |
| Tokens (USDC, USDT, DAI, GHO, WETH, WBTC, …) | `TestToken` stand-ins with the real decimals; the deployer mints |
| Chainlink feeds | Chainlink's `AccessControlledOCR2Aggregator` (libocr 199a6f1) behind `EACAggregatorProxy` (chainlink v2.10.0), four per token (primary, alternate, standby, second source), four local oracles (f = 1) whose keys come from `AVANA_OCR_MNEMONIC` (the public anvil test mnemonic on anvil); prices move only by signed OCR2 reports (`contracts/script/e2e/scenarios/ocr2.ts`); real |
| LINK (OCR2 payment token) | `TestToken` stand-in: the aggregators only book payments, nothing is withdrawn on a test network |
| Aave governance v3 Executor | `AaveGovernanceExecutorStandIn` (`contracts/script/deploy/local/`): the same `executeTransaction(target, value, signature, data, withDelegatecall)`, placed with `anvil_setCode` at the network's Aave DAO account (the admin Aave V4's deployment set), owned by a PayloadsController stand-in account; every Aave-side AIP runs through it by `delegatecall`, as on Ethereum |
| GHO fixed price source | `FixedPriceSource` (`contracts/script/deploy/local/`): an 8-decimal source answering $1.00, the stand-in for Aave's fixed GHO source of a fixed-price debt reserve |

### Licence of the vendored Aerodrome Slipstream

Slipstream's `LICENSE.md` is the Business Source License 1.1 (Licensor Perpetual Cyclist Services LLC, Licensed Work "Velodrome Smart Contracts"), with a change date of the earlier of 2026-01-01 or a date the licensor specifies, and GNU GPL v2.0 or later as the change licence. Avana uses the vendored source only to build local and test-network deployments (anvil, Sepolia), never for production contracts; on Base, Avana's LPVault reads the Aerodrome deployment itself.

## Manifest fields the services read

`services/common/src/manifest.ts` names the subset the keeper and the indexer use. The services view has one Hub (`aave.hub`, the Stable LP Hub) and one Lend Spoke (`aave.lendSpoke`); the full manifest also lists every Hub and Lend Spoke in `aave.hubs` and `aave.lendSpokes`.
