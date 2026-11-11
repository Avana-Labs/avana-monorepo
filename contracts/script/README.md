# script

Foundry deployment, listing and verification scripts for Avana. Every script is a `forge script` run from `contracts/`, reads its inputs from a release manifest under [`deployments/`](../../deployments/) and environment variables, and writes what it deployed to `contracts/deployments-local/`. Scripts never write into `deployments/proposed/` or `deployments/verified/`: a manifest enters `proposed/` by review and enters `verified/` only after the bytecode and live-configuration checks below pass (`Q-043`, `TEST-134`, `TEST-135`).

The order follows the contract inventory and constructor immutables of [1.2 Contract Relationships](../../spec/01-architecture/02-contract-relationships.md), the roles of [1.4 Permissions and Roles](../../spec/01-architecture/04-permissions-and-roles.md) and [2.15 Governance and Timelock](../../spec/02-contracts/15-governance-and-timelock.md), and the listing steps `MKT-018`…`MKT-026` of [3.8 Market Lifecycle](../../spec/03-operations/08-market-lifecycle.md).

## Scripts

| File | Runs on | Does |
|---|---|---|
| `00_Factories.s.sol` | Anvil only | `anvil_setCode` of the Safe Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`, CREATE2) and the CreateX factory (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`, CREATE3). Both already exist on mainnet, Sepolia and every mainnet fork. |
| `01_LiquidationLogic.s.sol` | Anvil, Sepolia, mainnet fork | CREATE2-deploys Aave V4's `LiquidationLogic` from `out-aave/` with salt 0 through the Safe Singleton Factory and writes `FOUNDRY_LIBRARIES=dependencies/aave-v4-a3ef63e/src/spoke/libraries/LiquidationLogic.sol:LiquidationLogic:<address>` to `deployments-local/libraries.env`. Skips the deployment when code already exists at the address. |
| `02_DeployAaveV4.s.sol` | Anvil, Sepolia, mainnet fork | Avana's own Aave V4 for test environments (`Q-074`, `TEST-002`): Aave-side `AccessManagerEnumerable` → `HubConfigurator`, `SpokeConfigurator` → `TreasurySpoke` (vault-token fee receiver) → the Avana Stable LP Hub and its interest-rate strategy → the standard CDP Spoke and Lend Spoke, each with its `AaveOracle`; then the GHO asset with Aave's fixed GHO price source, the Lend Spoke credit line, the CDP Spoke's three required vault-token reserve settings (`receiveSharesEnabled = false`, `liquidationFee = 0`, no reinvestment controller) and the deployment-AIP values of [`governance/README.md`](../../governance/README.md). Uses the batch contracts from `out-aave/`. The GHO Coverage Spoke is Avana's contract, deployed by `03_DeployAvana` once this script has listed GHO (step 12 below). Never runs against mainnet, where the Aave DAO deploys and owns Aave V4. |
| `03_DeployAvana.s.sol` | every chain | The AvanaTimelock and every Avana contract, in the order below. |
| `04_ConfigureAccess.s.sol` | every chain | Asserts the timelock's constructor roles and settings and the role state left by each `initialize` (`REQ-ACCESS-027`), then outputs the first timelock operation for the governance multisig to schedule: a role-change `scheduleBatch` at the normal delay that grants `APPLICATION_PAUSE_GUARDIAN` and `APPLICATION_FREEZE_GUARDIAN` on the MarketRegistry to the Emergency Guardian and the Aave Protocol Guardian. Role identifiers come from `src/governance/roles/AvanaRoles.sol`, holders from the manifest. Ends by asserting that the deployer holds no role on the timelock or any Avana contract. |
| `05_ProposeListing.s.sol` | every chain | Prepares a market listing (`MKT-018`, `MKT-019`): deploys and initialises the market's LPOracle, raises the pool's observation cardinality, and outputs the listing batch as one normal-delay `scheduleBatch` for the governance multisig. On Anvil and the mainnet fork it also schedules the batch as the manifest's governance multisig, executes it after `vm.warp` past the normal delay, runs the Aave listing payload, and schedules and executes `activateMarket` after the short delay. |
| `06_SeedPrice.s.sol` | every chain | Calls `poke()` on a market's LPOracle after registration and confirms `getPriceState()` is Live (`MKT-022`). |
| `07_VerifyDeployment.s.sol` | every chain | Read-only bytecode and live-configuration checks against a manifest; the same checks run as `test/fork/deployment/` tests. |
| `utils/Manifest.sol` | — | Reads and writes manifest JSON with `vm.parseJson*` and `vm.serialize*`. |
| `utils/Create3Addresses.sol` | — | Salt derivation and CREATE3 address prediction for the timelock, the fixed proxies and the immutable contracts. |
| `check-file-size.sh` | CI and local | Fails when an implementation file in `src/` exceeds 500 lines of code or an interface file exceeds 300 lines (`Q-240`); see [File layout and size limits](../README.md#file-layout-and-size-limits). |
| `install-security-tools.sh` | local and CI | Installs the pinned security tools: Echidna, Medusa, Aderyn and hevm from their GitHub releases into `tools/bin/` (each checked against its sha256), Slither, Semgrep and the other Python tools into `.venv` and Mythril into `.venv-mythril` with uv and an upload-date cutoff, solhint and `@openzeppelin/upgrades-core` with `npm ci --ignore-scripts`, the Semgrep smart-contract rules and 4naly3er as git checkouts of pinned commits (`--rules`, `--4naly3er`), Necessist with `cargo install --locked` (`--necessist`), and a link `tools/bin/gambit` to the Gambit binary of the pinned certora-cli wheel (`--gambit`, after `--python`). |
| `security-fast.sh` | local and CI (every push and pull request) | Fast security tier: formatting, file sizes, `forge lint`, a warning-free build, solhint, Slither, `slither-check-upgradeability`, Aderyn, Semgrep, 4naly3er and the storage-layout check; see [Security tooling](../README.md#security-tooling). |
| `security-slow.sh` | local and CI (manual dispatch, `suite: slow`; `mutate`, `gambit` and `necessist` at layer gates) | Slow security tier: Echidna, Medusa, Halmos, hevm and Mythril; layer-gate steps `mutate` (slither-mutate), `gambit` and `necessist`. |
| `security-gambit.sh` | called by `security-slow.sh gambit`; local and CI layer gate | Gambit expression mutants of each layer's implementation files (fixed seed, operators and per-file cap from the `gambit` object of `security/mutation-layers.json`), each run against the file's Foundry tests with a per-mutant timeout (`GAMBIT_TIMEOUT`, 300 seconds) in an isolated copy under `out-security/gambit/root`; survivors in `out-security/gambit/<layer>/survivors.txt`; fails on any survived or timed-out mutant not accepted in `security/gambit-triage.json`. |
| `check-coverage.sh`, `coverage-gate.py` | local and CI (every push and pull request) | `forge coverage --report lcov` in the `coverage` profile and the per-file branch-coverage minimums of `security/coverage-thresholds.json`. |
| `storage-layout.js` | called by `security-fast.sh layout` | Storage-layout snapshots in `security/storage-layout/` of every upgradeable `src/` contract and every contract sharing its ERC-7201 namespace; fails on any change to an existing slot. |
| `4naly3er-run.js` | called by `security-fast.sh 4naly3er` | Runs 4naly3er without the issues excluded in `security/4naly3er-triage.json`. |
| `mutation-targets.py` | called by `security-slow.sh mutate necessist` and `security-gambit.sh` | Implementation files and test files of each layer in `security/mutation-layers.json`, and the Gambit settings of each file (`gambit`). |
| `security-mythril.sh` | called by `security-slow.sh` | Mythril on the runtime code of every `src/` contract and library, settings from `security/mythril.conf`. |
| `security-gate.py` | called by the security runners | Severity gate and triage for Slither, `slither-check-upgradeability`, Aderyn, Mythril, Semgrep and 4naly3er reports, and for Gambit survivors. |
| `security-targets.py`, `security-list-upgradeable.py` | called by the security runners | Find harnesses, assertion entry points, runtime code and upgradeable contracts in the build, so no runner keeps a list of files. |

## Deployment order

Avana's contracts reference one another through constructor immutables (`REQ-ARCH-048`, `REQ-ARCH-049`): the Lock fixes its two members `AAVE_ADAPTER` and `LP_VAULT_SWAP`; Collateralization fixes `ADAPTER`, `LP_VAULT_SWAP`, `RISK_MODULE`, `LOCK` and `VAULT_TOKEN_FACTORY`; each LPVault fixes `INTEGRATION_ID`, `COLLATERALIZATION`, `MARKET_REGISTRY`, `LOCK` and `TIMELOCK` plus its AMM protocol's position manager and factory; the VaultTokenFactory fixes `ADAPTER`, `LP_VAULT_SWAP`, `COLLATERALIZATION`, `LOCK` and `TIMELOCK` and passes the first three to every vault token; the ProxyManager fixes `ADAPTER`, `MARKET_REGISTRY` and the PositionProxy creation-code hash; each UUPS implementation fixes the proxy addresses of the contracts it calls, and the timelock's launch short-delay list names its target contracts. These cycles are broken by deploying the timelock, every fixed proxy and every immutable contract at a CREATE3 address, which depends only on the deploying factory and the salt, never on init code. `03_DeployAvana` predicts all addresses first, deploys in dependency order, and asserts each deployed address equals its prediction.

Salts are `bytes32(abi.encodePacked(deployer, bytes1(0x00), bytes11(keccak256("avana.<release>.<Contract>"))))`: the deployer prefix makes CreateX reject the salt from any other sender, and the zero byte disables cross-chain redeploy protection so the same release has the same addresses on Anvil, Sepolia, the mainnet fork and mainnet.

| Step | Contract | Form | Address | Notes |
|---|---|---|---|---|
| 1 | AvanaTimelock | Immutable extension of OpenZeppelin 5.1.0 `TimelockController`, deployed directly (`REQ-ACCESS-013`) | CREATE3 | Constructor `admin = address(0)`; `PROPOSER_ROLE` and `EXECUTOR_ROLE` for the governance multisig (4-of-7); `CANCELLER_ROLE` for the governance multisig, Emergency Guardian (3-of-5), Aave Protocol Guardian and Aave governance executor; `DAO_CANCELLER_ROLE` for the Aave governance executor; `normalDelay = 432,000` (5 days), `publicExecution = true`, the launch short-delay list with predicted target addresses (`REQ-ACCESS-027`, `REQ-ACCESS-141`). `SHORT_DELAY` (12 hours), `MAX_DELAY` (5 days) and `GRACE_PERIOD` (14 days) are constants |
| 2 | Implementations of AaveAdapter, RiskModule, MarketRegistry, ParameterStore, LPVaultSwap, and on a chain with a debt asset other than GHO each DebtOracle | Each constructor calls `_disableInitializers()`; ERC-7201 storage; no linked libraries (`REQ-ARCH-050`, `REQ-ARCH-053`) | CREATE (address recorded) | Implementation immutables are predicted addresses. Source-verified before step 3 |
| 3 | ERC-1967 proxies of AaveAdapter, RiskModule, MarketRegistry, ParameterStore, LPVaultSwap | UUPS; `_authorizeUpgrade` requires `APPLICATION_ADMIN`; `initialize(timelock, …)` in the deploying transaction (`REQ-ACCESS-150`) | CREATE3 | Each `initialize` grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to the timelock only. `ParameterStore.initialize(timelock, params, initialDepositorUsdCap, initialPoolShareMaxBps)` writes every global value within its hard bounds, including `feeRecipient`; `LPVaultSwap.initialize(timelock, initialKeepers)` with at least `keeperFloor` keepers; `MarketRegistry.initialize(timelock)` sets both guardian roles' admin to `APPLICATION_ADMIN`. The Adapter and LPVaultSwap proxy addresses are immutables of every vault token, the Lock, Collateralization and the ProxyManager, so they never change |
| 4 | Lock | Immutable (`REQ-LOCK-001`) | CREATE3 | `AAVE_ADAPTER`, `LP_VAULT_SWAP`, `SELF` from predictions |
| 5 | Collateralization | Immutable (`REQ-COLL-002`) | CREATE3 | `ADAPTER`, `LP_VAULT_SWAP`, `RISK_MODULE`, `LOCK`, `VAULT_TOKEN_FACTORY` |
| 6 | LPVault, one per AMM protocol of the chain (Uniswap v3 on Ethereum, Slipstream on Base) | Immutable (`REQ-VAULT-155`) | CREATE3 | `INTEGRATION_ID`, `COLLATERALIZATION`, `MARKET_REGISTRY`, `LOCK`, `TIMELOCK`, and the AMM protocol's position manager and factory (`REQ-AMM-V3-001`, [2.21](../../spec/02-contracts/21-aerodrome-slipstream-integration.md)); a later AMM protocol adds one LPVault and touches no other contract |
| 7 | VaultTokenFactory | Immutable (`REQ-VTOKEN-023`) | CREATE3 | `ADAPTER`, `LP_VAULT_SWAP`, `COLLATERALIZATION`, `TIMELOCK`, `MARKET_REGISTRY` (the factory reads the Lock through Collateralization); registers each LPVault's integration ID once; deploys vault tokens with CREATE3, salt `keccak256(abi.encode(spoke, marketKey))` (`REQ-VTOKEN-020`), only when called by `TIMELOCK` in a listing batch |
| 8 | ProxyManager, then `AaveV3FlashSource` | Immutable (`REQ-PROXY-001`, `REQ-FLASH-001`) | CREATE3 | ProxyManager: `ADAPTER`, `MARKET_REGISTRY`, `PROXY_CREATION_CODE_HASH`. `AaveV3FlashSource`: `LENDER` (the chain's Aave V3 Pool), `LP_VAULT_SWAP`, `PARAMETER_STORE`; LPVaultSwap points at it through `setFlashSource`. There is no settlement budget (`Q-397`) |
| 9 | PayoutEscrow (escrow for failed payouts, Q-401) | Immutable (`REQ-ESCROW-001`) | CREATE3 | `LP_VAULT_SWAP`, `LOCK`; the constructor reverts `LockMismatch` unless the Lock of step 4 names the same LPVaultSwap |
| 10 | Swap route contracts (`PegModule`, `DexPath`, `WrapperThenDex`) | Immutable per version (`REQ-ROUTE-017`) | CREATE3, salt includes `(marketId, token, debtAsset, kind)` | Recorded in the MarketRegistry by `setRoute` in timelock operations, a primary and a backup per (market, token, debt asset); there are no buy or sell-back routes (`Q-379`) |
| 11 | Lens | Immutable, stateless, periphery outside the audited core (`REQ-LENS-001`) | CREATE | A new Lens is a new deployment; the manifest records the current address |
| 12 | Coverage Spoke (Avana Umbrella), one per covered (Hub, debt asset): at launch GHO on the chain's Stable LP Hub | Immutable, no owner; its only authority is the Aave DAO's AccessManager (`REQ-FLR-002`, `REQ-FLR-003`) | CREATE (address recorded) | `constructor(hub, asset, assetId, aaveAccessManager, 1,209,600)` reverts unless the Hub already lists `asset` under `assetId` with the token's decimals and the delay is `reserveWithdrawalDelay` (`REQ-FLR-008`), so it runs after the debt asset is listed on the Hub (`02_DeployAaveV4` in test environments, the Aave DAO's deployment on mainnet) and before the Aave payload of `MKT-023`, which registers it on its asset (`drawCap = 0`, `addCap = MAX_ALLOWED_SPOKE_CAP`, `REQ-FLR-007`), grants it `HUB_DEFICIT_ELIMINATOR_ROLE`, maps `coverDeficit` to `COVERAGE_ROLE` and the DAO functions to `RESERVE_ADMIN_ROLE`, allowlists the CDP Spoke and sets `firstLossReserveMinimum`; Avana Labs then calls `fund` up to the minimum before `enableDebtReserve` names the instance in `DebtReserveDef.coverageSpoke` and before any `drawCap` on that (Hub, asset) rises above 0 (`REQ-FLR-007`, `REQ-FLR-011`, `REQ-FLR-039`). No Avana contract fixes its address as an immutable, and the deployer, the timelock and every Avana contract hold no role on it. A later debt asset or Hub adds one instance the same way |
| 13 | Guardian roles | `04_ConfigureAccess` | — | Role-change operation at the normal delay, scheduled by the governance multisig at deployment; it executes before any listing batch can, so the guardians hold their roles before any market can take a pledge |
| 14 | Deployment check | `07_VerifyDeployment` | — | Every predicted address, immutable (including each `TIMELOCK`), ERC-1967 implementation slot and role equals the manifest; the deployer holds no role |

PositionProxies are not deployed by the scripts: each is a logic-free immutable account that the ProxyManager creates on the AaveAdapter's call, one per (wallet, CDP Spoke, market), with CREATE2 and salt `keccak256(abi.encode(wallet, spoke, marketId))` (`REQ-PROXY-001`); the manifest records the init-code hash used by `predictProxy`.

On mainnet Aave V4 is the Aave DAO's deployment; the manifest names its Hubs, CDP Spokes, Lend Spoke, AaveOracle, configurators and the linked `LiquidationLogic`, and `03_DeployAvana` reads them instead of running steps 01–02; the Coverage Spokes are Avana's deployments of step 12, which the Aave DAO registers and controls. Aave-side settings Avana depends on (the deployment AIP, `FLASH_BORROWER` on the Aave V3 Pool for LPVaultSwap's flash source, the Aave Protocol Guardian's one-way `freezeReserve` and `pauseReserve`) are governance payloads in [`governance/`](../../governance/), not script actions.

## Listing a market

Listings follow `MKT-018`…`MKT-026`. A listing carries one normal-delay (5-day) timelock operation; activation is a separate short-delay (12-hour) operation. Anyone executes a ready operation within its 14-day grace period, and any canceller can cancel it while it waits.

1. `05_ProposeListing` deploys the market's LPOracle as a UUPS proxy (`_authorizeUpgrade` requires `APPLICATION_ADMIN`) and runs `initialize` in the same transaction with the timelock, the pool, the stable flags, the description, `pokeMinGas`, the oracle configuration, the ParameterStore and the MarketRegistry; `initialize` reverts unless that configuration gives a Live price and seeds it as the first accepted price. It calls `increaseObservationCardinalityNext(n)` on the pool with `n` covering `twapWindow` (`MKT-019`).
2. The governance multisig schedules the listing batch with `scheduleBatch` at the normal delay (`MKT-018`), in this order: for each new pool token `ParameterStore.setFeed`, `setTokenCollateralFactorBps`, `setFeedAgreementToleranceBps` and `MarketRegistry.listToken`; `VaultTokenFactory.deployVaultToken(integrationId, pool, poolId, shape, hub, spoke, marketId, lpOracle, decimals, name, symbol)` with `marketId = marketCount + 1`; `MarketRegistry.listCollateralMarket(def)`; `ParameterStore.setInitialMarketParams` (including `minPledgeUsd`), `setInitialMarketCaps`, `setInitialTokenCap` and the route depth thresholds; `MarketRegistry.setRoute` for the primary and backup route of every non-GHO pool token; and, on a CDP Spoke's first market, `MarketRegistry.enableDebtReserve(spoke, def)` for each of its debt reserves. The vault token's `MARKET_ID` and `LP_ORACLE` are immutable and Collateralization reads every pledge's market and feed from them, so `deployVaultToken` and `listCollateralMarket` execute in the same batch; if another market took the ID first, both revert and the listing is proposed again (`MKT-F-007`). The vault-token address in the proposed manifest is `VaultTokenFactory.predictAddress(spoke, marketKey)`, with `marketKey = marketKeyOf(integrationId, pool, poolId, shape)`.
3. After the normal delay, anyone executes the batch (`MKT-020`, `MKT-021`); `06_SeedPrice` confirms the feed is Live (`MKT-022`).
4. The Aave DAO executes the listing payload (`MKT-023`).
5. `07_VerifyDeployment` runs the live-configuration check against the payload result (`MKT-024`); activation is scheduled only after it passes.
6. The governance multisig schedules `MarketRegistry.activateMarket(marketId)` at the short delay and anyone executes it; it reverts with `ActivationCheckFailed` unless the Aave side matches the registration (`MKT-026`).

## Verification before `deployments/verified/`

`07_VerifyDeployment` and the `test/fork/deployment/` tests check, against the manifest named by `AVANA_MANIFEST`:

- **Bytecode** (`TEST-134`): the runtime code of each Avana contract and UUPS implementation equals the release build in `out/` with immutable positions masked (positions from the artifact's `immutableReferences`), and each immutable equals the manifest value; Aave V4 contracts equal the `out-aave/` build of `a3ef63e`. `bytecode_hash = "none"` keeps the comparison independent of metadata.
- **Wiring**: `PayoutEscrow.LOCK().LP_VAULT_SWAP()` equals `PayoutEscrow.LP_VAULT_SWAP()` and the LPVaultSwap proxy (`REQ-ESCROW-001`); `VaultTokenFactory.MARKET_REGISTRY()` is the MarketRegistry proxy and every registered LPVault's `TIMELOCK()` and `MARKET_REGISTRY()` equal the chain's (`REQ-VTOKEN-044`); every vault token's symbol is `avLP-<marketId>` and its name the market's description (`REQ-VTOKEN-050`).
- **Live configuration** (`TEST-135`): the reserve flags, Hub assets and caps, collateral factors, CDP Spoke standard implementation and the three required settings (`receiveSharesEnabled = false`, `liquidationFee = 0`, no reinvestment controller), borrowable reserves equal to the enabled debt reserves, credit lines, `FLASH_BORROWER`, the role snapshot of the timelock and every upgradeable contract, every ERC-1967 implementation slot, keeper count and parameter bounds listed in [`deployments/README.md`](../../deployments/README.md).

A manifest that passes both, approved by the governance multisig signers, is copied unchanged from `proposed/` to `verified/`; only verified manifests are exported by `packages/protocol`.

## Manifests

Scripts read manifests with `vm.readFile` and `vm.parseJson*` (`fs_permissions` grants read on `../deployments`) and write their output with `vm.serialize*` and `vm.writeJson` to `deployments-local/<chainId>-<release>.json` (the only writable path). The output has the shape of a release manifest: chain ID, release commit, ABI hash of the build, Aave V4 addresses with `liquidationLogic`, every Avana address, each UUPS implementation and every immutable, the PositionProxy creation-code hash used by `predictProxy`, the timelock's role holders and settings, deployment blocks, and per market the pool, vault token, decimals, Hub asset ID, CDP Spoke and its reserve ID, LPOracle and routes. The mainnet-fork run is the shared environment (`TEST-004`): its manifest is what the web app, indexer and keeper tests consume.

## Environment variables

| Variable | Used by | Meaning |
|---|---|---|
| `RPC_MAINNET` | Ethereum fork and mainnet runs | Archive RPC endpoint (`[rpc_endpoints] mainnet`) |
| `RPC_BASE` | Base fork and Base runs | Archive RPC endpoint (`[rpc_endpoints] base`) |
| `RPC_SEPOLIA` | Sepolia runs | RPC endpoint (`[rpc_endpoints] sepolia`) |
| `RPC_BASE_SEPOLIA` | Base Sepolia runs | RPC endpoint (`[rpc_endpoints] base_sepolia`) |
| `MAINNET_FORK_BLOCK` | local fork runs | Override of `ForkConstants.MAINNET_FORK_BLOCK` (`test/utils/fixtures/ForkConstants.sol`) for local experiments; CI uses the committed pin |
| `BASE_FORK_BLOCK` | local fork runs | Override of `ForkConstants.BASE_FORK_BLOCK`, as above |
| `ETHERSCAN_API_KEY` | `--verify` | Source verification on Ethereum, Base, Sepolia and Base Sepolia (one Etherscan v2 key) |
| `CERTORAKEY` | `certoraRun` | Certora Prover key |
| `ACCOUNT_NAME`, `SENDER` | `make deploy-%` | Foundry keystore account name and its address |
| `LEDGER_SENDER`, `MNEMONIC_INDEX` | `make deploy-ledger-%` | Ledger address and derivation index |
| `AVANA_MANIFEST` | `03`–`07` | Path of the input manifest under `../deployments/` |
| `AVANA_RELEASE` | `02`, `03`, `05` | Release tag used in salts and output file names; `02` uses it to predict the LPVaultSwap proxy address. Equals the annotated git tag `vX.Y.Z` of the commit being deployed (see [Releases and tags](#releases-and-tags)) |
| `FOUNDRY_LIBRARIES` | `02` and the `aave` profile build | Set from `deployments-local/libraries.env` after `01` |
| `AVANA_FIXTURE` | hostile suites | `fork` runs the hostile-component tests on the Ethereum fork |

Every name is listed, without values, in [`../.env.example`](../.env.example); copy it to `contracts/.env`, which is gitignored.

The deployer signs with a Foundry keystore account (`--account <name> --sender <address>`) or a Ledger (`--ledger --mnemonic-indexes <n> --sender <address>`); no private key is passed through the environment. The deployer holds no role once deployment ends; every later change is a timelock operation scheduled by the governance multisig.

## Commands

```bash
# Local chain with Avana's Aave V4
anvil
forge script script/00_Factories.s.sol --rpc-url anvil --broadcast
FOUNDRY_PROFILE=aave forge build
forge script script/01_LiquidationLogic.s.sol --rpc-url anvil --broadcast --account deployer
set -a; . deployments-local/libraries.env; set +a
FOUNDRY_PROFILE=aave forge build --force
AVANA_RELEASE=<tag> forge script script/02_DeployAaveV4.s.sol --rpc-url anvil --broadcast --account deployer
AVANA_RELEASE=<tag> AVANA_MANIFEST=../deployments/proposed/<file>.json \
  forge script script/03_DeployAvana.s.sol --rpc-url anvil --broadcast --account deployer
AVANA_MANIFEST=../deployments/proposed/<file>.json \
  forge script script/04_ConfigureAccess.s.sol --rpc-url anvil --broadcast --account deployer

# Dry run of a mainnet deployment on a fork
forge script script/03_DeployAvana.s.sol --fork-url "$RPC_MAINNET" --fork-block-number "$MAINNET_FORK_BLOCK"

# Checks before a manifest moves to deployments/verified/
AVANA_MANIFEST=../deployments/proposed/<file>.json forge script script/07_VerifyDeployment.s.sol --rpc-url mainnet
```

## Makefile

[`../Makefile`](../Makefile) wraps the commands above. It reads `.env` and takes `chain` (an `[rpc_endpoints]` alias, default `anvil`) and `dry` on the command line. Every deploy target is a dry run unless `dry=0`: the script is simulated against the chain with the given sender and nothing is broadcast. With `dry=0` it broadcasts with `--slow`, so each transaction is confirmed before the next is sent, and on every chain except Anvil adds `--verify`, which submits the sources to the explorer configured for that chain in `[etherscan]` (Ethereum, Base, Sepolia and Base Sepolia, one `ETHERSCAN_API_KEY`).

```bash
make deploy-03_DeployAvana chain=sepolia                 # simulation with the keystore account
make deploy-03_DeployAvana chain=sepolia dry=0           # broadcast and verify
make deploy-ledger-03_DeployAvana chain=mainnet dry=0    # broadcast from a Ledger (LEDGER_SENDER, MNEMONIC_INDEX)
make build test test-fork gas gas-check sizes coverage security-fast
```

Each deploy script derives from a base contract with `_expectedChainId()` and reverts unless `block.chainid` equals it, with one subclass per chain (`...Ethereum`, `...Base`, `...Sepolia`, `...BaseSepolia`, `...Anvil`), so a script pointed at the wrong RPC fails before its first transaction.

## Releases and tags

`AVANA_RELEASE` goes into the CREATE2 and CREATE3 salts of every Avana contract and into the manifest file names, so the release string fixes the deployed addresses.

- A release is an annotated git tag `vX.Y.Z` on a commit of `main` that passed every CI job, with its section in [`CHANGELOG.md`](../../CHANGELOG.md). Version rules are in that file.
- `AVANA_RELEASE` equals that tag. Scripts `02`, `03` and `05` assert that `vm.envString("AVANA_RELEASE")` equals the manifest's `release` and that the manifest's `commit` is the tagged commit.
- A tag is never moved, deleted or reused: a tag deployed once names those addresses for good. A fix is a new tag.
- External audit reports name the audited and fix commits ([`audit/external/`](../../audit/external/index.md)); a verified manifest names a release whose commit is the fix commit or later with no change to the audited files.

## Checks on the build

| Script | Does |
|---|---|
| `check-sizes.sh` | Writes `out-security/sizes.json` from `out/` and fails when a deployable `src/` contract's runtime code is larger than 24,576 bytes minus its margin in [`security/size-margins.json`](../security/size-margins.json); with `--base <sizes.json>` prints each change in size. CI compares every pull request with the sizes saved from the last `main` build and writes the table to the job summary. |
| `governance-diff.py` | Writes a governance operation folder's `diff.md` from its `before.json` and `after.json` ([`governance/README.md`](../../governance/README.md#operation-folders)). |

## Mutation testing at the layer gate

From `contracts/`, after `script/install-security-tools.sh --python --gambit`:

```bash
MUTATE_LAYERS=2.1 script/security-slow.sh mutate gambit necessist          # every mutation step of layer 2.1
MUTATE_LAYERS=2.1 script/security-slow.sh gambit                           # Gambit only
MUTATE_LAYERS=2.2 MUTATE_CONTRACTS=ClPriceMath GAMBIT_TIMEOUT=600 script/security-gambit.sh   # one file, longer budget
script/mutation-targets.py gambit --layers 2.2                             # the files, tests, cap, seed and operators Gambit uses
```

`security-gambit.sh` writes `out-security/gambit/<layer>/<Contract>/status.tsv` (each mutant `killed`, `survived`, `timeout` or `invalid`), the mutants and their diffs under `gambit/`, one test log per mutant, `out-security/gambit/<layer>/survivors.txt` and the gate summary `out-security/gambit/gate.txt`. A survived or timed-out mutant fails the run until a test kills it or the layer gate review adds its fingerprint to `security/gambit-triage.json` with the reason its change cannot be observed. CI runs it in the `layer-gate` job (`workflow_dispatch` with the `layer` input).
