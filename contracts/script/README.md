# script

Foundry deployment, listing and verification scripts for Avana. Every script is a `forge script` run from `contracts/`, reads its inputs from a release manifest under [`deployments/`](../../deployments/) and environment variables, and writes what it deployed to `contracts/deployments-local/`. Scripts never write into `deployments/proposed/` or `deployments/verified/`: a manifest enters `proposed/` by review and enters `verified/` only after the bytecode and live-configuration checks below pass (`Q-043`, `TEST-134`, `TEST-135`).


## Scripts

| File | Runs on | Does |
|---|---|---|
| `deploy/00_Factories.s.sol` | every chain | Installs the Safe Singleton Factory (`0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7`, CREATE2) with the node's `setCode` RPC on anvil (Ethereum, Base, Sepolia and Base Sepolia have it), then CREATE2-deploys `deploy/AvanaCreate3Factory.sol` through it with salt 0, so the factory has one address on every chain. Skips what exists. |
| `deploy/01_DeployAaveV4.s.sol` | anvil, Sepolia | Avana's own Aave V4 for test networks (`Q-074`, `TEST-002`), following Aave's deploy orchestration with the batch contracts of `out-aave/`: `LiquidationLogic` at its CREATE2 address (linked into `SpokeInstance` by replacing its placeholder), the AccessManager, the configurators, the TreasurySpoke, every Hub of the config's `aaveLocal.hubs` with its interest-rate strategy and every Spoke of `aaveLocal.spokes` (CDP Spokes per AMM protocol and risk tier, Lend Spokes) with its AaveOracle. Aave's role procedures run unchanged by `delegatecall` from `deploy/local/AaveV4Bootstrap.sol`, which hands the AccessManager admin to the network's Aave DAO account at the end. Refuses Ethereum and Base. |
| `deploy/02_DeployWorld.s.sol` | anvil, Sepolia | The third-party world: test tokens of 6, 8 and 18 decimals, four Chainlink OCR2 feeds per token (primary, alternate and standby routes, and the second source) behind `EACAggregatorProxy` (`chainlink-ocr2` and `chainlink-proxy` builds), Uniswap v3 (factory, position manager, router from the `univ3` build), with `world.uniswapV4Pools` Uniswap v4 (Permit2 from the `permit2` build; PoolManager, PositionManager and StateView from the `univ4` build; `TestWETH9` as the PositionManager's WETH9) and its hookless pools, Aerodrome and Slipstream (Voter and gauges from the `aerodrome` build, four position-manager generations from the `slipstream-v1` and `slipstream-main` builds), an Aave V3 market from the `aave-v3` build (libraries linked into the Pool, every token listed with its primary feed as `AaveOracle` source, flash loans enabled and `world.aaveV3SupplyUsd` dollars supplied), and every pool of the config, created at the feeds' price with full-range liquidity. Stand-ins are listed in [`deployments/README.md`](../../deployments/README.md). |
| `deploy/03_DeployAvana.s.sol` | every chain | Avana's AccessManager and one core stack per integration of the config (LPVault, RiskModule, LiquidationModule, AaveAdapter; with an Aave V3 Pool, FlashloanRepay and one operator FlashLiquidator per `operatorHelpers` entry from `liquidator/out/`), each CREATE3 in the deployer's namespace. Then every role (below) and the admin handed to the DAO (the Aave governance executor). Writes `deployments-local/<network>/avana.json`. |
| `deploy/05_ExecuteOperations.s.sol` | every chain | Executes the ready calls of the AccessManager operations named in `AVANA_OPERATIONS`, as the Safe that scheduled them; reports a call that is not ready with its ready time. |
| `deploy/06_AaveDeploymentPayload.s.sol` | every chain (AAVE side) | The deployment AIPs, each an Aave V4 payload on Aave's config engine run by the governance executor (`executeTransaction(payload, 0, "execute()", "", true)`): the debt assets on each Hub, the Lend and CDP Spokes and their reserves (CDP debt reserves not borrowable yet), the CDP liquidation configuration, the Guardian role, the bootstrap supply (test networks) and `FLASH_BORROWER` for the operator FlashLiquidators. |
| `deploy/07_DeployFirstLossReserves.s.sol` | every chain | `AVANA_COVERAGE_STEP=deploy`: Avana's First-Loss Reserve and the DAO Deficit Offset behind it for each covered (Hub, debt asset) of `aavePayload`, governed by the Aave AccessManager; writes `coverage.json`. `fund`: Avana Labs tops its reserves up to their minimums. |
| `deploy/08_AaveLossLayersPayload.s.sol` | every chain (AAVE side) | The `AvanaLossLayers` AIP: each layer on its Hub asset with `HUB_DEFICIT_ELIMINATOR_ROLE`, its functions mapped to the coverage, reserve-admin and withdraw roles (`withdraw` held with the reserve's 14-day `WITHDRAWAL_DELAY`), the CDP Spokes allowed and the minimums set. Calls written to `aip-AvanaLossLayers.json`; run through the executor stand-in on test networks. |
| `deploy/09_ListMarkets.s.sol` | every chain | `AVANA_LISTING_STEP`: `setup` (CDP Spokes, debt reserves with their First-Loss Reserves, fee, coverage ratio, keepers), `markets` (`listPool`: each pool as a Full range and a Custom range market), `vault-tokens` (each market's VaultToken and LPOracle, their roles sent by the DAO; writes `markets.json`), `activate` (`activateMarket`). Governance operations are written for the Safe and scheduled on anvil. |
| `deploy/10_AaveListingPayload.s.sol` | every chain (AAVE side) | The `AvanaMarkets` AIP: each AaveAdapter a position manager on its CDP Spokes, the debt reserves borrowable, and each vault token a Hub asset and a CDP Spoke collateral reserve priced by its LPOracle (collateral factor the market's LTV, liquidation fee 0, no draw, no share transfers). |
| `deploy/11_FundKeepers.s.sol` | every chain | The keeper top-up wallet (`KEEPER_TOPUP_WALLET`, else the config's `keeperTopUp.wallet`) refills each keeper signer (`keepers` and each operator helper's `signer`) below `keeperTopUp.minBalanceWei` to `keeperTopUp.targetBalanceWei`, one transfer each, signed by the wallet. Safe to rerun; see [Keeper gas](#keeper-gas). |
| `deploy/step.sh` (`make step-<name>`) | every chain | Runs one named step of the deployment recipe with its environment and sender; the list of steps, in order, is at the top of the file. The rehearsal calls the same names. Every step is incremental: it reads the chain and acts only on what the config adds (a Hub, a Spoke, an asset, a market, a route), and with nothing new it schedules, proposes and deploys nothing, so running a step again is safe. `AVANA_CONFIG` (a path from `contracts/`) points every step at another config file. |
| `deploy/aave/AvanaAaveV4Payload.sol`, `deploy/lib/AavePayloads.sol` | — | The one payload contract every Avana AIP deploys (an `AaveV4Payload` whose actions are ABI-encoded data in SSTORE2 chunks, with plain `_postExecute` calls from the executor) and the builder that ships it. |
| `deploy/lib/` | — | `DeployInputs` (network config with `$<file>:<path>` references to earlier outputs), `DeployBase` (artifact loading per compiler profile, CREATE and namespaced CREATE3), `CoreRecord` (reads `avana.json` and `coverage.json` back), `AvanaAccess` (roles, delays and the map of every restricted function to its role), `AccessOperations` (AccessManager operations for the Safe), `AaveCalls` and `AavePayloads` (Aave-side AIPs), `DeploymentOutput`. |
| `deploy/config/<network>.json` | — | Every input of a network: governance accounts, Aave addresses or references, chain constants, initial parameters, keepers, operator helpers, the keeper top-up wallet and its refill band (`keeperTopUp`: `wallet`, `minBalanceWei`, `targetBalanceWei`; required off anvil), AMM integrations, and on test networks the Aave V4 layout, the world (tokens, prices, pools) and the Aave payload. No secret. |
| `e2e/e2e-local.sh`, `e2e/day2-additions.ts`, `e2e/services-smoke.sh`, `e2e/scenarios/run.ts` | local and CI (`e2e-local.yml`) | The local rehearsal: anvil, steps 00–10 through market activation, then a day-2 pass (`e2e/day2-additions.ts` adds a Hub with its Lend and CDP Spokes, a lend-only asset, a borrowable asset on a listed Spoke with routes for its market, a collateral token and two markets; every step runs again with `AVANA_CONFIG` on that config) and a pass that runs every step once more and fails if any acts (each timelock wait followed by a fresh round on every feed, `e2e/refresh-feeds.ts`; `E2E_RESUME=<step>` reruns from a step on the saved chain), the release manifest produced and verified (`packages/protocol`, `npm run manifest`), the keeper, the indexer and a local Convex deployment on that manifest (`e2e/convex-check.ts`: every listed market and debt reserve has its page with data and its listing text), the scenarios; each step pass, fail or not-run in `deployments-local/anvil/e2e-status.json`. |
| `check-ai-credit.sh`, `check-ai-credit.test.sh` | the `commit-msg` hook (`lefthook.yml`) and CI (`commit-messages.yml`, every pull request); the test in CI (`contracts.yml` scripts job) | Fails on an AI credit in a commit message or pull request text: an AI co-author trailer, the AI vendor's noreply address, or a "Generated with" line naming an AI tool. CI checks only the pull request's own commits (base..head), so commits already on main are not checked. |
| `check-file-size.sh` | CI and local | Fails when an implementation file in `src/` exceeds 500 lines of code or an interface file exceeds 300 lines (`Q-240`); see [File layout and size limits](../README.md#file-layout-and-size-limits). |
| `install-security-tools.sh` | local and CI | Installs the pinned security tools: Echidna, Medusa, Aderyn, hevm and the Bitwuzla solver (for the Halmos checks annotated `--solver bitwuzla`) from their GitHub releases into `tools/bin/` (each checked against its sha256), Slither, Semgrep and the other Python tools into `.venv` and Mythril into `.venv-mythril` with uv and an upload-date cutoff, solhint and `@openzeppelin/upgrades-core` with `npm ci --ignore-scripts`, the Semgrep smart-contract rules and 4naly3er as git checkouts of pinned commits (`--rules`, `--4naly3er`), Necessist with `cargo install --locked` (`--necessist`), and a link `tools/bin/gambit` to the Gambit binary of the pinned certora-cli wheel (`--gambit`, after `--python`). |
| `security-fast.sh` | local and CI (every push and pull request) | Fast security tier: formatting, file sizes, `forge lint`, a warning-free build, solhint, Slither, `slither-check-upgradeability`, Aderyn, Semgrep, 4naly3er and the storage-layout check; see [Security tooling](../README.md#security-tooling). |
| `test-shard.sh`, `test-shard.py`, `update-test-timings.py`, `hotfix-units.py` | local and CI (`test` and `hotfix` jobs) | Runs shard K of N of the Foundry suite (fork and differential excluded): units balanced by the measured CPU time in `test-timings.json`, each in exactly one shard. A file of `test/invariant/` is one unit, since Foundry runs all invariants of a contract in one campaign; a campaign over 20 minutes is split into segments `<file>@<k>/<m>` that each run `ceil(runs / m)` of its runs at the same depth with a seed of their own. `--list K N` prints a shard's units, `--unit U` runs one (the `hotfix` jobs, listed by `hotfix-units.py`), `test-shard.py --summary N` prints the estimated seconds per shard, and `update-test-timings.py <log>...` refreshes the times from the shard logs of a run on `main` (a segmented campaign weighs the mean of its finished segments times its segment count). With `TEST_RESULTS_DIR` set, each forge invocation also writes its results (`--json-file`) there; the `evidence` job reads them. |
| `upgrade-operation.py`, `upgrade/UpgradeOperation.s.sol`, `upgrade-operation.test.sh` | local (the governance Safe's signers); the test in CI (`contracts.yml` scripts job) | `TEST-263`: builds the AvanaTimelock `schedule` and `execute` calldata of `proxy.upgradeToAndCall(implementation, initData)` for a named proxy and implementation, at the normal delay (an upgrade is never short), and writes it to `deployments-local/upgrades/`. Before it outputs anything it refuses unless `security-slow.yml` has a completed successful slow-tier run on the implementation's source commit (`gh api .../security-slow.yml/runs?head_sha=<sha>&status=success`, then that run's `slow-gate` and at least one tool job passed and no campaign job ran); the run id is recorded in the output. `upgrade-operation.test.sh` checks the refusals and the pass path with stand-ins for `gh` and `forge`. |
| `halmos-outcome.py` | called by `security-slow.sh halmos` | The outcome of a Halmos run: `pass`, or `fail` (any counterexample, `[ERROR]`, build failure or memory-cap kill, or a check that its budget or a solver timeout ended before it completed), written to `out-security/halmos-outcome.json` and the CI job summary; `check` fails unless `security/halmos-bounds.json` lists no check. |
| `forge-results.py` | CI (`fork` job) | Counts passed, skipped and failed tests in `forge test --json-file` output; the fork job reports "not run" when no fork test passed. |
| `security-slow.sh` | local and CI (by hand: `security-slow.yml` for the tools, `mutation-gate.yml` for `mutate`, `gambit` and `necessist`) | Slow security tier: Echidna, Medusa, Halmos, hevm and Mythril; layer-gate steps `mutate` (slither-mutate's mutants through `mutation-slither.py`), `gambit` and `necessist`, all three built in the `mutation` profile of `foundry.toml`. Selectors limit a step to some targets, as each CI job does: `ECHIDNA_HARNESSES`, `ECHIDNA_MODES`, `MEDUSA_HARNESSES`, `HALMOS_CONTRACTS`, `HALMOS_TESTS`, `HEVM_TARGETS` (`harness:<Name>`, `src:<Name>`, `test`), `MYTHRIL_CONTRACTS`, `MUTATE_LAYERS`, `MUTATE_CONTRACTS`, `MUTATE_MUTATORS`, `MUTATE_SHARD` (`k/n`), `NECESSIST_TESTS`; a selected target that does not exist fails the step, and without selectors every target runs. |
| `ci-shards.py` | CI (`plan` jobs of `contracts.yml`, `security-slow.yml` and `mutation-gate.yml`) | Lists the targets of each long-running check as a JSON matrix, one job per target: Certora confs, Halmos test functions (one per `check_`), invariant files, SMTChecker contracts (and `smt-only`, which narrows `[profile.smt.model_checker]` to one contract), Echidna, Medusa and hevm targets and Mythril groups from the slow-tier build, slither-mutate shards of at most 40 mutants per contract (dealt over three matrices, from the counts `mutation-slither.py list` wrote), Gambit targets per contract and Necessist targets per test file (leaving out targets current in the ledger), and the harnesses of a layer's pre-audit campaign. A list above GitHub's 256 legs per matrix fails. |
| `security-gambit.sh` | called by `security-slow.sh gambit`; local and CI layer gate | Gambit expression mutants of each layer's implementation files (fixed seed, operators and per-file cap from the `gambit` object of `security/mutation-layers.json`), each run against the file's Foundry tests by `mutation-test.py` with a per-mutant timeout for compile and tests together (`GAMBIT_TIMEOUT`, 600 seconds) in an isolated copy under `out-security/gambit/root`; survivors in `out-security/gambit/<layer>/survivors.txt`; fails on any survived or timed-out mutant not accepted in `security/gambit-triage.json`. |
| `check-coverage.sh`, `coverage-gate.py` | local and CI (every push and pull request) | `forge coverage --report lcov` in the `coverage` profile and the per-file branch-coverage minimums of `security/coverage-thresholds.json`, none below its `floor` of 80 %; a branch leaves a file's count only through its `unreachable` entries, each with function, branch, reason and tests. |
| `storage-layout.js` | called by `security-fast.sh layout` | Storage-layout snapshots in `security/storage-layout/` of every upgradeable `src/` contract and every contract sharing its ERC-7201 namespace; fails on any change to an existing slot. |
| `4naly3er-run.js` | called by `security-fast.sh 4naly3er` | Runs 4naly3er without the issues excluded in `security/4naly3er-triage.json`. |
| `mutation-targets.py` | called by `security-slow.sh mutate necessist` and `security-gambit.sh` | Implementation files and test files of each layer in `security/mutation-layers.json`, and the Gambit settings of each file (`gambit`). |
| `mutation-records.py`, `mutation-records.test.sh` | called by `security-slow.sh necessist` and `mutation-report.py`; the test in CI (`contracts.yml` scripts job) | Reads each uncaught slither-mutate mutant and each Necessist removal that left the tests passing from a tool log, a mutant or statement that spans several lines kept whole. The test also checks `mutation-report.py` (a timed-out mutant is its own outcome, never killed) and the outcomes of `mutation-test.py`. |
| `mutation-test.py` | called by `mutation-slither.py` and `security-gambit.sh` | Runs a target's tests on one mutant: `forge test --fail-fast --match-path <tests>` in the `mutation` profile (no optimizer, via-IR only where needed; compiles `src/` and the matched tests only), then, for a survivor, the tests of the release build's gas that profile leaves out, in the default profile; outcome `killed`, `survived`, `timeout` (never counted as killed) or `invalid`. |
| `mutation-slither.py` | CI (`mutants` job of `mutation-gate.yml`); called by `security-slow.sh mutate` | `list`: one Slither run over the project writes every mutant of slither-mutate's mutators (`ci-shards.py` `SLITHER_MUTATORS`; the operator mutators are Gambit's) for each target, in a fixed order. `run`: tests one shard of a target's list (`--shard k --shards n`) with `mutation-test.py`, without Slither; reports `shard-<k>.tsv`, `shard-<k>.json` and `shard-<k>.log`. |
| `mutation-ledger.py`, `mutation-ledger.test.sh` | CI (`plan` and `ledger` jobs of `mutation-gate.yml`); the test in CI (`contracts.yml` scripts job) | Keys every mutation target by its file, its tests and everything they import, keeps the passed reports per key (the `mutation-ledger-*` cache), and lists the targets a `changed_only` run can skip. |
| `security-mythril.sh` | called by `security-slow.sh` | Mythril on the runtime code of every `src/` contract and library (or of those named in `MYTHRIL_CONTRACTS`), settings from `security/mythril.conf`. |
| `security-gate.py`, `security-gate.test.sh` | called by the security runners; the test in CI (`contracts.yml` scripts job) | Severity gate and triage for Slither, `slither-check-upgradeability`, Aderyn, Mythril, Semgrep and 4naly3er reports, and for Gambit survivors. An accepted entry's `reviewedFiles` hashes are checked: a reviewed file that changed since the review is reported as "review reopened" (a warning, not a failure). |
| `security-targets.py`, `security-list-upgradeable.py` | called by the security runners | Find harnesses, assertion entry points, creation and runtime code (address immutables filled as a constructor fills them, for Mythril and hevm) and upgradeable contracts in the build, so no runner keeps a list of files. |
| `hevm-batches.py`, `hevm-timings.json` | CI (`security-slow.yml` plan job) | Groups the hevm targets of the slow tier into `HEVM_BATCHES` jobs of about equal time, heaviest first, by the per-target seconds in `hevm-timings.json` (job times of run 43677588077, capped at 7,200 s); a target with no entry weighs the median |

## Deployment order

The core is not upgradeable and holds no admin key: every restricted function is gated by Avana's OpenZeppelin AccessManager, one per chain. Contracts reference one another through constructor immutables, so they are deployed in this order by `03_DeployAvana`, each with CREATE3 in the deployer's namespace (`deploy/AvanaCreate3Factory.sol`, effective salt `keccak256(abi.encode(msg.sender, salt))`, salt `keccak256("avana.<release>.<name>")`):

| Order | Contract | Name | Constructor |
|---|---|---|---|
| 1 | AccessManager | `AccessManager` | initial admin: the deployer, until the roles are set |
| 2 | LPVault of integration `i` (`UniswapV3Integration`, `SlipstreamIntegration`, `UniswapV4Integration`) | `I<i>.LPVault` | the manager and the AMM's position managers and factories |
| 3 | RiskModule | `I<i>.RiskModule` | the manager, the LPVault and the LiquidationModule's predicted address (its constructor checks `RiskModule.LIQUIDATION_MODULE() == this`) |
| 4 | LiquidationModule | `I<i>.LiquidationModule` | the RiskModule |
| 5 | AaveAdapter | `I<i>.AaveAdapter` | the RiskModule |
| 6 | FlashloanRepay, operator FlashLiquidators | `I<i>.FlashloanRepay`, `I<i>.FlashLiquidator.<k>` | the adapter or module and the Aave V3 Pool |

The RiskModule's `LP_VAULT` is immutable, so each integration has its own stack. Roles (`deploy/lib/AvanaAccess.sol`):

- Core roles, one set per integration (`100 · i + kind`), held with no delay: the RiskModule on `LPVault.listMarket`; the AaveAdapter on the LPVault's `pledge`, `addLiquidity`, `removeLiquidity`, `release`, `collectFees` and on each vault token's `mint` and `addValidProxy`; the LiquidationModule on `LPVault.unwind`; the burn role (each vault token's `burn`) held by both the adapter and the module.
- The RiskModule's setters: removals take the tighten role (the Safe at 12 hours, the risk steward at once), every other setter, listing and activation the governance role (the Safe at 4 to 5 days).
- The admin role: the DAO (Aave governance executor), guardian of every role; the deployer renounces it in the same run.
- First-Loss Reserves are governed by the Aave AccessManager (`08_AaveLossLayersPayload`): `withdraw` takes the withdraw role, held with the reserve's 14-day `WITHDRAWAL_DELAY`.

On mainnet Aave V4 is the Aave DAO's deployment; the config names its Hubs, CDP Spokes, configurators and AccessManager, and the Aave-side steps (06, 08, 10) only write the AIP's calls.

## Listing a market

Every listed pool gets two ERC-20 markets with the same LTV (the lower of the two tokens' `collateralFactorBps`, or the market's `eModeLtvBps` for a correlated pair on a Correlated Spoke) and a band fixed for life: Full range (the pool's lowest and highest usable ticks) and Custom range (the Spoke kind's width around the Chainlink listing price: Stable ±1%, Correlated ±5%, Volatile 0.345x to 2.898x). `RiskModule.routeOf` sends exact full-range ticks to Full and ticks inside the Custom band to Custom.

1. `09-listing-setup`, executed after the governance delay: CDP Spokes, debt reserves, fee, coverage ratio, keepers.
2. `09-listing-markets`, executed after the governance delay: `listPool` for each new pool (the listing tick is read at scheduling time; the RiskModule checks again at execution that the Chainlink price lies in the Custom band).
3. `09-vault-tokens`: each market's VaultToken (decimals the RiskModule chose) and LPOracle (the same feeds), and their roles, sent by the DAO at once.
4. `10-aave-markets-aip`: Aave lists each vault token with its LPOracle as price source.
5. `09-listing-activate`, executed after the governance delay: `activateMarket` checks the vault token and the Aave reserve against the listing.

`test/integration/DeployScripts.integration.t.sol` runs every step in this order on the real local Aave V4 and real Uniswap v3 pools.

## Keeper gas

The keeper signers (the config's `keepers` and each operator helper's `signer`) pay their own gas. The **keeper top-up wallet** holds the chain's keeper gas and refills them: `11-fund-keepers` sends each signer below `keeperTopUp.minBalanceWei` back up to `keeperTopUp.targetBalanceWei`, one transfer each, signed by the wallet. It is the rule the removed AvanaGasVault applied, without the contract: run it after `09-execute-listing-activate`, then whenever a signer runs low (a signer at or above its minimum gets nothing). The wallet is required on test networks and mainnet (`KEEPER_TOPUP_WALLET` or `keeperTopUp.wallet`); it signs from its encrypted Foundry keystore (one of `AVANA_KEYSTORE_PATHS`, or `AVANA_SIGNER_FLAGS="--account <topup> --sender 0x…"`), never from a key in the environment. On test networks `script/testnet/testnet.ts` names it from the private config's `KEEPER_TOPUP_WALLET` keystore and sets the band (`KEEPER_TOP_UP`).

### Deploy gas per step

Measured by `test/integration/DeployScripts.integration.t.sol` (`forge test -j 2 --match-path test/integration/DeployScripts.integration.t.sol -vv` logs `gas <step>`): one integration (Uniswap v3), one Hub, one debt asset, two pools listed as four markets. Each figure is the step's execution gas plus, per broadcast transaction, the intrinsic 21,000 gas and its calldata; it is an upper bound, since it includes the script's own config reads. Prices: Sepolia **1.0 gwei** (base fee 14 to 19 wei and a 1 gwei median priority fee over the 1,024 blocks from 12,171,329, `eth_feeHistory` on a public Sepolia RPC, 2026-11-19); Base Sepolia **0.0072 gwei** (base fee 0.005 gwei, flat over the 1,024 blocks from 61,091,274, plus the 90th-percentile tip 0.0022 gwei, same day). Base Sepolia's L1 data fee is left out of the rows: its `GasPriceOracle` (`0x4200…000F`) quoted `getL1FeeUpperBound(1000)` = 786 wei per 1,000 bytes that day (L1 base fee 14 wei), under 0.000000002 ETH for the whole deploy's calldata.

| Step | Transactions | Gas | Sepolia ETH | Base Sepolia ETH |
|---|---:|---:|---:|---:|
| `00-factories` | 1 | 272,029 | 0.00027 | 0.0000020 |
| `03-avana` | 28 | 21,921,513 | 0.02192 | 0.0001578 |
| `07-deploy-first-loss-reserves` | 2 | 6,559,402 | 0.00656 | 0.0000472 |
| `08-aave-loss-layers-aip` | 17 | 5,708,509 | 0.00571 | 0.0000411 |
| `07-fund-first-loss-reserves` | 3 | 792,587 | 0.00079 | 0.0000057 |
| `09-listing-setup` | 1 | 3,669,510 | 0.00367 | 0.0000264 |
| `09-execute-listing-setup` (05) | 5 | 671,127 | 0.00067 | 0.0000048 |
| `09-listing-markets` | 1 | 2,013,697 | 0.00201 | 0.0000145 |
| `09-execute-listing-markets` (05) | 2 | 1,159,637 | 0.00116 | 0.0000083 |
| `09-vault-tokens` | 9 | 14,875,390 | 0.01488 | 0.0001071 |
| `10-aave-markets-aip` | 14 | 6,703,671 | 0.00670 | 0.0000483 |
| `09-listing-activate` | 1 | 749,559 | 0.00075 | 0.0000054 |
| `09-execute-listing-activate` (05) | 4 | 885,347 | 0.00089 | 0.0000064 |
| `11-fund-keepers` | 1 | 133,299 | 0.00013 | 0.0000010 |
| **Total** | **89** | **66,115,277** | **0.0661** | **0.00048** |

The steps grow with the listing: `03-avana` by about 22M gas per integration, and each pool (two markets) adds about 13.2M across `09-listing-markets`, `09-vault-tokens`, `10-aave-markets-aip`, `09-listing-activate` and their executions. The test networks' first release (three integrations; Sepolia's Hub files list 10 pools, 20 markets, Base Sepolia's 12 pools, 24 markets) therefore takes about **216M gas on Sepolia (0.22 ETH at 1 gwei)** and **242M gas on Base Sepolia (0.0017 ETH at 0.0072 gwei)** for steps 03 to 11. Steps 01 and 02 (Avana's own Aave V4 and the test world) are not counted. Keep three times that on the deployer for fee spikes: 0.65 ETH on Sepolia, 0.006 ETH on Base Sepolia.

### Keeper spend per day and the top-up wallet

Since the refactor the keepers send only liquidations. The oracles are stateless (no pokes), there is no pending settlement, bands are fixed at listing, and a depeg is an alert the risk steward answers with a freeze from its Safe, so the band and depeg monitors send nothing. The wallet's own refills are one 21,000-gas transfer per signer at most once a day.

| Item | Gas | Basis |
|---|---:|---|
| One liquidation | 1,300,000 | about 1M for `LiquidationModule.liquidate` and the NFT unwind (LiquidationModule DESIGN.md), plus the flash path's Aave V3 flash loan and two SwapRouter02 swaps |
| Daily spend `D` per signer (test network) | 13,000,000 | 10 liquidations a day from the scenarios and price moves; one signer per network (`KEEPER` is both the keeper and the operator helper signer) |
| Burst `B` | 65,000,000 at twice the price | 50 liquidations: every account the stress shock makes liquidatable on a 20 to 24 market test world |
| Wallet refill | 21,000 | one transfer per signer per refill |

The band follows the AvanaGasVault's rule: `minBalanceWei` = 3 `D`, `targetBalanceWei` = 7 `D` + `B`, and the wallet holds a first fill to the target plus 30 days of `D` and one `B`.

| Network | `D` per day | `minBalanceWei` | `targetBalanceWei` | Wallet need | **Recommended `KEEPER_TOPUP_WALLET` balance** |
|---|---:|---:|---:|---:|---:|
| Sepolia (1.0 gwei) | 0.013 ETH | 0.04 ETH | 0.25 ETH | 0.77 ETH | **1.0 ETH** |
| Base Sepolia (0.0072 gwei; L1 data about 500 wei a transaction) | 0.000094 ETH | 0.0005 ETH | 0.002 ETH | 0.0058 ETH | **0.01 ETH** |

The headroom (about 30% on Sepolia, 70% on Base Sepolia) covers a priority fee above 1 gwei or a busier test day. Re-derive `D` and the band before a listing that adds markets, from the keepers' measured spend once it exists, and on mainnet from the chain's own gas price; the anvil config uses 3 and 10 ETH.


## Verification before `deployments/verified/`

`07_VerifyDeployment` and the `test/fork/deployment/` tests check, against the manifest named by `AVANA_MANIFEST`:

- **Bytecode** (`TEST-134`): the runtime code of each Avana contract and UUPS implementation equals the release build in `out/` with immutable positions masked (positions from the artifact's `immutableReferences`), and each immutable equals the manifest value; Aave V4 contracts equal the `out-aave/` build of `a3ef63e`. `bytecode_hash = "none"` keeps the comparison independent of metadata.
- **Live configuration** (`TEST-135`): the reserve flags, Hub assets and caps, collateral factors, CDP Spoke standard implementation and the three required settings (`receiveSharesEnabled = false`, `liquidationFee = 0`, no reinvestment controller), borrowable reserves equal to the enabled debt reserves, each First-Loss Reserve covering its summed draw caps (`drawCapCoverage`), `FLASH_BORROWER`, the role snapshot of the timelock and every upgradeable contract, every ERC-1967 implementation slot, keeper count and parameter bounds listed in [`deployments/README.md`](../../deployments/README.md).

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
| `AVANA_RELEASE` | `03`, `04`, `09` | Release tag used in salts and output file names, default the config's `release`. Checked on every run (see [Releases and tags](#releases-and-tags)) |
| `AVANA_RELEASE_RECORD` | `03` | Path from `contracts/` of the release workflow's `release.json` for this tag, default `deployments-local/<network>/release.json` when present; `03` refuses to deploy unless its release, commit, CREATE3 factory, salts and (for this deployer) addresses match |
| `AVANA_OPERATION_GAS_BUDGET` | `09` (`markets`) | Execution gas budget of each listing operation; overrides the config's `.chain.operationGasBudget` (default 40,000,000) |
| `KEEPER_TOPUP_WALLET` | every step off anvil, `11` | Address of the keeper top-up wallet; overrides the config's `keeperTopUp.wallet`. Required on test networks and mainnet (in the environment or the config): `step.sh` stops every step without it, and `00_Factories`, `03_DeployAvana` and `11_FundKeepers` check it before their first transaction (a real address, `0 < minBalanceWei < targetBalanceWei`, not a keeper signer). Optional on anvil |
| `AVANA_FIXTURE` | hostile suites | `fork` runs the hostile-component tests on the Ethereum fork |

Every name is listed, without values, in [`../.env.example`](../.env.example); Foundry and the Makefile read the values from `contracts/.env`.

The deployer signs with a Foundry keystore account (`--account <name> --sender <address>`) or a Ledger (`--ledger --mnemonic-indexes <n> --sender <address>`); no private key is passed through the environment. The deployer holds no role once deployment ends; every later change is a timelock operation scheduled by the governance multisig.

## Commands

```bash
# Builds the deploy scripts read: default and aave profiles, Uniswap v3, Slipstream, Aerodrome, Aave V3, Chainlink
make build build-aave build-external

# Every step in order on a fresh anvil node, then the manifest, services and scenarios (deployments/README.md)
script/e2e/e2e-local.sh

# One step by hand (script/deploy/step.sh lists every step in order); on anvil every sender is unlocked
anvil --auto-impersonate --code-size-limit 49152 --gas-limit 60000000 &
AVANA_NETWORK=anvil AVANA_RPC_URL=http://127.0.0.1:8545 script/deploy/step.sh 00-factories
AVANA_NETWORK=anvil AVANA_RPC_URL=http://127.0.0.1:8545 script/deploy/step.sh 01-aave-v4

# Off anvil: a keystore or Ledger signer, the release tag checked out, the keeper top-up wallet named
AVANA_NETWORK=sepolia AVANA_RPC_URL="$RPC_SEPOLIA" AVANA_RELEASE=<tag> KEEPER_TOPUP_WALLET=0x… \
  AVANA_SIGNER_FLAGS="--account deployer --sender 0x…" script/deploy/step.sh 03-avana

# The keeper signers refilled by the top-up wallet, from its keystore (password from a file or the prompt)
AVANA_NETWORK=sepolia AVANA_RPC_URL="$RPC_SEPOLIA" KEEPER_TOPUP_WALLET=0x… \
  AVANA_SIGNER_FLAGS="--account keeper-topup --sender 0x…" script/deploy/step.sh 11-fund-keepers

# Dry run of the Avana deployment on a mainnet fork (simulated, nothing broadcast)
AVANA_NETWORK=ethereum AVANA_RELEASE=<tag> forge script script/deploy/03_DeployAvana.s.sol --fork-url "$RPC_MAINNET" --fork-block-number "$MAINNET_FORK_BLOCK"

# The release manifest, checked against the chain before it moves to deployments/verified/ (from packages/protocol)
node src/manifest/cli.ts produce --network sepolia --rpc-env RPC_SEPOLIA
node src/manifest/cli.ts verify --manifest ../../deployments/sepolia/<release>.json --rpc-env RPC_SEPOLIA
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
- `AVANA_RELEASE` equals that tag. Every step that loads the network config (`03`, `04`, `09`) checks it (`DeployInputs._checkRelease`): it matches `^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z0-9.]+)?$` on every chain, and off anvil (chain ID other than 31337) it is not a learning tag (`-local`, `-test`, `-learn`), HEAD is the tag's commit and `src`, `script/deploy`, `foundry.toml`, `soldeer.lock` and `remappings.txt` have no uncommitted change. The off-anvil check reads git through forge's `--ffi`, which `script/deploy/step.sh` passes on those chains only; a script run without it stops.
- `03` also compares the run with the release workflow's `release.json` when one is given (`AVANA_RELEASE_RECORD`, or `deployments-local/<network>/release.json`): the same release, commit and CREATE3 factory, each salt and, for a record made for this deployer, each predicted address.
- A tag is never moved, deleted or reused: a tag deployed once names those addresses for good. A fix is a new tag.
- Once the external audit has run ([`docs/audit/README.md`](../../docs/audit/README.md#audit-status)), a verified manifest names a release whose commit is the audit's fix commit or later with no change to the audited files.

## Checks on the build

| Script | Does |
|---|---|
| `check-sizes.sh` | Writes `out-security/sizes.json` from `out/` and fails when a deployable `src/` contract's runtime code is larger than 24,576 bytes minus its margin in [`security/size-margins.json`](../security/size-margins.json). Each contract is measured on the artifact of the profile it is deployed with: the restricted profile's artifact for a file named in a `compilation_restrictions` entry of `foundry.toml`, the default profile's artifact for every other file, even when a restricted file also compiles it; a contract with no artifact for its deployment profile fails. `check-sizes.test.sh` checks this rule on fixture artifacts (`make sizes` runs both); with `--base <sizes.json>` prints each change in size. CI compares every pull request with the sizes saved from the last `main` build and writes the table to the job summary. |
| `governance-diff.py` | Writes a governance operation folder's `diff.md` from its `before.json` and `after.json` ([`docs/governance/README.md`](../../docs/governance/README.md#operation-folders)). |

## Mutation testing at the layer gate

From `contracts/`, after `script/install-security-tools.sh --python --gambit`:

```bash
MUTATE_LAYERS=2.1 script/security-slow.sh mutate gambit necessist          # every mutation step of layer 2.1
MUTATE_LAYERS=2.1 script/security-slow.sh gambit                           # Gambit only
MUTATE_CONTRACTS=Lock MUTATE_SHARD=1/3 script/security-slow.sh mutate      # the first of three slither-mutate shards of Lock
MUTATE_LAYERS=2.2 MUTATE_CONTRACTS=ClTickMath GAMBIT_TIMEOUT=600 script/security-gambit.sh   # one file, longer budget
script/mutation-targets.py gambit --layers 2.2                             # the files, tests, cap, seed and operators Gambit uses
```

`security-gambit.sh` writes `out-security/gambit/<layer>/<Contract>/status.tsv` (each mutant `killed`, `survived`, `timeout` or `invalid`), the mutants and their diffs under `gambit/`, one test log per mutant, `out-security/gambit/<layer>/survivors.txt` and the gate summary `out-security/gambit/gate.txt`. A survived or timed-out mutant fails the run until a test kills it or the layer gate review adds its fingerprint to `security/gambit-triage.json` with the reason its change cannot be observed. CI runs it in the `layer-gate` job (`workflow_dispatch` with the `layer` input).
