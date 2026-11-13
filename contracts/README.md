# contracts

The Foundry workspace for Avana's Solidity contracts. It builds and tests with the pinned Foundry, Solidity and dependency versions only, independently of the TypeScript workspace. Contracts are written from the specification in [`spec/`](../spec/); where code and specification disagree, the specification changes first and the code follows.

`src/` holds the interface of every Avana contract, with every external function, event and custom error of its contract page, and the minimal interfaces of the external contracts Avana calls. Each contract has its own folder, and its interface files sit next to the file its implementation will occupy (see [File layout and size limits](#file-layout-and-size-limits)).

## Toolchain

| Tool | Version | Pinned in |
|---|---|---|
| Foundry (`forge`, `cast`, `anvil`, `chisel`) | 1.9.0 | [`.foundry-version`](.foundry-version), read by every job of [`.github/workflows/contracts.yml`](../.github/workflows/contracts.yml) |
| Solidity | 0.8.28, EVM `cancun`, optimizer on, `bytecode_hash = "none"` (`REQ-ARCH-053`) | `foundry.toml` |
| Soldeer (dependency manager, `forge soldeer`) | bundled with Foundry 1.9.0 | `foundry.toml` `[dependencies]`, `soldeer.lock` |
| certora-cli | 8.20.3 | `requirements.txt` |
| Halmos | 0.3.3 (requires Python 3.11 or later) | `requirements.txt` |
| Slither, crytic-compile | 0.11.6, 0.4.2 | `requirements.txt` |
| Mythril | 0.24.8, in its own venv `.venv-mythril` (its `z3-solver` pin conflicts with Halmos) | `requirements-mythril.txt` |
| Semgrep | 1.182.1 | `requirements.txt` |
| Semgrep smart-contract rules (Decurity) | commit `2e878a89ac7bba1f8435e8a68e3ecb7700096cd5`, checked out into `tools/semgrep-smart-contracts/` (licensed CC BY-NC-SA 4.0; read at run time, not copied into the repository) | `script/install-security-tools.sh` |
| 4naly3er | commit `8a9d1ebb7d362bc94f036fa9123d0977c6cb7436`, checked out into `tools/4naly3er/` with its Node dependencies and solc-js 0.8.28 as its only compiler | `script/install-security-tools.sh` |
| solhint, @openzeppelin/upgrades-core | 6.2.5, 1.47.0 | `package.json`, `package-lock.json` |
| Necessist | 4.1.0, built with `cargo install --locked` into `tools/bin/` (no release binaries exist) | `script/install-security-tools.sh --necessist` |
| Gambit | the binary shipped in the certora-cli 8.20.3 wheel, linked as `tools/bin/gambit` | `requirements.txt` (certora-cli pin), `script/install-security-tools.sh --gambit` |
| Echidna, Medusa, Aderyn, hevm | 2.3.3, 1.5.1, 0.6.8, 0.58.0 (GitHub release binaries in `tools/bin/`, checked by sha256) | `script/install-security-tools.sh` |
| uv | 0.13.1 in CI | CI `UV_VERSION`; resolves Python packages with an upload-date cutoff |
| Python | 3.11 for `.venv` and `.venv-mythril` (uv); 3.12 in the Halmos, differential and Certora CI jobs | `script/install-security-tools.sh`, CI workflow |

Dependencies, installed by Soldeer into `dependencies/` (not committed) and locked by checksum or commit in `soldeer.lock`. There are no git submodules.

| Dependency | Version | Remapping | Used for |
|---|---|---|---|
| forge-std | 1.17.0 | `forge-std/` | Tests and scripts |
| OpenZeppelin Contracts | 5.1.0 (`EXT-018`, `REQ-VTOKEN-002`) | `@openzeppelin/contracts/` | `ERC20`, `SafeERC20`, `Math`, `TimelockController` (base of the AvanaTimelock), `ERC1967Proxy`, ERC-3156 and ERC-4626 interfaces |
| OpenZeppelin Contracts Upgradeable | 5.1.0 | `@openzeppelin/contracts-upgradeable/` | `Initializable`, `UUPSUpgradeable` and `AccessControlUpgradeable` bases of the upgradeable contracts |
| Solady | 0.1.26 | `solady/` | `CREATE3` for the VaultTokenFactory (`REQ-VTOKEN-020`) |
| Aave V4 | `a3ef63ea6415d25237a9775bf66e76e9993561c2` | `aave-v4/` and a context remapping of its own `src/` imports | Avana's Aave V4 deployment on Anvil, Sepolia and forks, including the Aave-side `AccessManagerEnumerable` that governs the Hub and Spokes; the reference the Avana-written Aave V4 interfaces are checked against (selectors, struct layouts, events) |
| Uniswap v3-core | `5ea68a77cb541c6b3812df783be71ba8c081e25f` | `@uniswap/v3-core/` | Reference source of the pool and factory interfaces and tick math (0.7.6; not compiled) |
| Uniswap v3-periphery | `24ccf014fe7f81d74a14c1689d6fdf123f280e45` | `@uniswap/v3-periphery/` | Reference source of the NonfungiblePositionManager interface (0.7.6; not compiled) |
| gho-core | `c6335a0bb9cba099960c5378b1ff0db190b8da8f` | `gho-core/` | Reference source of the GSM interfaces |
| halmos-cheatcodes | `6da4e692c357ba6d641a2e677a28298cac9f76ab` | `halmos-cheatcodes/` | Remapped for `test/halmos/` and the Certora confs; no Avana file imports it today (the Halmos tests use forge-std) |

`remappings.txt` is maintained by hand (`remappings_generate = false`, `auto_detect_remappings = false`) because Aave V4 imports its own files as `src/...`, which needs the context remapping `dependencies/aave-v4-a3ef63e/:src/=dependencies/aave-v4-a3ef63e/src/`. Changing a pin means editing `[dependencies]`, running `forge soldeer update`, and reviewing the `soldeer.lock` diff; CI installs strictly from the lock file (`TEST-001`).

## Setup

```bash
cd contracts
cp .env.example .env                     # every variable name the workspace reads: RPC endpoints and keys
forge soldeer install                    # dependencies/ from soldeer.lock
script/install-security-tools.sh         # .venv, .venv-mythril, node_modules/ (solhint), tools/bin/ (Echidna, Medusa, Aderyn, hevm)
forge build
```

## Layout

```
contracts/
├── foundry.toml          profiles, formatter, linter, dependencies
├── .foundry-version      the Foundry release CI installs
├── .env.example          every environment variable name, without values
├── Makefile              build, test, gas, size and deploy targets
├── snapshots/            committed gas snapshots of test/gas/ (gas profile)
├── remappings.txt
├── soldeer.lock
├── requirements.txt      certora-cli, Halmos, Slither, crytic-compile
├── requirements-mythril.txt  Mythril (own venv)
├── package.json, package-lock.json  solhint
├── slither.config.json, aderyn.toml, .solhint.json, .solhintignore, echidna.yaml, medusa.json
├── security/             triage files of Slither, slither-check-upgradeability, Aderyn and Mythril; mythril.conf; size-margins.json
├── src/
│   ├── amm/                        IAmmIntegration, IAmmIntegrationHooks, IClIntegration; uniswap-v3/, slipstream/; shared AMM types
│   ├── custody/
│   │   ├── lp-vault/               ILPVault: NFT custody, liquidity removal, fee collection, stray NFTs (one LPVault per AMM protocol per chain)
│   │   └── collateralization/      ICollateralization: records, pledge and release, seizure, pending settlement, counters
│   ├── vault-token/
│   │   ├── vault-token/            IVaultToken
│   │   └── vault-token-factory/    IVaultTokenFactory
│   ├── proxy/
│   │   ├── position-proxy/         IPositionProxy (logic-free account: Adapter-only execute)
│   │   └── proxy-manager/          IProxyManager (CREATE2 deployer of every PositionProxy)
│   ├── flash/                      IFlashSource, IFlashReceiver
│   ├── policy/
│   │   ├── aave-adapter/           IAaveAdapter: borrower entry points, burnSeized, proxy lookups
│   │   ├── risk-module/            IRiskModule: pledge and borrow-side checks, previews, RiskModuleConstants
│   │   ├── market-registry/        IMarketRegistry: Spokes, debt reserves, tokens, markets, routes, in-kind, pause state
│   │   └── parameter-store/        IParameterStore: risk parameters with tighten, loosen and listing setters
│   ├── oracle/
│   │   ├── lp-oracle/              ILPOracle, ILPOracleCL
│   │   └── debt-oracle/            IDebtOracle (one per debt asset other than GHO)
│   ├── liquidation/
│   │   ├── lp-vault-swap/          ILPVaultSwap
│   │   ├── settlement-routes/      ISettlementRoute (swap routes from each unwound token into the debt asset)
│   │   └── payout-escrow/         IPayoutEscrow
│   ├── governance/
│   │   ├── timelock/               IAvanaTimelock
│   │   └── roles/                  AvanaRoles (role IDs)
│   ├── lock/
│   │   └── lock/                   ILock, LockSlot
│   ├── lens/
│   │   └── lens/                   ILens and its pieces, LensConstants
│   ├── types/                      structs and enums shared by several contracts, one per file
│   └── interfaces/external/
│       ├── aave/         Aave V4 Spoke (events and extSload in their own files), Hub, AaveOracle, price-feed interface, Coverage Spoke funding; Aave V3 Pool, flash-loan receiver, ACLManager
│       ├── uniswap/      NonfungiblePositionManager, UniswapV3Factory, UniswapV3Pool, swap callback
│       ├── aerodrome/    Slipstream NonfungiblePositionManager, CLFactory, CLPool, CLGauge
│       ├── chainlink/    AggregatorV3, aggregator proxy, offchain aggregator bounds, sequencer-uptime feed
│       ├── sky/          LitePSM, DAI↔USDS converter
│       └── curve/        StableSwap-NG pool
├── test/                 test plan and folder conventions: test/README.md
├── aave-deploy/          AvanaAaveV4Roles: runs Aave's role procedures for the local fixture; built only by the aave profile
├── certora/              CVL specifications and configurations: certora/README.md
├── script/               deployment, listing and verification, file size check: script/README.md
├── dependencies/         Soldeer packages (ignored)
├── tools/bin/            Echidna, Medusa, Aderyn, hevm (ignored)
├── out-security/         security tool builds and reports (ignored)
├── out/, cache/          Avana build (ignored)
└── out-aave/, cache-aave/  Aave V4 build with Aave's compiler settings (ignored)
```

GHO and the other debt assets are reached through OpenZeppelin's `IERC20`. Flash funding goes through the chain's `IFlashSource` implementation over the Aave V3 Pool (`src/flash/`); Avana uses no GHO flash minter (`Q-379`).

### Folders and the specification

| Folder | Contract | Form (1.2) | Spec page | Requirement IDs |
|---|---|---|---|---|
| `amm/` | AMM integration interface; Uniswap v3 and Aerodrome Slipstream integrations | Interfaces of each LPVault and its pricing library | [2.19](../spec/02-contracts/19-amm-integration-interface.md), [2.20](../spec/02-contracts/20-uniswap-v3-integration.md), [2.21](../spec/02-contracts/21-aerodrome-slipstream-integration.md) | `REQ-AMM-CORE-…`, `SPEC-AMM-CORE-…`, `REQ-AMM-V3-…`, `SPEC-AMM-V3-…`, `REQ-AMM-SLIP-…`, `SPEC-AMM-SLIP-…` |
| `custody/lp-vault/` | LPVault (one per AMM protocol per chain) | Immutable | [2.2](../spec/02-contracts/02-lp-vault.md) | `REQ-VAULT-…`, `REQ-ARCH-031` |
| `custody/collateralization/` | Collateralization | Immutable | [2.3](../spec/02-contracts/03-collateralization.md) | `REQ-COLL-…`, `REQ-VAULT-…`, `SPEC-BACK-…`, `REQ-ARCH-171` |
| `vault-token/vault-token/`, `vault-token/vault-token-factory/` | Vault token, VaultTokenFactory | Immutable | [2.4](../spec/02-contracts/04-vault-tokens.md) | `REQ-VTOKEN-…`, `SPEC-UNIT-…`, `REQ-ARCH-032`, `REQ-ARCH-033` |
| `proxy/position-proxy/`, `proxy/proxy-manager/` | PositionProxy, ProxyManager | Immutable: each PositionProxy is a logic-free contract created by CREATE2 per (wallet, CDP Spoke, market) by the immutable ProxyManager, with no beacon or upgrade | [2.5](../spec/02-contracts/05-position-proxy-and-proxy-manager.md) | `REQ-PROXY-…`, `SPEC-PROXY-…`, `REQ-ARCH-034`, `REQ-ARCH-035` |
| `policy/aave-adapter/`, `policy/risk-module/` | AaveAdapter, RiskModule | Upgradeable (UUPS) | [2.6](../spec/02-contracts/06-aave-adapter.md), [2.7](../spec/02-contracts/07-risk-module.md) | `REQ-ADAPTER-…`, `REQ-PROXY-…`, `REQ-RISK-…`, `SPEC-CAP-…`, `SPEC-CF-…` |
| `policy/market-registry/` | MarketRegistry: Spokes, debt reserves, tokens, price sources, markets, routes, in-kind windows and the application pause state | Upgradeable (UUPS) | [2.8](../spec/02-contracts/08-market-registry.md) | `REQ-CONFIG-…`, `REQ-MREG-…`, `REQ-ARCH-142` |
| `policy/parameter-store/` | ParameterStore: every risk parameter with its tighten, loosen and listing setters and bounds | Upgradeable (UUPS) | [2.9](../spec/02-contracts/09-parameter-store.md) | `REQ-PSTORE-…`, `REQ-CONFIG-…`, `REQ-RISK-…` |
| `oracle/lp-oracle/`, `oracle/debt-oracle/` | LPOracle (one implementation per AMM protocol, one instance per market); DebtOracle (one per debt asset other than GHO) | Upgradeable (UUPS) | [2.10](../spec/02-contracts/10-lp-oracle.md) | `REQ-ORACLE-…`, `SPEC-ORC-…`, `REQ-ARCH-039`, `REQ-ARCH-189` |
| `liquidation/lp-vault-swap/`, `liquidation/settlement-routes/`, `liquidation/payout-escrow/` | LPVaultSwap; swap routes; PayoutEscrow | Upgradeable (UUPS) at a fixed address; immutable per version; immutable | [2.11](../spec/02-contracts/11-lpvaultswap.md), [2.12](../spec/02-contracts/12-settlement-routes.md), [2.18](../spec/02-contracts/18-payout-escrow.md) | `REQ-SWAP-…`, `SPEC-LIQ-…`, `REQ-ROUTE-…`, `REQ-ESCROW-…` |
| `flash/` | `IFlashSource` implementation over the Aave V3 Pool | Immutable; replaced by `setFlashSource` on LPVaultSwap | [2.11](../spec/02-contracts/11-lpvaultswap.md) | `REQ-FLASH-…`, `REQ-ARCH-210` |
| `governance/timelock/`, `governance/roles/` | AvanaTimelock; AvanaRoles role IDs | Immutable | [2.15](../spec/02-contracts/15-governance-and-timelock.md), [1.4](../spec/01-architecture/04-permissions-and-roles.md) | `REQ-ACCESS-…`, `SPEC-GOV-…`, `REQ-ROLE-…` |
| `lock/lock/` | Lock | Immutable | [2.16](../spec/02-contracts/16-lock.md) | `REQ-LOCK-…` |
| `coverage/coverage-spoke/` | Avana Umbrella (Coverage Spoke), one per covered `(Hub, debt asset)` | Immutable; controlled by the Aave DAO through its AccessManager | [2.14](../spec/02-contracts/14-first-loss-reserve.md) | `REQ-FLR-…`, `SPEC-FLR-…` |
| `lens/lens/` | Lens | Immutable; a new Lens is a new deployment | [2.17](../spec/02-contracts/17-lens.md) | `REQ-LENS-…` |
| `interfaces/external/` | Aave V4, Uniswap v3, Chainlink, GHO, Sky, Curve | External | [4.3](../spec/04-security/03-external-dependencies.md), [2.1](../spec/02-contracts/01-avana-hub-and-spokes.md) | `EXT-…` (in NatSpec) |

The SettlementBudget ([2.13](../spec/02-contracts/13-settlement-budget.md)) is removed (`Q-397`): the liquidation caller pays any rounding gap, so it has no folder. Debt buy routes are removed too (`Q-379`): LPVaultSwap flash-borrows the debt asset itself.

The First-Loss Reserve ([2.14](../spec/02-contracts/14-first-loss-reserve.md)) is a set of Coverage Spokes (Avana Umbrella), one per covered `(Hub, asset)`. Each is a supply-only Aave V4 Spoke that Avana writes in `coverage/coverage-spoke/` and the Aave DAO controls through its own AccessManager (`COVERAGE_ROLE`, `RESERVE_ADMIN_ROLE`); no Avana contract, multisig, timelock or keeper holds a role on it. LPVaultSwap's `settlePending` funds the Coverage Spoke of the market's (funding Hub, debt asset) with the value recovered from pending settlement, and the RiskModule and the Lens read its balance and minimum.

### File layout and size limits

Every contract has one folder, `src/<domain>/<contract>/`, named after the contract in kebab case; the implementation `<Contract>.sol` sits in the same folder as its interfaces. Inside a folder, files are split by kind and, for a large surface, by audience:

| File | Holds |
|---|---|
| `I<Name>.sol` | The external functions of a small contract, or the aggregate that inherits every piece of a large one. The implementation declares only `I<Name>`. |
| `I<Name>Events.sol`, `I<Name>Errors.sol` | Every event and every custom error of the contract. |
| `I<Name><Audience>.sol` | The functions one class of caller uses, for example `ILPVaultSwapKeeper`, `ILPVaultSwapPermissionless`, `ILPVaultSwapAdmin` and `ILPVaultSwapViews`. |
| `types/<Type>.sol` | One struct or enum of the contract per file, declared at file level. |
| `<Name>Constants.sol` and other libraries | Constant-only libraries of the contract. |

Callers import only the piece they call, for example `IRiskModuleChecks` for `checkPledge`, `ILPVaultSwapKeeper` for a keeper bot, or `I<Name>Errors` for a revert selector in a test. Structs and enums used by several contracts live in `src/types/`.

| Contract | Pieces besides events and errors |
|---|---|
| MarketRegistry | `IMarketRegistryListing`, `IMarketRegistryHubs`, `IMarketRegistryCreditLines`, `IMarketRegistryRoutes`, `IMarketRegistryRouteViews`, `IMarketRegistryStandby`, `IMarketRegistryPause`, `IMarketRegistryFreeze`, `IMarketRegistryBreakers`, `IMarketRegistryWindDown`, `IMarketRegistryViews`, `IMarketRegistrySafetyEvents` |
| ParameterStore | `IParameterStoreTighten`, `IParameterStoreLoosen`, `IParameterStoreListing`, `IParameterStoreLiquidation`, `IParameterStoreBreakers`, `IParameterStoreChain`, `IParameterStoreAdmin`, `IParameterStoreViews`, `IParameterStoreRiskViews` |
| AaveAdapter | `IAaveAdapterUser`, `IAaveAdapterCollateral`, `IAaveAdapterSettlement`, `IAaveAdapterAdmin`, `IAaveAdapterViews` |
| LPVault | `ILPVault`, which implements `IAmmIntegration` and `IAmmIntegrationHooks` (`src/amm/`) |
| Collateralization | `ICollateralizationAdapter`, `ICollateralizationSeizure`, `ICollateralizationUser`, `ICollateralizationDebtMark`, `ICollateralizationViews` |
| LPVaultSwap | `ILPVaultSwapKeeper`, `ILPVaultSwapPermissionless`, `ILPVaultSwapDeleverage`, `ILPVaultSwapAdmin`, `ILPVaultSwapViews` |
| RiskModule | `IRiskModuleChecks`, `IRiskModuleAdmin`, `IRiskModuleViews` |
| PositionProxy | `IPositionProxy` |
| AvanaTimelock | `IAvanaTimelockGovernance` (self-call setters, expired-operation clean-up), `IAvanaTimelockViews` |
| Lens | `ILensAccount`, `ILensMarket`, `ILensLiquidation`, `ILensPreview`, `ILensRisk`; the dependency getters are declared on `ILens` |
| LPOracle | `ILPOracle`, `ILPOracleCL` |
| DebtOracle | `IDebtOracle` |

Size limits (`Q-240`): an implementation file holds at most 500 lines of code (lines that are neither blank nor comment-only), and an interface file at most 300 lines including NatSpec and blank lines. [`script/check-file-size.sh`](script/check-file-size.sh) treats a file as an implementation when it declares a contract or a library with functions, and every other `.sol` file under `src/` (interfaces, events, errors, types, constant-only libraries, external mirrors) as an interface file. It prints each file over its limit and the largest file of each class, and exits 1 when any file is over; the CI build job runs it.

### Implementation rules carried by the interfaces

- Upgradeable contracts (AaveAdapter, RiskModule, MarketRegistry, ParameterStore, each LPOracle, each DebtOracle, LPVaultSwap) are UUPS proxies (ERC-1967) whose `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only by the AvanaTimelock, so every upgrade is a normal-delay (5-day) timelock operation that any canceller can cancel; there is no `ProxyAdmin` and no `Ownable` owner. Each `initialize(timelock, …)` runs in the transaction that deploys its proxy and grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` only to the timelock (`REQ-ACCESS-150`). They keep their state in ERC-7201 namespaces (`avana.storage.<Contract>`, named in each interface's NatSpec), call `_disableInitializers()` in the implementation constructor, and use no linked libraries (`REQ-ARCH-050`, `REQ-ARCH-053`). The ProxyManager and every PositionProxy are immutable, with no beacon, implementation slot or upgrade (`Q-306`): account logic lives in the Adapter, so a fix reaches every account through one timelocked Adapter upgrade.
- Custody trust (`REQ-ARCH-047`): the reviewed AaveAdapter implementation is trusted for custody of proxy positions, and the ProxyManager only for creating proxies at their predicted addresses; the immutable contracts (each LPVault, Collateralization, vault tokens) keep NFT custody and the backing checks. Collateralization and the LPVault read the Spoke, Hub, pool, market ID and LPOracle only from the vault token's immutables (`REQ-ARCH-048`). Immutable contracts with a privileged function check `msg.sender == TIMELOCK` instead of keeping roles.
- Vault tokens are deployed with CREATE3 salted by `keccak256(abi.encode(spoke, marketKey))` (`REQ-VTOKEN-020`); PositionProxies are deployed by the ProxyManager at CREATE2 addresses salted by `keccak256(abi.encode(wallet, spoke, marketId))` (`REQ-PROXY-001`); the immutable core is deployed at CREATE3 addresses so constructor immutables can reference each other ([`script/README.md`](script/README.md)).
- Every outer state-changing entry point acquires the Lock (`REQ-ARCH-052`); amounts are measured as before/after deltas and approvals are exact and reset to 0 (`REQ-ARCH-051`).
- Files start with `// SPDX-License-Identifier: BUSL-1.1`, `pragma solidity 0.8.28;`, a blank line and `// Copyright (c) 2026 Avana Labs` (`script/check-licence.sh`). A file containing ported third-party code carries that code's licence and is listed in `security/licence-allowlist.txt` (today `src/amm/concentrated-liquidity/ClPriceMath.sol`, GPL-2.0-or-later). An external interface written by Avana from a third party's ABI (the Aave V4 Hub, Spoke, oracle, price feed and storage read) is Avana's own code under the same licence as the rest of `src/`, declares only the members Avana code, tests and CVL specs use, and names the pinned source file its selectors, struct layouts and event signatures were checked against; an external interface taken from its origin keeps that origin's licence.

## Profiles

| Profile | Selects | Settings | Command |
|---|---|---|---|
| `default` | everything except `test/fork/**` and `test/differential/**` | fuzz 1,000 runs, fixed seed; invariant 64 runs × depth 64, `fail_on_revert = false` | `forge test` |
| `ci` | as default | fuzz 10,000 runs; invariant 10,000 runs × depth 100 (`TEST-007`) | `FOUNDRY_PROFILE=ci forge test` |
| `lite` | as default | for the edit-and-rerun loop: optimizer off outside the via-IR compilation restrictions, no contract size limit, its own `out-lite/` and `cache-lite/` so the default build stays warm; gas figures and sizes differ, so gas tests, `script/check-sizes.sh`, coverage and the gate use `default` | `FOUNDRY_PROFILE=lite forge test --match-path <suite>` |
| `invariant` | `test/invariant/**` | 2,000 runs × depth 400 for long histories (timelock delays and the 14-day grace period, the LPOracle grace latch) | `FOUNDRY_PROFILE=invariant forge test` |
| `fork` | `test/fork/**` | Ethereum and Base forks from `RPC_MAINNET` and `RPC_BASE` at the blocks pinned in `test/utils/fixtures/ForkConstants.sol`; fuzz 256 runs; RPC responses cached per block | `FOUNDRY_PROFILE=fork forge test` |
| `differential` | `test/differential/**` | FFI on, 2,000 runs against the exact `fractions.Fraction` reference in `test/differential/reference/` (`TEST-037`) | `FOUNDRY_PROFILE=differential forge test` |
| `smt` | build only | SMTChecker CHC engine on the immutable contracts (LPVault, Collateralization, VaultToken, VaultTokenFactory, ProxyManager, PositionProxy, Lock, PayoutEscrow, the AvanaTimelock extension: `PROP-043`) and on LPOracle, DebtOracle, LPVaultSwap, the RiskModule, the ParameterStore and the swap route contracts (`PROP-044`); targets assert, underflow, overflow, divByZero, constantCondition, popEmptyArray, outOfBounds, balance; contract and reentrancy invariants reported | `FOUNDRY_PROFILE=smt forge build --force` |
| `gas` | `test/gas/**` | `gas_snapshot_check = true`: values recorded with `vm.snapshotGasLastCall` or `vm.startSnapshotGas`/`vm.stopSnapshotGas` must equal the committed `snapshots/<group>.json` | `make gas-check` (CI); `make gas` rewrites the snapshots |
| `governance` | `test/governance/**` | read-write `fs_permissions` on `../governance/operations` for each operation's `before.json` and `after.json` | `FOUNDRY_PROFILE=governance forge test` |
| `coverage` | unit, fuzz, integration | optimizer and via-IR off for exact source maps; 64 fuzz runs | `FOUNDRY_PROFILE=coverage forge coverage --report lcov` |
| `aave` | Aave V4 sources only, into `out-aave/` | Aave's settings: 44,444,444 runs; `HubInstance` via-IR 22,300 runs; `SpokeInstance` via-IR 750 runs (`TEST-002`, `TEST-134`) | `FOUNDRY_PROFILE=aave forge build` |

Fuzz and invariant reasons are written next to each setting in `foundry.toml`. The `smt` profile names the planned implementation files; until they exist solc reports them as missing sources and checks nothing.

## Commands

```bash
forge build                                            # Avana sources
forge build --sizes                                    # with the 24,576-byte runtime limit check
FOUNDRY_PROFILE=aave forge build                       # Aave V4 artifacts for fixtures and scripts

forge test                                             # unit, fuzz, integration, invariant smoke
forge test --match-path 'test/unit/**'                 # one folder
forge test --match-path test/unit/LPVault.Pledge.unit.t.sol
forge test --match-test 'test_TEST_027_'               # one TEST-NNN
FOUNDRY_PROFILE=ci forge test                          # CI depth
FOUNDRY_PROFILE=invariant forge test                   # deep invariant campaign
FOUNDRY_PROFILE=fork forge test                        # reads RPC_MAINNET and RPC_BASE; blocks pinned in ForkConstants.sol
FOUNDRY_PROFILE=differential forge test

make gas                                               # rewrite snapshots/*.json from test/gas
make gas-check                                         # fail when a gas suite differs from snapshots/
script/check-sizes.sh                                  # runtime size of each src/ contract against EIP-170 minus its margin
forge fmt                                              # format (forge fmt --check in CI)
forge lint src                                         # lints on src/, external interfaces excluded
script/check-file-size.sh                              # file size limits of src/ (Q-240)

.venv/bin/halmos --root . --match-contract 'HalmosTest$' --loop 8   # symbolic tests in test/halmos
FOUNDRY_PROFILE=smt forge build --force                # SMTChecker
.venv/bin/certoraRun certora/conf/LPVault.conf         # one Certora configuration (needs CERTORAKEY)
```

PRs that change gas update `snapshots/` in the same PR (`make gas`), and a contract-size change shows in the CI job summary against `main`. Deploy commands and the release-tag rule are in [`script/README.md`](script/README.md#makefile); [`Makefile`](Makefile) wraps the build, test and deploy commands.

Test folders, naming (`test_TEST_NNN_<behavior>`, `testFuzz_TEST_NNN_<behavior>`, `invariant_TEST_NNN_<name>`, `check_PROP_NNN_<behavior>`), the complete `TEST-…` and `INV-…` map, fixtures, invariant handlers and hostile-component tests are in [`test/README.md`](test/README.md). Certora specifications and run commands are in [`certora/README.md`](certora/README.md). Deployment order, environment variables and manifests are in [`script/README.md`](script/README.md).

## Security tooling

Two tiers run every security tool on everything that exists under `src/` and on every property harness under `test/`, found through the build rather than a list of files: a contract, library or harness added later is analyzed on the next run. Each tier builds into its own directory under `out-security/` with `forge build --build-info`, so neither touches `out/` or `cache/`, and writes its reports there.

| Tier | Runner | Steps | When |
|---|---|---|---|
| Fast | `script/security-fast.sh` | `forge fmt --check`, `script/check-file-size.sh`, `forge lint -D notes`, `forge build` of `src/` with warnings denied, solhint, Slither, `slither-check-upgradeability` on every deployable `src/` contract that inherits `Initializable`, Aderyn, Semgrep with the smart-contract rules, 4naly3er, and the storage-layout check (`layout`) | every push and pull request; about ten minutes |
| Coverage | `script/check-coverage.sh` | `forge coverage --report lcov` in the `coverage` profile, then a per-file branch-coverage minimum for every `src/` file with branches, never below 80 % (`security/coverage-thresholds.json`) | every push and pull request (`coverage` job) |
| Slow | `script/security-slow.sh` | build of `src/`, `test/` and `script/` (first `forge build -D warnings` of `src/` and of each `test/` folder, a folder of more than 60 files in alphabetical chunks of 60, so no compile reaches solc's limit of 256 warnings and any warning in any file fails; then one build of all three with build info for the tools); Echidna (property and assertion mode) and Medusa on every `*Properties` harness; Halmos on `test/halmos/`; hevm on every harness assertion entry point, on the runtime code of every `src/` contract and library, and on `prove_` tests in `test/symbolic/`; Mythril on the runtime code of every `src/` contract and library | on every push to `main`, by hand and before a release |
| Layer gate | `script/security-slow.sh mutate gambit necessist` | `slither-mutate` (statement mutants) and Gambit (expression mutants, `script/security-gambit.sh`) on every implementation file of a layer, each mutant run against its Foundry tests, and Necessist on the same tests; targets in `security/mutation-layers.json` | on every push to `main` (`mutation-gate.yml`), at each layer gate (`workflow_dispatch` with the `layer` input), or locally with `MUTATE_LAYERS=2.1` |

Entry points, from `contracts/` (each runner also takes step names, for example `script/security-fast.sh slither aderyn`):

```bash
npm run security:install                  # script/install-security-tools.sh
npm run security:fast                     # script/security-fast.sh
npm run security:slow                     # script/security-slow.sh
script/security-slow.sh build echidna     # one tool after a build
ECHIDNA_TEST_LIMIT=1000000 ECHIDNA_TIMEOUT=1800 MEDUSA_TIMEOUT=1800 HEVM_SMT_TIMEOUT=600 HALMOS_LOOP=16 script/security-slow.sh   # CI slow-tier budgets
script/security-fast.sh semgrep 4naly3er layout   # the newer fast-tier steps alone (layout needs the build step's output)
script/check-coverage.sh                  # branch-coverage gate; --update raises minimums to the measured values
MUTATE_LAYERS=2.1 script/security-slow.sh mutate gambit necessist   # layer gate of 2.1
MUTATE_LAYERS=2.2 MUTATE_CONTRACTS=ClPriceMath GAMBIT_TIMEOUT=600 script/security-gambit.sh   # Gambit on one file
MUTATE_CONTRACTS=Lock MUTATE_MUTATORS=RR script/security-slow.sh mutate   # one contract, revert mutants only
ECHIDNA_HARNESSES=LockProperties script/security-slow.sh echidna          # one harness (CI runs one per job)
HALMOS_CONTRACTS=LockHalmosTest HEVM_TARGETS=src:Lock script/security-slow.sh halmos hevm   # one target each
HALMOS_CONTRACTS=LockHalmosTest HALMOS_TESTS=check_PROP_037_secondAcquireFails script/security-slow.sh halmos   # one Halmos check (CI runs one per job)
node script/storage-layout.js out-security/build/src --snapshots security/storage-layout --update   # record a reviewed layout
```

### Gates

A runner exits 1 when any step fails; every step still runs, so one run reports everything. A step fails on a tool error or on a finding at or above its gate that is not accepted in a triage file.

| Tool | Configuration | Gate |
|---|---|---|
| `forge fmt` | `foundry.toml` `[fmt]` | any formatting difference |
| File sizes | `script/check-file-size.sh` | any file over its limit (`Q-240`) |
| `forge lint` | `foundry.toml` `[lint]`: every severity; excluded lints carry their reason in place | any finding (`-D notes`) |
| solhint | `.solhint.json` (security rules plus custom errors, explicit types, imports, one contract per file, comprehensive interfaces), `.solhintignore` | any warning or error |
| Slither | `slither.config.json`; `security/slither-triage.json` | High, Medium, Low and Informational; Optimization is reported only |
| slither-check-upgradeability | `security/slither-upgradeability-triage.json` | any finding |
| Aderyn | `aderyn.toml` (excluded detectors carry their reason in place); `security/aderyn-triage.json` | High and Low |
| Semgrep | rules in `tools/semgrep-smart-contracts/solidity`; `security/semgrep-triage.json` | ERROR, WARNING and INFO rules (high, medium, low); `performance` rules are reported only; any Semgrep error (parse failure, rule timeout) fails |
| 4naly3er | `security/4naly3er-triage.json` (its `excluded_detectors` are not run; `script/4naly3er-run.js`) | H, M and L issues; NC and GAS are reported only |
| Storage layout | `security/storage-layout/<Contract>.json` (`script/storage-layout.js`); OpenZeppelin upgrades-core `validate` with `--unsafeAllow constructor,state-variable-immutable,delegatecall` | any change to the slot, offset, size or type of an existing field, a removed field, a new field overlapping an existing one, a base slot that is not `erc7201(id)` or is absent from the declaring file, two contracts disagreeing on a shared namespace, a missing or stale snapshot; any upgrades-core error |
| Branch coverage | `security/coverage-thresholds.json` (`script/coverage-gate.py`) | a `src/` file below its minimum or below the 80 % floor, a `src/` file with branches and no minimum, a minimum below the floor, an `unreachable` entry without its reason and tests, a minimum for a file without branches, any failing test |
| slither-mutate, Necessist | `security/mutation-layers.json` | report only (survivors in `out-security/mutation/<layer>/survivors.txt`, passing removals in `out-security/necessist/<layer>.txt`), reviewed at the layer gate; a tool error fails |
| Gambit | `security/mutation-layers.json` (`gambit`: seed, operators, per-file cap); `security/gambit-triage.json` | any mutant that survives its tests or runs past `GAMBIT_TIMEOUT`, unless its fingerprint is accepted with a reason; tests that fail without a mutant; a tool error |
| Echidna, Medusa | `echidna.yaml`, `medusa.json` | any failed property or reachable assertion; for Echidna also a worker crash, a run with `Total calls: 0` or a run without its summary (Echidna exits 0 in those cases) |
| Halmos | `check_` functions in `test/halmos/`, one CI job each | any counterexample; in CI also a check that has not finished within its job's 6 hours |
| hevm | harness assertion entry points, from the state the harness constructor leaves on a local anvil chain; `src/` runtime code on that chain with its address immutables filled; `test/symbolic/` | harness entry point not proven (counterexample or partial exploration); any assertion violation in `src/`; any failed `prove_` test |
| Mythril | `security/mythril.conf`; `security/mythril-triage.json` | High, Medium and Low |

`script/security-gate.py` applies the gates of Slither, slither-check-upgradeability, Aderyn, Mythril, Semgrep, 4naly3er and Gambit (a Gambit fingerprint hashes the operator, the file and the original and mutated lines). It prints each finding with a fingerprint (Slither's result ID; for the others a hash of tool, detector, file and the normalized source line, so it survives code moving within a file). A triage entry accepts one fingerprint, or every finding of one detector in matching files; the condition `no-implementation-in-folder` limits an entry to folders that hold no implementation file, so it stops applying in any folder that has one. Every entry and every detector excluded in `slither.config.json` needs a one-line reason, or the gate fails.

Rules that do not run, and why:

| Tool | Rule | Reason |
|---|---|---|
| Slither | `naming-convention` | Getters of immutables and constants keep the SCREAMING_SNAKE_CASE name of the value they expose (`HUB()`, `PROXY_HEALTH_FACTOR_FLOOR()`); naming is not a security property. |
| Slither | `unindexed-event-address` | Indexed event fields are fixed by the spec's event definitions and the indexer's topic layout. |
| Slither, Aderyn, solhint, `forge lint` | `src/interfaces/external/` | Minimal mirrors of third-party ABIs; names and layout follow the deployed contracts. |
| solhint | `not-rely-on-time` | Time-based logic is part of the design; Slither's `timestamp` detector gates each comparison. |
| solhint | `no-empty-blocks` | Aggregate interfaces (`interface IRiskModule is IRiskModuleChecks, …{}`) have empty bodies by design; Aderyn's `empty-block` checks implementations. |
| solhint | `import-path-check` | solhint does not read `remappings.txt`; `forge build` fails on any unresolved import. |
| solhint | `use-natspec`, naming, ordering and `gas-*` rules other than `gas-custom-errors` | Documentation is checked by `trace.py`, naming and ordering are style, and gas is measured by `forge snapshot`. |
| Mythril | `IntegerArithmetics` (SWC-101) | solc 0.8 reverts on overflow, and its optimizer compiles `x == c` to `SUB` + `ISZERO`, which Mythril reports as an underflow on bytecode; unchecked blocks are covered by Slither, Halmos and the `smt` profile. |
| 4naly3er | `Using \`delegatecall\` inside a loop` | Its regex nests unbounded repetitions and backtracks exponentially on files with loops (more than ten minutes on one file); Slither's `delegatecall-loop` and `msg-value-loop` check the same pattern on compiled code. |
| Medusa | arithmetic panic `0x11` | solc 0.8 reverts on overflow by design; harnesses assert their arithmetic bounds explicitly. |

### Findings accepted today

| Tool | Finding | Reason |
|---|---|---|
| Aderyn | `unused-error` on every error declared in `src/**/I*.sol` | Errors are declared in the interface next to the file of the implementation that reverts with them. The entry is limited to folders without an implementation file, so in every folder that has one each declared error is checked. |

### Tools replaced, and why

| Tool | Status | What runs instead |
|---|---|---|
| MythX | The hosted service shut down effective 31 March ([mythx.io/sunset](https://mythx.io/sunset/)); `api.mythx.io` no longer resolves. | Mythril, the open-source engine MythX ran, locally and in the nightly job. No step sends code to an external service. |
| Manticore | Archived on GitHub (`trailofbits/manticore`); last release 0.3.7 in February 2022. | hevm and Halmos for symbolic execution of harnesses and tests, Mythril for bytecode-level symbolic analysis. |
| Kontrol | Needs the K framework through `kup` and Nix. | hevm (`hevm test`, `hevm symbolic`) and Halmos prove Foundry tests and harness assertions. |

Harness conventions are in [`test/invariant/echidna/README.md`](test/invariant/echidna/README.md), [`test/invariant/medusa/README.md`](test/invariant/medusa/README.md) and [`test/symbolic/README.md`](test/symbolic/README.md).

## Traceability

[`spec/05-verification/trace.py`](../spec/05-verification/trace.py) builds the matrix requirement → check → implementation in [`traceability.md`](../spec/05-verification/traceability.md). It scans `contracts/src/**/*.sol`, `contracts/test/**/*.sol` and every file under `contracts/certora/`:

- **Solidity links.** NatSpec `/// @custom:spec <ID>, <ID>` on an interface, function, event or error links that code to the rules it implements; on an interface, a function without a body or an abstract contract that no concrete contract in `src/` inherits, the link is shown as a declaration and does not count as the rule's implementation. The tag line holds only IDs that `trace.py` recognises (`REQ-<CODE>-NNN`, `INV-NNN`, `SPEC-<AREA>-NNN`, `ATTACK-NNN`, flow steps such as `DEP-003`, `LIQ-F-002`, `WDR-POST-001`, and `Q-NNN`), and every ID must be defined in `spec/01`–`04`; other identifiers (`EXT-…`, `ROLE-…`, `TB-…`) appear in `@dev` prose.
- **Checks.** A test or property links with `<CHECK-ID> verifies: <ID>, …` in the comment block directly above the test function or CVL rule: `TEST-027 verifies: BOR-004, Q-105` above `test_TEST_027_…`, `PROP-001 verifies: INV-001` above a rule. A tag anywhere else is an error. A `TEST-NNN` tag on a test named for another row counts for nothing unless the tag line adds `; shared: <reason>`.
- **What counts.** A tagged check counts for a row only when it ran and passed in the run's results (`forge test --json-file`, Halmos logs; a CVL rule needs a prover result with a job id in `certora/RUNS.md` or a CI result file) and its test file, with the fixtures and base tests it imports, uses no stand-in for a contract whose page defines the row (the harnesses and mocks listed in `spec/05-verification/evidence.py`, `STAND_INS`: a test on `LPOracleHarness` does not count for the LPOracle, one on `AaveAdapterMock` not for the AaveAdapter). Each row is Verified, Failed, Not run or Unlinked.
- **Result.** `trace.py` fails on a duplicate ID, a tag naming an undefined ID, a tag that sits on no test, or a requirement whose text changed since its checks were accepted; `--strict` also fails on a `REQ-…`, `INV-…` or `SPEC-…` that is not Verified (with `--results`) or has no counting check, on one with only declaration Solidity links, and on a tag placed on another row's test.

```bash
cd ../spec/05-verification
.venv/bin/python trace.py            # must report 0 errors
.venv/bin/python trace.py --strict   # coverage gaps
.venv/bin/python trace.py --strict --results ../../contracts/out-results --out /tmp/traceability-run.md   # with a run
```

The `contracts` workflow runs `trace.py` on every change; its `evidence` job reads every test shard's results and runs `contract_checklist.py --all --check` and `trace.py --strict` on them, and both fail the gate while a row in scope is not verified. The `spec` workflow runs `trace.py` as part of `run_all.sh`.

## CI

[`.github/workflows/contracts.yml`](../.github/workflows/contracts.yml): `forge soldeer install` from the lock file, `forge fmt --check`, the file size check (`script/check-file-size.sh`), `forge lint src`, `forge build --sizes`, the `aave` build, the `ci` test profile with a fresh fuzz seed per run (10 shards on a pull request, 20 elsewhere, each invariant file one campaign, a campaign over 30 minutes split into run segments), the generated-ABI check, the `invariant` campaign (one job per file of `test/invariant/`), the gas snapshot check (`gas` profile), the contract-size margins (`script/check-sizes.sh`, with the change against `main` in the job summary), the `fork` profile at the blocks pinned in `test/utils/fixtures/ForkConstants.sol` (needs the `RPC_MAINNET` and `RPC_BASE` secrets and both blocks pinned; without them, or when no fork test passes, the job reports "not run" and the gate fails) including hostile tests on the fork, the `differential` profile, the branch-coverage gate (`script/check-coverage.sh`), the `smt` profile (one job per contract of `[profile.smt.model_checker]`; fails on any counterexample), Certora (one job per `certora/conf/*.conf`, six at a time; needs the `CERTORAKEY` secret, without which each job reports "not run" and fails), the traceability check, the `evidence` job (every contract's checklist and `trace.py --strict` on the shards' results), and the `fast-security` job (`script/security-fast.sh`, with Slither, Aderyn and Semgrep SARIF uploaded to code scanning). Every pull request runs the short set in about 10 minutes (build, the test shards with the invariant suites as a short check, gas, the generated-ABI check, coverage, traceability, evidence and `fast-security`); a pull request labelled `hotfix` also runs the touched contracts' invariants at full depth, one per job. Every push to `main` runs the same set at full test depth. The long checks (the `invariant` campaign, `fork`, `differential`, `smt` and Certora) run every night on `main` at 06:00 UTC, on every release tag and by hand. The `gate` job passes only when every job and every matrix leg that ran passed, and in those runs only when all of them ran; a long check that could not run (a missing secret, an unpinned fork block, every fork test skipped) counts as not run and fails it. A `plan` job lists the targets of the matrix jobs with [`script/ci-shards.py`](script/ci-shards.py), so a new file, contract or conf gets its own job on the next run, and every job is bounded at 4 hours. The same nightly, release-tag and manual runs start [`security-slow.yml`](../.github/workflows/security-slow.yml) and [`mutation-gate.yml`](../.github/workflows/mutation-gate.yml); pull requests and pushes do not run these two. `security-slow.yml` builds once (`script/security-slow.sh build` and the build Halmos runs), then runs each target in its own job on that build with the slow-tier budgets: one job per Echidna harness (property and assertion mode, 30 minutes each), one per Medusa harness (30 minutes), one per Halmos `check_` function (loop 16, with `FOUNDRY_DYNAMIC_TEST_LINKING=false`, up to 6 hours each, since Halmos runs a contract's checks one after another with no time bound of its own; the properties' 10,000-run fuzz twins run on every pull request), one per hevm target (a harness's assertion entry points or one `src/` contract) and one per group of eight `src/` contracts for Mythril; the Echidna and Medusa corpora are kept per harness between runs, and `slow-gate` passes only when every job passed. By hand, its `campaign` input runs the 24-hour pre-audit campaign of one layer instead: eight 3-hour jobs per harness and mode with fresh seeds, whose corpora are then merged and kept. `mutation-gate.yml` runs `slither-mutate` per contract and mutator group, Gambit per contract, Necessist per test file and `certoraMutate` per Certora conf (needs the `CERTORAKEY` secret; without it each job reports "not run" and fails); `mutation-summary` passes only when every job passed. [`.github/workflows/spec.yml`](../.github/workflows/spec.yml) runs `spec/05-verification/run_all.sh` one part per job in parallel: the `trace` part (the licence check, `trace.py` and the `traceability.md` freshness check) on every run, and each Z3 folder, SymPy, the simulations, Hypothesis and Quint (4 hours each at most) only on pushes to `main` and manual runs, never on a pull request; `spec-gate` passes only when every part that ran passed, and on `main` only when every part ran. Every action in the workflows is pinned by commit SHA with its release in a trailing comment, and checkouts keep no credentials (`persist-credentials: false`); dependency versions change only by a reviewed pull request (Dependabot is off), and [`.github/workflows/dependency-review.yml`](../.github/workflows/dependency-review.yml) fails a pull request that adds a dependency with a known vulnerability of moderate severity or above.

## Licence

Avana's code in this workspace is licensed under the Business Source License 1.1 in the root [`LICENSE`](../LICENSE): Licensor Avana Labs, no Additional Use Grant, Change License MIT, Change Date the earlier of three years after Avana's official Ethereum mainnet launch and four years after the first public distribution of the version. Every Avana-owned `.sol` file under `src/`, `test/`, `script/`, `certora/` and `aave-deploy/` starts with `// SPDX-License-Identifier: BUSL-1.1` and `// Copyright (c) 2026 Avana Labs`, and `script/check-licence.sh` (pre-commit, the `build` and `fast-security` jobs) fails on a missing header or any `UNLICENSED` identifier.

Files under another licence:

| Files | Licence | Why |
|---|---|---|
| `src/amm/concentrated-liquidity/ClPriceMath.sol` (listed in `security/licence-allowlist.txt`) | GPL-2.0-or-later | contains code ported from Uniswap v3-core `TickMath` and `Tick` and v3-periphery `LiquidityAmounts` and `OracleLibrary`; compiled into the Uniswap v3 and Slipstream LPVaults through `ClLPVaultBase.sol` and `ClLPVaultMarkets.sol` |
| `test/differential/reference/avana_reference.py` | GPL-2.0-or-later | Python port of the same Uniswap v3 math, the reference of the differential tests |
| `src/interfaces/external/uniswap/*.sol`, `src/interfaces/external/aerodrome/*.sol` | GPL-2.0-or-later | interface subsets copied from Uniswap v3 and Aerodrome Slipstream |
| `src/interfaces/external/aave/IAaveV3ACLManager.sol` | AGPL-3.0 | copied from Aave V3 core |
| `src/interfaces/external/sky/*.sol` | AGPL-3.0-or-later | copied from Sky (`usds`, `dss-lite-psm`) |
| `src/interfaces/external/aave/IAaveV3Pool.sol`, `IAaveV3PoolAddressesProvider.sol`, `IAaveV3FlashLoanReceiver.sol`, `src/interfaces/external/chainlink/*.sol`, `src/interfaces/external/gho/*.sol` | MIT | copied from Aave V3 origin, Chainlink and gho-core |

The Aave V4, Curve and Tether interfaces in `src/interfaces/external/` are written by Avana from the deployed ABIs and carry BUSL-1.1. Dependencies in `dependencies/` keep their own licences and are not committed. The full list, with versions and notices, is in [`LICENSING.md`](../LICENSING.md) and [`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md).
