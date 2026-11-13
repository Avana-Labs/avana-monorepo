# Formal rules (CVL)

The CVL rules and invariants for the implementation-stage properties `PROP-001` … `PROP-074` of [5.2 Formal Properties](../../spec/05-verification/02-formal-properties.md) (`Q-041`), written against the final interfaces in `contracts/src/` and run with the Certora Prover. Every `PROP` row has at least one rule here, including the rows whose primary tool in 5.2 is Halmos or the SMTChecker; those rules restate the same arithmetic or bound over unbounded integers, and the Halmos checks in `contracts/test/` and the SMTChecker run of the `smt` profile remain the evidence 5.2 names for them.

## Status

Sixteen confs target merged code, compile and type-check (`--compilation_steps_only`, exit 0) and have been run on the prover with `rule_sanity: basic`: Lock, AvanaTimelock, ParameterStore, MarketRegistry, VaultToken, VaultTokenFactory, PositionProxy, ProxyManager, ProxyManagerIsolation, PayoutEscrow, CoverageSpoke, FlashSource, Collateralization, DexPathRoute, WrapperThenDexRoute and PegModuleRoute, with the router-only `ParameterStoreRoles` and `MarketRegistryRoles` confs and the `MarketRegistryListingProbe` conf beside them; [RUNS.md](RUNS.md) has the per-rule results and job links. The contracts of LPOracle, DebtOracle, the LPVaults and AMM integrations (`LPVault`, `LPVaultSlipstream`, `UniswapV3Integration`, `SlipstreamIntegration`), RiskModule and RiskModuleDrift are merged; their confs have no prover run recorded in RUNS.md yet. AaveAdapter and AaveAdapterGates compile and type-check (`--compilation_steps_only`, exit 0) and `LPVaultSwap.conf` compiles and links its logic contracts (`--build_only`); none has a prover run yet. The Hub conf, which models Aave's own code, stays at the methods check.

- `check-methods.py` checks every `methods` entry of every spec against the compiled ABIs. It runs on every commit as the `cvl` step of the fast security tier (`script/security-fast.sh cvl`).
- Every rule and invariant carries a `PROP-NNN verifies:` tag; [`trace.py`](../../spec/05-verification/trace.py) reports no error from this folder.

`certoraRun` needs the implementation files at the paths the confs name, Java 21 for local CVL type checking, and a key in `CERTORAKEY`.

## Layout

```
certora/
├── check-methods.py          methods-block check against the interface ABIs (fast security tier, step cvl)
├── RUNS.md                   run log
├── harness/                  verification-only wrappers that add views to unchanged contracts
│   └── MarketRegistrySafetyLogicHarness.sol   the safety logic plus an immutables comparison and read views of its
│                                              own copy of the layout (MarketRegistry.conf)
├── conf/                     one JSON5 configuration per verified contract and spec
│   ├── Collateralization.conf   LPVault.conf             VaultToken.conf          VaultTokenFactory.conf
│   ├── LPVaultSlipstream.conf   (the Slipstream LPVault against LPVault.spec)
│   ├── AaveAdapter.conf         (AaveAdapter with Collateralization linked)
│   ├── AaveAdapterGates.conf    (AaveAdapter against AaveAdapterGates.spec)
│   ├── ProxyManager.conf        PositionProxy.conf       Lock.conf                Hub.conf (Aave V4 Hub at a3ef63e)
│   ├── RiskModule.conf          MarketRegistry.conf      ParameterStore.conf      LPOracle.conf      DebtOracle.conf
│   ├── AvanaTimelock.conf       LPVaultSwap.conf         PayoutEscrow.conf     CoverageSpoke.conf
│   ├── PegModuleRoute.conf, DexPathRoute.conf, WrapperThenDexRoute.conf                    (SettlementRoute.spec)
│   └── ParameterStoreRoles.conf, MarketRegistryRoles.conf   (role-map rules on the router alone, logic unlinked)
└── specs/
    ├── <Contract>.spec       rules of one contract
    └── setup/                shared ghost models imported by the contract specs
        ├── Erc20Model.spec       ERC-20 balances, supply and allowances; vault-token mint(to) and burn(from)
        ├── LockModel.spec        the Lock's holder slot
        ├── AaveModel.spec        Borrow Spoke, Hub and AaveOracle
        ├── PriceStateModel.spec  LPOracle and DebtOracle price state and served price per oracle
        ├── TransientModel.spec   empty transient storage at the start of a rule (TLOAD/TSTORE hooks)
        ├── RegistryReadsModel.spec  RegistryModel without the single pause state (AaveAdapter specs)
        └── RegistryModel.spec    MarketRegistry pause state and reason, freeze list, breakers,
                                  approved debt reserves, with every read counted
```

Each conf verifies one contract against one spec: `"verify": "<Contract>:certora/specs/<Spec>.spec"`. The `files` entries are the planned implementation paths under `contracts/src/` (the Hub conf uses the pinned Aave release under `dependencies/`). `AaveAdapter.conf` links Collateralization as real code, because the backing rules (`PROP-054`, `PROP-065`) span both contracts; every other second contract a property needs is summarised by a setup model or a spec-local model whose own behaviour is proved by another conf (the vault token, the Lock, the LPVault, the oracles, the MarketRegistry), or is an external system summarised as its 5.2 row states.

Setup files hold only ghosts and CVL functions; each contract spec binds them in its own `methods` block, so a summary applies only where that spec says so.

## Methods check

`check-methods.py` parses the `methods` block of every spec and requires each entry to name a function that exists, with the same parameter types and, where the entry states them, the same return types:

| Entry | Checked against |
|---|---|
| `function f(...) external` | the verified contract's interface (`I<Contract>`; `IAaveV4Hub` for the Hub, `ISettlementRoute` for the swap routes, `ICoverageSpoke` for CoverageSpoke.spec), plus `IAccessControl` for the AccessControl contracts (AaveAdapter, MarketRegistry, ParameterStore, RiskModule, LPOracle, DebtOracle, LPVaultSwap, AvanaTimelock; the ProxyManager is immutable with no roles) |
| `function c.f(...) external` | the interface of the contract bound by `using C as c;`, which must be in that spec's conf |
| `function _.f(...) external => …` | any interface ABI that declares `f` with those parameter types and the `expect` return types |

Internal entries and catch-all (`_._`, `unresolved`) entries are refused, so every external call a spec summarises is bound to a declared interface function. Functions that no Avana interface declares have no methods entry and are called directly in the rules, which the prover resolves against the implementation: OpenZeppelin `TimelockController`'s `schedule`, `execute`, `cancel` and friends (AvanaTimelock.spec), UUPS `upgradeToAndCall`, and Aave's `previewRemoveByShares` (Hub.spec). Calls to external contracts without an Avana interface (ERC-4626 static aTokens, the Aave DAO's AccessManager, Chainlink aggregators) stay unresolved, which lets them return anything.

```bash
cd contracts
python3 certora/check-methods.py            # against out/ (forge build)
python3 certora/check-methods.py -v         # list every entry and the interface it matched
script/security-fast.sh cvl                 # the fast-tier step, against out-security/build/src
```

## Common settings

Every conf sets:

| Setting | Value | Why |
|---|---|---|
| `solc` | `solc-0.8.28` | CI installs the static solc 0.8.28 binary on `PATH` under exactly this name (`REQ-ARCH-053`). |
| `solc_evm_version` | `cancun` | Transient storage (Lock holder, seizure snapshot, repay-with-collateral session, route hop context) needs Cancun. |
| `solc_optimize` | `10000` | `foundry.toml` `[profile.default]`; the Hub conf uses Aave's hub profile (via-IR, 22,300 runs) so the verified bytecode is the release bytecode. |
| `packages` | `contracts/remappings.txt` | Same import resolution as `forge build`; the Hub conf maps Aave's `src/` imports to `dependencies/aave-v4-a3ef63e/src`. |
| `optimistic_loop`, `loop_iter` | per conf | Loops beyond `loop_iter` iterations are assumed not to happen; each conf states the bound it relies on (below). |
| `optimistic_fallback` | `true` | Every external call is summarised or reaches no fallback; Avana sends no ETH and makes no empty-calldata calls. |
| `optimistic_hashing`, `hashing_length_bound` | `true`, `224` (2,048 in three confs) | Hashed inputs are mapping keys, the 85-byte CREATE2 preimage, the CREATE3 salt and ERC-7201 ids. `ProxyManager.conf` and `ProxyManagerIsolation.conf` use 2,048 because `deployProxy` and `predictProxy` hash the PositionProxy init code (about 1,500–1,650 bytes of creation code plus four words); `AvanaTimelock.conf` uses 2,048 because `hashOperationBatch` of six calls with payloads of up to 132 bytes is 1,984 bytes. At 224 these hashes exceeded the bound and the rules that reach them were vacuous. |
| `prover_args` | `-mediumTimeout 60`, `-depth 15` | SMT timeout and split depth for the ghost-heavy rules. `MarketRegistry.conf` adds `-disableInputSizeValidation true`: the router forwards `msg.data` unchanged to its logic contracts and does not decode the struct and array arguments itself, so the prover's lower bound on the forwarded buffer is below the logic function's ABI minimum and its internal size check aborted the run. The three route confs and `FlashSource.conf` add `-enableStorageSplitting false`, which the TLOAD/TSTORE hooks of `TransientModel.spec` need. |
| `rule_sanity` | `basic` | Vacuity and tautology checks; a vacuous rule counts as a failed rule. |

`ProxyManager.conf`, `ProxyManagerIsolation.conf` and `VaultTokenFactory.conf` add `dynamic_bound` 1 and `dynamic_dispatch`, because `deployProxy` and `deployVaultToken` create contracts. `ParameterStore.conf` and `MarketRegistry.conf` list the router's logic contracts (five and six) and `link` its `_*_LOGIC` immutables to them, so the prover resolves each delegatecall to the real logic code; `MarketRegistry.conf` links the safety logic through `certora/harness/MarketRegistrySafetyLogicHarness.sol` (below). `Collateralization.conf` compiles with via-IR and 200 optimizer runs, the foundry compilation restriction for `Collateralization.sol`. `AaveAdapter.conf` and `AaveAdapterGates.conf` list the Adapter router's four logic contracts and `link` its `_*_LOGIC` immutables to them and each logic's `_SELF` to itself; `AaveAdapter.conf` also links `_COLLATERALIZATION` in the router and every logic contract and Collateralization's `_ADAPTER`, and compiles Collateralization with its own via-IR, 200-run settings (`solc_via_ir_map`, `solc_optimize_map`). `LPOracle.conf` and `DebtOracle.conf` set `storage_extension_annotation` for their ERC-7201 namespaces.

Storage hooks and direct storage reads use the variable and field names of the Storage table of each 2.x contract page; each spec states this once in its header. Upgradeable contracts keep their state in ERC-7201 namespaces and are read through their views; Collateralization, the LPVault and the vault token are immutable and read directly.

## Mutation testing (`certoraMutate`)

Every conf ends with a `mutations` section. `certoraMutate` reads it, generates the mutants and runs the conf's rules on each; a mutant survives when every rule still passes. `mutation-gate.yml` runs it once per conf when the `CERTORAKEY` secret is set ([audit/mutation](../../audit/mutation/README.md)).

- **Gambit entries.** One entry per implementation file under `src/` that the verified contract is built from: the conf's `files` under `src/`, the logic contracts it delegates to, and the `src/` base contracts they inherit (a harness counts through the `src/` contracts it inherits). Files with no function body are left out. A collaborator that has its own conf is left to that conf: `AaveAdapter.conf` does not mutate PositionProxy or Collateralization.
- **Count.** `num_mutants` is the per-file cap of `security/mutation-layers.json` (`gambit.num_mutants`): 10 for a file in layer 2.1, 20 for a file in layers 2.2 to 2.6, and 10 for a file in no layer (the RiskModule and the AaveAdapter). A file shared by several confs has the same count in each.
- **No seed.** certora-cli 8.20.3 reads every integer of a conf as a string and converts `num_mutants` back, but passes `seed` to Gambit as a string, which Gambit refuses (`invalid type: string "20261111", expected u64`). The entries set no seed, so Gambit uses its default.
- **Not mutated:** `Hub.conf`. Its contract is the unmodified Aave V4 Hub under `dependencies/`, not Avana code, so it has no `mutations` section and `script/ci-shards.py certora-mutate` leaves it out; its rules still run in the `certora` job. No modified copy of Aave code is kept in the repository.
- **Mutation targets.** The two AaveAdapter confs mutate the router, its four logic contracts and the `AaveAdapterSteps` and `AaveAdapterStorage` bases; `LPVaultSwap.conf` mutates the router and its three logic contracts.

Check a conf without a key. `--test check_args` stops `certoraMutate` right after its own conf validation (`MutateValidator`: the `mutations` keys, every Gambit `filename` readable, every manual mutant path), before the key check, the build and any upload. The CLI raises `TestResultsReady` there and exits 1 with no message, so the check calls the same entry point from Python and treats `TestResultsReady` as a pass:

```bash
cd contracts
for c in certora/conf/*.conf; do
  .venv/bin/python -c 'import sys
import certora_cli.certoraMutate as cm
from Shared import certoraUtils as U
try:
    cm.run_mutate_from_args([sys.argv[1], "--test", "check_args"])
except U.TestResultsReady:
    print(sys.argv[1], "valid"); sys.exit(0)
except U.CertoraUserInputError as e:
    print(sys.argv[1], "INVALID:", e, e.orig or ""); sys.exit(1)' "$c"
done
```

To also generate the Gambit mutants locally (Gambit compiles each file with the conf's solc settings), put `solc-0.8.28` on `PATH` and call the app's `run_gambit()` on the object `TestResultsReady` carries; it writes `gambit_out/` and `tmp_gambit.gconf` in the working directory, so run it on a copy of `contracts/`.

## Shared models and why they are sound

| Model | What it assumes | Why it is sound | What it does not cover |
|---|---|---|---|
| `Erc20Model` | Standard ERC-20 semantics with no hooks, fees or rebasing; a short balance or allowance aborts the call. Vault-token `mint(to, amount)` and `burn(from, amount)` change supply and balances for any caller; `burn` needs no allowance. | The listing rule of 2.7 admits only standard tokens; vault-token mint and burn authority (only `adapter()`) is proved on the real token (`PROP-005`, `PROP-055`, VaultToken.spec), so the model's open mint path is never taken by another caller. | Token blocklisting of an Avana contract (accepted external risk, 4.3); a fee switched on after listing, which Avana settles by balance delta (`Q-271`, fork test `TEST-221`). |
| `LockModel` | `acquire` succeeds only while free and records the caller; `release` only by the holder. | The real Lock's rules are proved in Lock.spec (`PROP-037`). | Which contracts are members: Lock.spec proves only the AaveAdapter and LPVaultSwap acquire it (`PROP-077`). |
| `AaveModel` | The Spoke moves tokens along the vault-token recipient rule; `supply`, `withdraw` and `liquidationCall` change supplied shares one-for-one (Hub shares == assets); health factors after a state-changing call are fresh arbitrary values; reserve paused and frozen flags are ghost configuration. | Matches the 5.2 summaries ("token movers that follow the recipient rule", "getUserSuppliedShares returns ghost state that only liquidationCall and withdraw lower", "ghost HF computed after the call", "ghost paused/frozen flags"); shares == assets for the vault-token asset is `PROP-040` on the real Hub. | Aave's own liquidation sizing, dust rule, bonus and fee shares: fork tests `TEST-109` … `TEST-111` and `TEST-114` run them on real bytecode (5.2 limitations). |
| `PriceStateModel` | Each LPOracle and DebtOracle has fixed Drifting, Cached, Expired, disagreement, grace, timestamp and accepted-price state for a rule; `getPriceState()` agrees with it, including `liquidationPaused = Cached or Expired or disagreement pause or disagreement expired`; the served price follows `SPEC-ORC-017` and `SPEC-ORC-018`: an LPOracle that is not Live serves at most its accepted price and at least 1 (exactly 1 when Expired), a DebtOracle that is not Live serves at least its accepted price. | The oracles' own rules are proved on the real oracles (`PROP-027`, `PROP-049`, `PROP-074` in LPOracle.spec and DebtOracle.spec). | The state machine that decides when a feed becomes Cached or Expired: LPOracle and DebtOracle fuzz and fork tests (`TEST-036` … `TEST-038`, `TEST-044`, `TEST-219`, `TEST-220`). |
| `RegistryModel` | The pause state and reason (`pauseReason() == None` exactly when not Paused), the freeze list, breakers and approved debt reserves are arbitrary ghost state; every read is counted per kind. | A function that never reads a value behaves the same for every value of it, so a zero read count proves independence (`PROP-032`, `PROP-057`, `PROP-066`); the MarketRegistry's own transitions are proved in MarketRegistry.spec (`PROP-041`, `PROP-061`, `PROP-071`). | Values the registry derives from other contracts (market records, route records), which each spec takes as uninterpreted functions. |

## Spec files

### Collateralization.spec — `Collateralization.conf`

- **Contracts**: `src/custody/collateralization/Collateralization.sol:Collateralization`.
- **Covers**: `PROP-001` (ledger half), `PROP-002`, `PROP-003`, `PROP-004`, `PROP-011` (debit equality), `PROP-012`, `PROP-013`, `PROP-014`, `PROP-028`, `PROP-029`, `PROP-032` (exits make no RiskModule call), `PROP-033` (`releaseZeroCredit`), `PROP-037`, `PROP-038` (NFT returns), `PROP-043`, `PROP-045`, `PROP-054` and `PROP-065` (ledger half: pledge, re-credit, partial removal, deleverage release), `PROP-067` (rescue units booked per record and summed per account-market, the input of the health check), `PROP-072` (deleverage release); `INV-001`, `INV-002`, `INV-005`, `INV-007`, `INV-008`, `INV-009`, `INV-014`, `INV-015`, `INV-016`, `INV-027`, `INV-054`, `INV-058`, `INV-066`, `INV-080`, `INV-082`, `INV-088`, `INV-089`.
- **Ghosts and hooks**: a mirror of every seizure list (entries and length), for `seizureListEntriesBelowNextId` (every entry is a record id below `_nextRecordId`, which `pledgeInsertsInOrder` requires); per-record mirrors of `credited`, `rescueUnits`, `currentUsdCharge`, `vaultToken`, `proxy`, `depositor`, `tokenId`; sums of credited units per market and per account-market, of rescue units per account-market, and of charges per market, pool token and depositor; `marketUsd` summed over both buckets. Field moves are handled in any write order, so `delete records[id]` and the pledge write order cannot desynchronise a sum.
- **Summaries**: the LPVault by a custody model (it pulls the NFT from its owner and records the depositor, returns it only to the depositor of record, removes exactly the liquidity asked and pays the principal to the named recipient, or to the depositor of record in `releaseLiquidity`; `topUpPosition` adds arbitrary liquidity to a held position), proved on the real LPVault in LPVault.spec; the position manager's `positions` by a liquidity ghost; vault and pool tokens by `Erc20Model`; the Spoke and Hub by `AaveModel`; the RiskModule's `checkPledge` returns an arbitrary charge and is counted (any RiskModule: these rules survive a hostile upgrade of it); the LPOracle's `poke` and the pool's `slot0` are NONDET; the vault-token factory registry, the Uniswap factory and the pool immutables are uninterpreted.
- **Assumptions**: between `beginSeizure` and `settleSeizure` the proxy's supplied shares and the vault-token supply fall by arbitrary amounts, standing for `liquidationCall` and the Adapter's `burnSeized`; the prover keeps transient storage across the calls of one rule, as within one transaction. Reconcile rules assume a proxy's supply never exceeds its credit (vault tokens reach the Hub only through the Adapter's mint and the proxy's supply, `INV-008`).
- **Loop bound**: 8, the records-list bound of 5.2 (Halmos unrolls the seizure list to 8). `TEST-057`, `TEST-123` and `TEST-124` cover list order and gas for longer lists.
- **Not covered**: that reconciliation also runs in `recredit` with the proxy's current supply (`SPEC-BACK-011`); `recreditAddsUncreditedLiveUnits` states the re-credit with no unsettled seizure, and `TEST-238` covers the reconciled case.

### LPVault.spec — `LPVault.conf`, `LPVaultSlipstream.conf`

- **Contracts**: the Uniswap v3 LPVault (`LPVault.conf`) and the Aerodrome Slipstream LPVault (`LPVaultSlipstream.conf`), whose custody code is the shared concentrated-liquidity base. Rules name a position by its `bytes32` key; `resolve(key)` reads the (position manager, token ID) the LPVault resolves it to through one `positionOwner` call, so every Uniswap v3 key and the keys of all four Slipstream generations are covered. Both confs compile at 1,000 optimizer runs, the `compilation_restrictions` setting of foundry.toml for the two LPVaults.
- **Covers**: `PROP-002` (custody half), `PROP-003` (stray path), `PROP-032` (`collectFees`), `PROP-034` (`returnStrayNft` only by `TIMELOCK`), `PROP-037`, `PROP-038`, `PROP-065` (partial-removal principal to the depositor); `INV-002`, `INV-005`, `INV-007`, `INV-051`, `INV-054`, `INV-088`.
- **Covers (additions 2026-11-11)**: `receivePositionKeepsTheMarketsPositionManager` (`PROP-002`: the key's manager is the market's pinned one, `REQ-AMM-SLIP-007`) and `collectFeesNeedsTheAaveAdapterLock` (`PROP-037`: `REQ-VAULT-064`). `recordedPositionsAreHeld` is the inductive step of the former invariant, over every non-view function and every second key (the constructor writes no custody entry); unwind, release and fee rules also assert that no other NFT is touched.
- **Summaries**: every position manager by a ghost model of owner, liquidity, owed amounts and approvals per (called manager, tokenId) (`decreaseLiquidity(x)` lowers liquidity by exactly `x` and adds the principal to the owed amounts; `collect` pays at most the owed amounts and the cap, to the named recipient); `positions` NONDET (its field 5 is `uint24 fee` on Uniswap v3 and `int24 tickSpacing` on Slipstream, and no rule reads its fields); pool tokens by `Erc20Model`; the Lock by `LockModel`, with `AAVE_ADAPTER()` a non-zero ghost.
- **Assumptions**: distinct keys name distinct NFTs (`distinctNfts`, required of the second key of a parametric call): the Slipstream constructor refuses equal managers (`REQ-AMM-SLIP-006`), which the prover sees only as unknown immutables.
- **Loop bound**: 1; every function acts on one tokenId.

### VaultToken.spec — `VaultToken.conf`

- **Contracts**: `src/vault-token/vault-token/VaultToken.sol:VaultToken`.
- **Covers**: `PROP-005`, `PROP-008` (recipient part), `PROP-009` (append-only part), `PROP-043`, `PROP-055`; `INV-009`, `INV-010`, `INV-011`, `INV-012`.
- **Hooks**: OpenZeppelin v5.1.0 `_balances` summed against `_totalSupply`; registry writes on `isValidProxy`.
- **Definitions**: `allowedPath(from, to)` is the `REQ-VTOKEN-040` formula (proxy to Hub, Hub to proxy, Hub to LPVaultSwap); `isBinding(a)` is the seven address bindings and the token itself, which `addValidProxy` refuses (`REQ-VTOKEN-047`).
- **Summaries**: none; the token holds its own registry and makes no external call, so every rule holds for any Adapter.
- **Assumptions**: the supply rules start from a state where `totalSupply` is the sum of balances (`totalSupplyIsSumOfBalances`, required), because OpenZeppelin's burn lowers `_totalSupply` unchecked.
- **Loop bound**: 7, the constructor's pairwise check of the seven address bindings.

### VaultTokenFactory.spec — `VaultTokenFactory.conf`

- **Contracts**: `src/vault-token/vault-token-factory/VaultTokenFactory.sol:VaultTokenFactory`.
- **Covers**: `PROP-099`: only the AvanaTimelock registers an integration or deploys a token (`registerOnlyByTimelock`, `deployOnlyByTimelock`), `lpVaultOf(id)` and `tokenOf(spoke, marketKey)` are written once (`lpVaultOfIsWriteOnce`, `tokenOfIsWriteOnce`), `isVaultToken(t)` only turns true, each (CDP Spoke, market key) gets one token at `predictAddress(spoke, marketKey)` (`deployLandsAtThePredictedAddress`, `secondDeployForAMarketReverts`), the factory's bindings never change, and `timelockCanRegister` and `timelockCanDeploy` show both paths reachable; `INV-009`, `INV-012`, `INV-051`.
- **Summaries**: the LPVault and Collateralization reads of `registerIntegration` are length-checked low-level `STATICCALL`s, which the prover treats as returning arbitrary data, so every identity rule holds for any answer (the methods block also binds `INTEGRATION_ID`, `COLLATERALIZATION` and `LOCK` to ghost functions of the called contract); the VaultToken constructor runs inside the CREATE3 deployment, whose bytecode the prover creates with `dynamic_bound` 1.
- **Loop bound**: 7: the 32-byte words of names and symbols up to 64 bytes, and the VaultToken constructor's pairwise check of its seven bindings, which runs inside the CREATE3 deployment.

### AaveAdapter.spec — `AaveAdapter.conf`

- **Contracts**: `src/policy/aave-adapter/AaveAdapter.sol:AaveAdapter` (reviewed Adapter, the router) with its logic contracts `AaveAdapterUserLogic`, `AaveAdapterExitLogic`, `AaveAdapterCollateralLogic` and `AaveAdapterSettlementLogic` linked (each delegatecall resolves to the real code) and `src/custody/collateralization/Collateralization.sol:Collateralization` linked.
- **Covers**: `PROP-001`, `PROP-006`, `PROP-007`, `PROP-008` (end-of-call holders), `PROP-009` (origin), `PROP-033`, `PROP-034` (role changes), `PROP-054`, `PROP-064` (binding written once), `PROP-065`, `PROP-070` (Adapter), `PROP-072` (Adapter side); `INV-001`, `INV-009`, `INV-010`, `INV-011`, `INV-012`, `INV-016`, `INV-051`, `INV-054`, `INV-064`, `INV-066`, `INV-080`, `INV-084`, `INV-088`, `INV-089`.
- **Summaries**: vault tokens and every other ERC-20 by `Erc20Model`, with mints and burns counted per token and holder; the LPVault by the custody model of Collateralization.spec; the Spoke and Hub by `AaveModel`, with `getUserAccountData` returning the ghost health factor and a ghost borrow count; PositionProxies by their one `execute`, which forwards the Adapter's call to the named target (proved on the implementation in PositionProxy.spec); the ProxyManager's `deployProxy` returns `predictProxy(wallet, spoke, marketId)`; the MarketRegistry by `RegistryReadsModel` plus a pause state and reason per Hub, with the market, Spoke, debt-reserve and receiver-rule views NONDET; the Hub's listing views NONDET; RiskModule checks NONDET (the backing rules hold whatever the RiskModule approves); LPVaultSwap havocked except that `deleverage` calls back `deleverageRepay` and `deleverageRelease` once each with the session's arguments and returns only when it repaid at least `minDebtRepaid` (2.11 `DeleverageTooSmall`); the ParameterStore's `sequencer()` and the feed's `latestRoundData()` NONDET; the Lock by `LockModel`.
- **Assumptions**: every Adapter entry point is an outer call and starts with the Lock free and transient storage empty (`TransientModel`).
- **Loop bound**: 8, Collateralization's records-list walks and the reserves named in `repayAllAndWithdraw`.

### ProxyManager.spec — `ProxyManager.conf`

- **Contracts**: `src/proxy/proxy-manager/ProxyManager.sol:ProxyManager`.
- **Covers**: `PROP-064` (Adapter-only deployment at `predictProxy(wallet, spoke, marketId)`, at most once per triple); `INV-012`, `INV-064`, `INV-084`. The ProxyManager is immutable and holds no role, so `PROP-034` and `PROP-070` have no ProxyManager half.
- **Summaries**: the freeze list by a ghost map (the freeze part of `RegistryModel`; the model itself names MarketRegistry types that are not in this scene); OpenZeppelin `Create2` v5.1.0 runs as real code, and the new proxy's constructor only stores its immutables (its binding rules are `PROP-010` and `PROP-056` in PositionProxy.spec).
- **Loop bound**: 1.

### PositionProxy.spec — `PositionProxy.conf`

- **Contracts**: `src/proxy/position-proxy/PositionProxy.sol:PositionProxy`, the logic-free immutable account of one (wallet, CDP Spoke, market).
- **Covers**: `PROP-010` (`WALLET()`, `SPOKE()` and `MARKET_ID()` never change; no delegatecall; `execute` calls the target the Adapter names exactly once, with no ETH, and no other address), `PROP-056` (only the Adapter calls `execute`); `INV-016`, `INV-063`. Exact supply, withdrawal and the repay refund are Adapter properties, proved in AaveAdapter.spec (`PROP-033`, `PROP-054`).
- **Summaries**: none. `CALL` and `DELEGATECALL` opcode hooks record every call target, so the call-target rules hold over the bytecode.
- **Loop bound**: 4, the word-by-word copies of `execute`'s calldata and return data.

### Lock.spec — `Lock.conf`

- **Contracts**: `src/lock/lock/Lock.sol:Lock`.
- **Covers**: `PROP-037`, `PROP-043`, `PROP-075` (exactly two members, the AaveAdapter and LPVaultSwap, distinct and non-zero; every other caller's `acquire` reverts); `INV-091`, `INV-054`. The Lock's state is the transient holder slot, read through `holder()` and `isLocked()`.
- **Loop bound**: 1.

### FlashSource.spec — `FlashSource.conf`

- **Contracts**: `src/flash/AaveV3FlashSource.sol:AaveV3FlashSource`, the `IFlashSource` implementation on the Aave V3 Pool `flashLoan` (single asset, mode 0); the Pool model `test/utils/mocks/AaveV3PoolMocks.sol:MockAaveV3Pool`, linked as `LENDER`.
- **Covers**: `PROP-080`: only LPVaultSwap starts a loan; the lender callback runs only from the lender, for a loan this contract initiated, for one asset, inside the active context; the lender is never the Hub of the CDP Spoke being liquidated; the amount is within the lender's available liquidity and the quoted premium within the exact `maxFlashFeeBps` cap (`INV-095`, `INV-040`, `REQ-FLASH-001` … `REQ-FLASH-004`, `SPEC-LIQ-015`).
- **Summaries**: the Pool's views (including `getVirtualUnderlyingBalance`), the PoolAddressesProvider, the ACLManager and `maxFlashFeeBps` are deterministic ghost reads; balances use the ERC-20 model; `LENDER` is linked to the Pool model `MockAaveV3Pool` (`test/utils/mocks/AaveV3PoolMocks.sol`), whose `flashLoan` calls `executeOperation` back (dispatched), and the satisfy rules `flashLoanCanComplete` and `flashLoanCanCompleteWithPremium` show that a loan completes, so the flashLoan rules are not vacuous.
- **Assumptions**: the flash context is transient and empty at the start of each rule (`TransientModel.spec`, called first in every rule); `optimistic_hashing` bounds the hashed `context` bytes at 224, which covers the 32-byte context hash LPVaultSwap passes (`IFlashReceiver`).
- **Loop bound**: 1.

### UniswapV3Integration.spec, SlipstreamIntegration.spec — `UniswapV3Integration.conf`, `SlipstreamIntegration.conf`

- **Contracts**: the Uniswap v3 LPVault and the Slipstream LPVault.
- **Covers**: `PROP-083`: `validatePosition` and `receivePosition` accept a position only when both ticks equal the market's exact range (`INV-005`, `REQ-AMM-CORE-006`, `REQ-AMM-CORE-016`, `REQ-AMM-SLIP-018`).
- **Summaries**: the position manager's `positions` by ghost ticks keyed by tokenId, in the shape of each manager (`fee` for Uniswap v3, `tickSpacing` for Slipstream).

### ProxyManagerIsolation.spec — `ProxyManagerIsolation.conf`

- **Contracts**: `src/proxy/proxy-manager/ProxyManager.sol:ProxyManager`.
- **Covers**: `PROP-076`: one PositionProxy per (wallet, CDP Spoke, market), deployed by the Adapter at its CREATE2 address; a deployment whose predicted address already holds a proxy reverts, so two successful deployments never share an address (`INV-064`, `INV-012`, `REQ-PROXY-052`, `REQ-PROXY-055`). That distinct triples predict distinct addresses is not provable: a CREATE2 address is 160 bits of a hash, and the collision is the accepted assumption of `REQ-PROXY-055`.

### RiskModuleDrift.spec — `RiskModuleDrift.conf`

- **Contracts**: `src/policy/risk-module/RiskModule.sol:RiskModule`.
- **Covers**: `PROP-078`: `checkAaveConfig` reverts whenever it reads `receiveSharesEnabled = true`, a non-zero `liquidationFee` or a reinvestment controller on the vault-token asset.
- **Summaries**: `getReserveConfig`, `getDynamicReserveConfig` and `getAssetConfig` return arbitrary values and record whether a drifted value was read.

### Hub.spec — `Hub.conf`

- **Contracts**: `dependencies/aave-v4-a3ef63e/src/hub/instances/HubInstance.sol:HubInstance`, the real Hub at `a3ef63e`. Aave publishes no CVL specs for the Hub at this commit, so none are reused.
- **Covers**: `PROP-011` (Halmos primary, share preview identity), `PROP-040`; `INV-014`.
- **Assumptions**: the Avana listing configuration of 2.1 (liquidity fee 0, no reinvestment controller, `drawCap == 0` for the caller, no draws, premiums or deficits on the asset); configuration selectors are filtered because they set that configuration. The interest-rate strategy and the Aave DAO's AccessManager stay unresolved view calls.
- **Loop bound**: 2.

### AaveAdapterGates.spec — `AaveAdapterGates.conf`

- **Contracts**: `src/policy/aave-adapter/AaveAdapter.sol:AaveAdapter` (reviewed Adapter, the router) with its four logic contracts linked. The backing, mint, burn, binding and role rules are in AaveAdapter.spec.
- **Covers**: `PROP-031` (Adapter half: proxy, nonce, deadline, approved reserve, application state, the RiskModule calls and their order), `PROP-032`, `PROP-046` (the Adapter runs the check), `PROP-057`, `PROP-061` (a borrow names an approved reserve), `PROP-066` (Adapter half), `PROP-067` (`postHealthCheck` after a borrow and after Collateralization's debit), PositionManagerApproved by construction (`noPositionManagerApproval`: no Adapter method reaches the Spoke's `setUserPositionManager`, `renouncePositionManagerRole` or `multicall`; REQ-PROXY-008, REQ-RISK-088); `INV-019`, `INV-023`, `INV-025`, `INV-030`, `INV-043` … `INV-046`, `INV-049`, `INV-050`, `INV-067`, `INV-073`, `INV-081`, `INV-082`.
- **Summaries**: the Lock by `LockModel`; the MarketRegistry by `RegistryReadsModel` plus a pause state and reason per Hub, with every other registry view (the receiver rule's included) counted as a read; RiskModule checks recorded with their arguments and a step number (RiskModule.spec proves what they check, and the two specs together give each 5.2 row); Collateralization's `pledge` and `recredit` recorded with `requireRescue`, `release`, `releasePartial` and `releaseForDeleverage` with a step number, and its credited total per vault token kept as the real contract keeps it (credit what it returns, debit what it releases), so the Adapter's backing-gap check passes exactly on matching mints and burns; its debt mark and `recordIdOf` NONDET; the Spoke by `AaveModel` through the real PositionProxy, with `getUserAccountData` returning a ghost borrow count; the Hub's listing views NONDET; ERC-20s and vault tokens by `Erc20Model`; ParameterStore reads (`minPledgeUsd`, `sequencer`) counted and the feed's `latestRoundData` NONDET; LPVaultSwap's `deleverage` calls back `deleverageRepay` and `deleverageRelease` once each with the request's arguments; the Spoke's `setUserPositionManager`, `renouncePositionManagerRole` and `multicall` counted for `noPositionManagerApproval`.
- **Assumptions**: a rule is one transaction (transient storage empty, `TransientModel`); a bound proxy's account agrees with the registry's market record (Spoke, market and vault token; written once at creation, `bindingIsWrittenOnce`); an enabled debt reserve records a non-zero funding Hub (REQ-CONFIG-079).
- **Loop bound**: 4, the reserves named in `repayAllAndWithdraw`.
- **Not covered**: that a zero-debt `repay` emits no event (`TEST-132`).

### RiskModule.spec — `RiskModule.conf`

- **Contracts**: `src/policy/risk-module/RiskModule.sol:RiskModule` (verified implementation).
- **Covers**: `PROP-030` and `PROP-067` (Halmos primary: the `hfEx` arithmetic is restated, and the implementation rules show that `postHealthCheck` returns at least the required floor and at most Aave's health factor), `PROP-031` (gates half), `PROP-034`, `PROP-044` (restated), `PROP-046`, `PROP-050`, `PROP-061` (drift-check half), `PROP-062`, `PROP-066` (RiskModule half), `PROP-070`; `INV-019`, `INV-023`, `INV-025`, `INV-028`, `INV-030`, `INV-043`, `INV-045`, `INV-051`, `INV-060`, `INV-069`, `INV-073`, `INV-081`, `INV-082`, `INV-084`.
- **Summaries**: the Spoke by `AaveModel` (`getUserAccountData` returns a ghost health factor, debt value and borrow count; each reserve's `borrowable` flag is uninterpreted); the MarketRegistry by `RegistryModel`, with market records, `marketOfReserve`, `getSpoke` and `getDebtReserve` uninterpreted and `getDebtReserveIds` returning at most four entries, exactly the enabled set; LPOracles by `PriceStateModel`; `hardHealthFloor(marketId)`, `minPledgeUsd`, Collateralization's `getAccountRescueUnits` and LPVaultSwap's `activeKeeperCount` uninterpreted; NFPM, pool, Hub-configuration and `getBuyRoute` reads NONDET.
- **Assumptions**: the price rules use a debt scope of GHO reserves (`fixedPrice`); the LPOracle's and the DebtOracle's `getPriceState()` share one selector with different return types, so one wildcard summary serves the LPOracle.
- **Loop bound**: 4 (`MAX_RESERVES` per Spoke).
- **Not covered**: the DebtOracle half of the account price check (`DebtPriceTooOld`, `UnexpectedDebtPriceSource`), covered by `TEST-201` and `TEST-028`.

### MarketRegistry.spec — `MarketRegistry.conf`

- **Contracts**: `src/policy/market-registry/MarketRegistry.sol:MarketRegistry`, the UUPS router, with its six logic contracts (`MarketRegistryHubsLogic`, `ListingLogic`, `ActivationLogic`, `RoutesLogic`, `SafetyLogic`, `WindDownLogic`) linked to the router's `_*_LOGIC` immutables; the safety logic is linked through `certora/harness/MarketRegistrySafetyLogicHarness.sol`, the unchanged contract plus one view, `immutablesMatch`, that compares its implementation immutables with given addresses.
- **Covers**: `PROP-034`, `PROP-041`, `PROP-061` (activation and removal), `PROP-070`, `PROP-071`; `INV-049`, `INV-051`, `INV-073`, `INV-084`, `INV-085`. The pause rules cover the per-Hub functions and `freezeAll`/`pauseAll` (`REQ-CONFIG-082`); `onlyRoleCanCall` treats `closeMarket` and `syncDrawCap` as callable by anyone (`REQ-CONFIG-080`, `REQ-CONFIG-081`) and runs in `MarketRegistryRoles.conf` (router only, as for the ParameterStore). Parametric rules range over the router's functions; the prover leaves the router's 4-byte `freezeAll` delegatecall unresolved, so the state rules leave `freezeAll` out and `freezeAllFreezesOnlyFreeHubs` checks its body on the safety logic's own copy of the layout through the harness views. `appAdminAdministeredByDefaultAdmin` states that `APPLICATION_ADMIN` is administered by `DEFAULT_ADMIN_ROLE` in every reachable state; the role-map rules start from it.
- **Summaries**: LPVaultSwap's `isApprovedKeeper`, `activeKeeperCount` and `KEEPER_FLOOR` the AaveAdapter's `walletOf` and the flash source's `LENDER()` (an immutable of the source, so a function of the source) are uninterpreted; the Hub's `getSpokeTotalOwed` and `getSpokeDeficitRay` are uninterpreted functions of (hub, assetId, spoke); the RiskModule's `checkAaveConfig` is recorded (RiskModule.spec proves it refuses unequal debt sets) and the other activation reads are NONDET; OpenZeppelin `AccessControl` and `UUPSUpgradeable` v5.1.0 run as real code.
- **Assumptions**: `block.timestamp` non-decreasing; each logic contract's implementation immutables equal the router's (the router's constructor checks the immutables hash of every logic contract, `REQ-CONFIG-005`; the prover does not run that constructor, so the freeze rules state the equality through the harness view); `initializeSetsTheRoleMap` checks that `initialize` writes no pause state, which on the fresh proxy storage it runs on leaves every Hub at None; the protected set is checked on the part the registry's views expose (the immutables, the vault tokens and LPOracles of markets that are not Cancelled, approved Spokes, registered proxies, the flash source and its `LENDER()`, and every AMM contract recorded for an integration, named in the rules by an arbitrary (integration, index) pair of `integrationContracts`).
- **Loop bound**: 4, the debt reserves per Spoke and the route legs; the 24-bucket freeze window is read through `freezesInWindow`.
- **Not covered**: recorded routes, Coverage Spokes and debt price sources in the protected set (internal sets with no view) and the bucket arithmetic of the rolling freeze window, covered by `TEST-229`.

### ParameterStore.spec — `ParameterStore.conf`

- **Contracts**: `src/policy/parameter-store/ParameterStore.sol:ParameterStore`, the UUPS router, with its five logic contracts (`ParameterStoreTightenLogic`, `LoosenLogic`, `ListingLogic`, `AdminOracleLogic`, `AdminRiskLogic`) linked to the router's `_*_LOGIC` immutables. Parametric rules and invariants range over the router's functions only (`routerEntry`): in the deployment every logic contract refuses a direct call (`_onlyDelegated`), as the MarketRegistry's do. `settersNeedApplicationAdmin` runs in `ParameterStoreRoles.conf`, the router without its logic contracts: the role check is in the router and the rule reads only the roles before the call, so an unresolved delegatecall that may write any router storage is a sound over-approximation, and the rule closes without the logic bodies. The rule states the role map with its two exceptions: the 20 tighten setters and `setAvanaFeeShareBps` accept `APPLICATION_RISK_STEWARD` (the Joint Configuration Safe) beside `APPLICATION_ADMIN`, and `useStandbySecondSource` needs `APPLICATION_PAUSE_GUARDIAN` (the Emergency Guardian or the Aave Protocol Guardian); every other setter and the upgrade need `APPLICATION_ADMIN`.
- **Covers**: `PROP-034`, `PROP-042` (including `minPledgeUsd` and the buy-slippage floor; Halmos primary), `PROP-044` (step arithmetic restated; SMTChecker primary), `PROP-070`; `INV-047`, `INV-051`, `INV-084`.
- **Summaries**: the LPOracle's `checkConfig`, the MarketRegistry's market, token and debt-reserve reads are NONDET, which can only add reverts; the registry's `activePriceRoutes(token)` returns routes of at most two feeds that are a fixed function of the token, so the feed-agreement floor the setter checks and the one the rule reads agree.
- **Assumptions**: `adminRolesAdministeredByDefaultAdmin` (`APPLICATION_ADMIN` and `DEFAULT_ADMIN_ROLE` are administered by `DEFAULT_ADMIN_ROLE`) makes `gateRecoveryInBoundsOnceAdministered` inductive over `grantRole`. `gateRecoveryInBoundsOnceAdministered`: once an admin role exists (initialize sets the global parameters and grants the roles in one call), `gateRecoverySeconds` is inside [600, 7,200]; the tighten rule starts from it. `capStepArithmeticFits` states the cap step check `value * 10_000 <= old * 15_000` inside the listing bound `USD_CAP_MAX = 2^128 - 1`.
- **Loop bound**: 4, the `loosenFloorRoundingAllowanceGho` walk over approved debt reserves and the re-check walk over markets in `_recheck` (with `optimistic_loop`, setter paths over more than four markets are not checked).

### LPOracle.spec — `LPOracle.conf`

- **Contracts**: `src/oracle/lp-oracle/LPOracle.sol:LPOracle` (verified implementation).
- **Covers**: `PROP-023` … `PROP-026` (Halmos primary, arithmetic restated in CVL), `PROP-027`, `PROP-034`, `PROP-044` (SMTChecker primary), `PROP-049` (stored first observation), `PROP-070`, `PROP-074` (served price by state; a `priceRouteVersion` change restarts the disagreement timer and leaves the failure timer); `INV-051`, `INV-055`, `INV-059`, `INV-084`, `INV-087`.
- **Summaries**: Chainlink aggregators and the pool's `observe` are unresolved, so either `try`/`catch` branch occurs; `getOracleConfig`, `getFeed`, `activePriceRoutes` and `getToken` are NONDET; `priceRouteVersion` is an uninterpreted function of the token. A `GAS` opcode hook fixes a gas floor above `POKE_MIN_GAS_CEILING` (the 5.2 assumption "a gas floor after catch"); `storage_extension_annotation` exposes the ERC-7201 namespace.
- **Loop bound**: 4 (2 tokens × 2 routes × at most 2 legs).
- **Not covered**: that a disagreement start is cleared only when the routes agree (`TEST-044`, `TEST-157`, `TEST-159`), and the exact lower-route value during a disagreement, which the rule bounds by `min(fresh, accepted)` (`TEST-230`).

### DebtOracle.spec — `DebtOracle.conf`

- **Contracts**: `src/oracle/debt-oracle/DebtOracle.sol:DebtOracle` (verified implementation).
- **Covers**: `PROP-034`, `PROP-044` (stress-rise arithmetic, including the 5.2 example 0.9999 → 1.049895), `PROP-049`, `PROP-070`, `PROP-074` (never reverts; at least the accepted price `A` unless Live; `max(p, b, A)` in a disagreement; `A` when Cached; `ceil(A × (10000 + debtStressRiseBps) / 10000)` when Expired; route-version timers); `INV-051`, `INV-055`, `INV-059`, `INV-084`, `INV-087`.
- **Summaries**: aggregators unresolved; registry and ParameterStore reads NONDET; `priceRouteVersion` uninterpreted; `debtStressRiseBps` uninterpreted within [100, 5,000]; the gas floor and `storage_extension_annotation` as for the LPOracle.
- **Loop bound**: 4 (2 routes × 2 legs).

### AvanaTimelock.spec — `AvanaTimelock.conf`

- **Contracts**: `src/governance/timelock/AvanaTimelock.sol:AvanaTimelock`, immutable, extending OpenZeppelin `TimelockController` v5.1.0, which runs as real code.
- **Covers**: `PROP-058`, `PROP-070` (the timelock is its own only `DEFAULT_ADMIN_ROLE` holder), `PROP-073`; `INV-051`, `INV-065`, `INV-068`, `INV-084`, `INV-090`.
- **Summaries**: `schedule`, `scheduleBatch`, `execute`, `executeBatch`, `cancel`, `getTimestamp`, `hashOperation(Batch)` and `updateDelay` have no Avana interface, so they have no methods entry and the rules call them directly; executed calls to other targets are unresolved.
- **Assumptions**: `block.timestamp` non-decreasing; batches of at most 6 calls with payloads the 2,048-byte hashing bound covers; `togglingFlagClearBetweenCalls` (the `_toggling` flag is set and cleared inside one call) is required by the open-executor rules.
- **Loop bound**: 6.
- **Not covered**: rules that build call payloads in CVL, such as a restoring call in a batch, which `TEST-244` covers.
- **Executed calls**: the executed `target.call` is unresolved and does not change the timelock's own storage in the prover's model (the parametric rules over `execute` and `executeBatch` hold), so a self-call made through `execute` is not modelled; the self-call functions (`setNormalDelay`, `setShortDelaySelector`, `togglePublicExecution`, role changes) are checked as direct calls from the timelock instead.

### LPVaultSwap.spec — `LPVaultSwap.conf`

- **Contracts**: `src/liquidation/lp-vault-swap/LPVaultSwap.sol:LPVaultSwap` (verified implementation), with its three logic contracts `LPVaultSwapLiquidationLogic`, `LPVaultSwapPendingLogic` and `LPVaultSwapDeleverageLogic` linked to its `_LIQUIDATION_LOGIC`, `_PENDING_LOGIC` and `_DELEVERAGE_LOGIC` immutables, so the prover resolves the delegatecalls to their real code.
- **Covers**: `PROP-015` … `PROP-022`, `PROP-034`, `PROP-035`, `PROP-036`, `PROP-037` (flash callback), `PROP-044`, `PROP-047`, `PROP-048`, `PROP-049` (liquidation half), `PROP-051`, `PROP-053`, `PROP-057` and `PROP-066` (LPVaultSwap halves), `PROP-059`, `PROP-060` (pending side), `PROP-063` and `PROP-084` (LPVaultSwap side: a liquidation writes no persistent storage of LPVaultSwap, `liquidationWritesNoLPVaultSwapStorage`), `PROP-068`, `PROP-069`, `PROP-070`, `PROP-072` (LPVaultSwap side), `PROP-074` (liquidation half), `PROP-097` (liquidation half: with a transfer-fee token model the booked `Kf` is the measured balance increase and is the amount passed to `liquidationCall`, `callerFundingIsTheMeasuredIncrease`; the `deleverage` half needs the flash source linked and is not reached by this conf). `PROP-015`, `017`, `018`, `019`, `048`, `059` and `069` are Halmos primary and `PROP-044` SMTChecker primary; their arithmetic is restated over unbounded integers. Invariants `INV-021`, `INV-030`, `INV-034` … `INV-040`, `INV-042`, `INV-043`, `INV-045`, `INV-046`, `INV-048`, `INV-051`, `INV-053`, `INV-054`, `INV-055`, `INV-058`, `INV-059`, `INV-062`, `INV-067`, `INV-070`, `INV-071`, `INV-081`, `INV-083`, `INV-084`, `INV-086`, `INV-087`, `INV-089`.
- **Summaries**: ERC-20s by `Erc20Model`, with pool-token transfers through `swapTransfer`, where an uninterpreted `tokenRefuses` stands for a blocklisted or reverting recipient; the Spoke by `AaveModel` (`liquidationCall` takes `D` no greater than the amount LPVaultSwap passes, which the spec records and the rules require to be the measured caller funding `Kf`, and seizes an arbitrary `c ≥ 0`); LPOracle and DebtOracle state by `PriceStateModel`, leg prices a ghost per oracle, GHO at the fixed 1e8; pause state and reason, breakers, freeze list and enabled debt reserves by `RegistryModel`, markets, debt reserves and route records uninterpreted functions of their keys; ParameterStore values uninterpreted constants. `burnSeized` burns from the caller; Collateralization's `settleSeizure` and `settlePending` pay arbitrary pool-token amounts (zero for zero units); settlement and sell-back routes pay an arbitrary GHO amount ≥ `minOut`; buy routes take at most `maxGhoIn` and deliver `amountOut`; the caller pays any shortfall, including the rounding gap (no settlement budget exists, Q-397); the GHO Coverage Spoke's `fund` pulls exactly `amount`; the PayoutEscrow (payout escrow for transfers a token refuses) `deposit` pulls exactly `amount` and credits the named recipient.
- **Assumptions**: `liquidate` takes no flash loan, so every full-flow liquidation rule covers any caller, direct or funded through a flash liquidation helper (the helper is an ordinary caller to LPVaultSwap); the ERC-20 model has no transfer fee, so `Kf = debtToCover`; the Lock is free at entry, and held by the AaveAdapter for `deleverage`, the only path that runs `onFlashLoan`.
- **Loop bound**: 4 (up to four pool legs with primary and backup swap routes, up to 4 registered committed operators).
- **Not covered**: the `deleverage` core behind the flash callback (see the table of failing rules); the flash liquidation helper (`src/periphery/flash-liquidator/`), which has no conf here and is checked by tests; the gas limits of the breaker `try` and the payout transfers (`TEST-228`, `TEST-179`); the sell-back floor value of `REQ-SWAP-089`, of which the rules check `minOut ≥ 1`.

### PayoutEscrow.spec — `PayoutEscrow.conf`

- **Contracts**: `src/liquidation/payout-escrow/PayoutEscrow.sol:PayoutEscrow`.
- **Covers**: `PROP-037` (`deposit`), `PROP-043` (escrow bound), `PROP-052`; `INV-054`, `INV-061`.
- **Ghosts and hooks**: a hook on `claimable` keeps the per-token sum and splits each change into a credited (rise) or claimed (fall) ghost per borrower, so "credited = claimed + held" is checked after every function.
- **Summaries**: tokens by `Erc20Model`, with the escrow's own payouts and pulls recorded; the Lock by `LockModel`.
- **Loop bound**: 1.

### SettlementRoute.spec — `PegModuleRoute.conf`, `DexPathRoute.conf`, `WrapperThenDexRoute.conf`

- **Contracts**: swap route types 0–2 under `src/liquidation/settlement-routes/` (`PegModuleRoute`, `DexPathRoute`, `WrapperThenDexRoute`), bound through `ISettlementRoute`; each compiles with its abstract bases `SwapRouteBase` and (types 1 and 2) `DexHops`, the library `RouteMath` (type 0) and the structs in `types/`, pulled in through imports (abstract contracts and struct-only files have no deployable contract to list in a scene).
- **Covers**: `PROP-036` (swap callback refused outside a hop), `PROP-037` (`swap` only for LPVaultSwap while LPVaultSwap or the AaveAdapter holds the Lock), `PROP-068` (route half: `swap` returns at least `minOut` of the debt asset and takes at most `amountIn`); `INV-034`, `INV-040`, `INV-054`, `INV-083`.
- **Summaries**: tokens by `Erc20Model`; the Lock by `LockModel`; Curve `exchange` and the concentrated-liquidity pool `swap` pay an arbitrary amount of the debt asset to their recipient; the peg modules (GSM `sellAsset`, LitePSM `buyGem`) pay an arbitrary amount of the debt asset to the address they are told to pay; the wrapper steps (ERC-4626 `redeem`, the DAI-USDS converter) pay an arbitrary amount of their output token to the address they are told to pay, and an ERC-4626 `deposit` mints arbitrary shares to its receiver. With these steps unresolved, no peg-module or wrapper route could deliver output and the swap rules were vacuous. Launch hop kinds are concentrated-liquidity pools (Uniswap v3, Slipstream) and Curve StableSwap-NG; a Balancer hop would be a new hop kind in a new route version.
- **Assumptions**: the transient hop context is empty at the start of a rule (`TransientModel.spec`); the LPVaultSwap and AaveAdapter bindings are non-zero and distinct (`routeBindingsSet`, the constructor check).
- **Loop bound**: 5: the leg loop (at most three hops or fixed legs) and the balance loops over the held tokens (tokenIn, up to three intermediates, tokenOut).

### CoverageSpoke.spec — `CoverageSpoke.conf`

- **Contracts**: `src/coverage/coverage-spoke/CoverageSpoke.sol:CoverageSpoke`, against `ICoverageSpoke`. Avana writes the contract; the Aave DAO controls it through its AccessManager.
- **Covers**: `PROP-039`, `PROP-060`; `INV-042`, `INV-071`. `coverDeficit` calls `eliminateDeficit` exactly once, on its own `(HUB(), ASSET_ID())`, for an allowlisted Spoke only, with `0 < amount ≤ min(maxAmount, ceil(deficitRay / RAY), fundedBalance())`; `fund` moves exactly `amount` of `ASSET()` from the caller to `HUB()` and adds it on its own asset.
- **Summaries**: Hub views are persistent ghost functions of state, so `fundedBalance()` read by a rule and inside `coverDeficit` agree (the AccessManager's `canCall` is the only unresolved call, a STATICCALL); `eliminateDeficit` and `add` record their arguments; tokens by `Erc20Model`; storage read `allowedBorrowSpoke` (2.14).
- **Not covered**: the `COVERAGE_ROLE` check, which goes to the Aave DAO's AccessManager outside `contracts/src`; its `canCall` stays unresolved, so the rules hold for every role decision.

## Property map

| PROP | Tool in 5.2 | Spec | Rules and invariants |
|---|---|---|---|
| `PROP-001` | Certora | Collateralization.spec, AaveAdapter.spec | `totalCreditedIsSumOfRecords`, `collateralizationNeverMovesSupply`, `pledgeIsReachable`; `adapterCallsKeepTheBackingGap` |
| `PROP-002` | Certora | Collateralization.spec, LPVault.spec | `liveUnitsCoverCredit`; `recordedPositionsAreHeld`, `receivePositionKeepsTheMarketsPositionManager`, `unwindTakesExactlyAndCollectsPrincipal` |
| `PROP-003` | Certora | Collateralization.spec, LPVault.spec | `recordsBeyondNextIdAreEmpty`, `openRecordsIndexed`, `uniqueOpenRecordPerPosition`, `pledgeOfRecordedPositionReverts`; `strayReturnNeverMovesRecordedPosition` |
| `PROP-004` | Certora | Collateralization.spec | `seizureDebitEqualsSnapshotDrop` |
| `PROP-005` | Certora | VaultToken.spec | `supplyChangesOnlyThroughAdapter`, `adapterOnlyFunctionsRefuseOtherCallers`, `adapterCanMint` |
| `PROP-006` | Certora | Collateralization.spec, AaveAdapter.spec | `pledgeCreditsUnitsReadAfterCustody`; `mintOnlyInPledgeAndRecredit`, `pledgeMintsCreditedToCallerProxy`, `recreditMintsAddedToCallerProxy` |
| `PROP-007` | Certora | AaveAdapter.spec | `burnSeizedRaisesGapOnlyByItsUnits`, `burnsOnlyFromOwnProxyOrSwap`, `withdrawBurnsTheRecordCredit`, `removeLiquidityBurnsTheDebitedUnits` |
| `PROP-008` | Certora | VaultToken.spec, AaveAdapter.spec | `transferNeedsAllowedRecipientOnly`, `transferFromNeedsAllowedRecipientOnly`, `mintNeedsRegisteredProxy`, `onlyAllowedRecipientsHoldBalance`; `adapterCallsLeaveNoUnitsOutsideHub` |
| `PROP-009` | Certora | VaultToken.spec, AaveAdapter.spec | `registryIsAppendOnly`, `addValidProxyAddsAtMostOne`, `noBindingIsAProxy`; `registersOnlyTheCallerProxy` |
| `PROP-010` | Halmos | PositionProxy.spec | `boundWalletSpokeAndMarketNeverChange`, `noDelegateCall`, `executeCallsOnlyTheNamedTarget` |
| `PROP-011` | Halmos | Collateralization.spec, Hub.spec | `seizureDebitEqualsSnapshotDrop`; `previewRemoveBySharesIsIdentity` |
| `PROP-012` | Certora | Collateralization.spec | `seizureDebitWalksFromHead`, `reconcileDebitWalksFromHead` |
| `PROP-013` | Certora | Collateralization.spec | `debitAboveCreditFails` |
| `PROP-014` | Certora | Collateralization.spec | `pledgeInsertsInOrder`, `releaseUnlinksWithoutReordering` |
| `PROP-015` | Halmos | LPVaultSwap.spec | `waterfallWithOracleFee`, `waterfallBalances`, `waterfallExample` |
| `PROP-016` | Certora | LPVaultSwap.spec | `liquidateLeavesBalancesAndAllowances` (every caller, direct or helper-funded), `settlePendingLeavesBalancesAndAllowances` |
| `PROP-017` | Halmos | LPVaultSwap.spec | `effectiveSlippageCoversCosts` |
| `PROP-018` | Halmos | LPVaultSwap.spec | `recoveryFloorRoundsTowardSafety` |
| `PROP-019` | Halmos | LPVaultSwap.spec | `callerTopUpClosesTheGap` (no in-kind keeper share, Q-401) |
| `PROP-020` | Certora | LPVaultSwap.spec | `everySeizedUnitIsBurnedAndSettled`, `waterfallWithOracleFee` (no settlement budget; the caller pays any gap, Q-397) |
| `PROP-021` | Certora | LPVaultSwap.spec | `liquidatePaysNoPoolTokensOut` (no in-kind settlement or shortfall report, Q-401) |
| `PROP-022` | Certora | LPVaultSwap.spec | `liquidateCallerGates` (freeze, deadline, `minPayout`; no registry or role check), `liquidateAccountGates` (every caller) |
| `PROP-023` | Halmos | LPOracle.spec | `price8IsPositiveAndBelowExact` |
| `PROP-024` | Halmos | LPOracle.spec | `stableCeilingNeverRaisesAndIsMonotone` |
| `PROP-025` | Halmos | LPOracle.spec | `clampedSqrtPriceStaysInTickMathRange` |
| `PROP-026` | Halmos | LPOracle.spec | `agreementCheckIsSymmetric` |
| `PROP-027` | Certora | LPOracle.spec | `latestAnswerAlwaysServesOnceSeeded` |
| `PROP-028` | Halmos | Collateralization.spec | `recreditRebasesChargeBasis`, `exitChargeFollowsFixedBasis` |
| `PROP-029` | Certora | Collateralization.spec | `marketExposureMatchesRecords`, `tokenExposureMatchesRecords`, `depositorExposureMatchesRecords` |
| `PROP-030` | Halmos | RiskModule.spec | `pledgeBudgetFitsAddCap`, `partialExitsKeepBookingAboveFloor` |
| `PROP-031` | Certora | AaveAdapterGates.spec, RiskModule.spec | `borrowEnforcesGates`, `borrowNonceOneSuccessEach`, `borrowNonceChangesOnlyInBorrow`, `borrowIsReachable`, `withdrawLeavingDebtEnforcesFloor`, `removeLiquidityLeavingDebtEnforcesFloor`; `preBorrowCheckCollateralGates`, `preBorrowCheckDebtGates`, `preWithdrawCheckFreshnessGates`, `preWithdrawCheckAllowsFrozenCollateral`, `preBorrowCheckIsReachable` |
| `PROP-032` | Certora | Collateralization.spec, LPVault.spec, AaveAdapterGates.spec | `exitsMakeNoPolicyCall`; `collectFeesPaysOnlyDepositor`; `repayMakesNoPolicyRead`, `debtFreeWithdrawMakesNoPolicyRead`, `debtFreeRemovalMakesNoPolicyRead`, `repayAllAndWithdrawMakesNoPolicyRead`, `repayAtZeroDebtIsNoop`, `repayIsReachableInEveryPauseState` |
| `PROP-033` | Certora | Collateralization.spec, AaveAdapter.spec | `releaseZeroCreditOnlyByDepositor`; `bindingIsWrittenOnce`, `walletEntriesActOnCallerProxyOnly`, `repayFromAnyPayerTouchesOnlyPayerAndDebt`, `thirdPartyRepayIsReachable` |
| `PROP-034` | Certora | LPVault.spec, AaveAdapter.spec, RiskModule.spec, MarketRegistry.spec, ParameterStore.spec, LPOracle.spec, DebtOracle.spec, LPVaultSwap.spec | `returnStrayIsTimelockAndStray`; `roleChangesNeedTheRoleAdmin`; `upgradeNeedsApplicationAdmin`; `onlyRoleCanCall`, `roleChangesNeedTheRoleAdmin`, `initializeSetsTheRoleMap`, `roleAdminsNeverChange`; `settersNeedApplicationAdmin` (every setter needs `APPLICATION_ADMIN`, except that the tighten setters and `setAvanaFeeShareBps` also accept `APPLICATION_RISK_STEWARD` and `useStandbySecondSource` needs `APPLICATION_PAUSE_GUARDIAN`); `setPokeMinGasNeedsApplicationAdmin`, `onlyPokeIsPermissionless`; `debtSetPokeMinGasNeedsApplicationAdmin`; `restrictedSelectorsNeedApplicationAdmin`, `roleChangesNeedRoleAdmin` |
| `PROP-035` | Certora | LPVaultSwap.spec | `liquidateIgnoresRegistry` (an unregistered, unfrozen caller completes a liquidation), `liquidateLeavesRegistryUnchanged`, `removeKeeperKeepsFloor`, `addKeeperNeedsAdminAndUnfrozenKeeper` |
| `PROP-036` | Certora | LPVaultSwap.spec, SettlementRoute.spec, FlashSource.spec | `onFlashLoanOnlyFromFlashSourceUnderLock` (AaveAdapter holds the Lock, inside `deleverage` only), `onFlashLoanRefusedWhileLiquidating`, `liquidateTakesNoFlashLoan`; `swapCallbackRefusedOutsideHop`; `executeOperationOnlyFromLenderForOwnLoan`, `executeOperationRevertsWithoutActiveContext` |
| `PROP-037` | Certora | Collateralization.spec, LPVault.spec, AaveAdapter.spec, Lock.spec, LPVaultSwap.spec, PayoutEscrow.spec, SettlementRoute.spec | `settlePendingChecksBurnAndPaysOnlyLpVaultSwap`, `innerEntryPointsRequireLockAndCaller`; `custodyEntryPointsNeedCollateralizationUnderLock`, `collectFeesNeedsTheAaveAdapterLock`; `deleverageStepsOnlyInsideASession`; `acquireOnlyByMembersWhileFree`, `releaseOnlyByHolder`, `holderChangesOnlyThroughAcquireAndRelease`, `secondAcquireFails`, `memberAcquiresAFreeLock`; `onFlashLoanOnlyFromFlashSourceUnderLock`; `depositOnlyFromLpVaultSwapUnderLock`; `swapOnlyForLpVaultSwapUnderLock` |
| `PROP-038` | Certora | Collateralization.spec, LPVault.spec | `positionReturnsOnlyToDepositorOnClose`; `positionLeavesOnlyToDepositorOrAsStray`, `returnStrayIsTimelockAndStray`, `receivePositionRecordsTheOwnerItPulledFrom`, `unwindTakesExactlyAndCollectsPrincipal`, `releaseToDepositorPaysOnlyTheDepositor`, `collectFeesPaysOnlyDepositor`, `collectFeesIsReachableAtZeroCredit` |
| `PROP-039` | Certora | CoverageSpoke.spec | `coverDeficitOnlyAllowlistedOwnAssetAndBounded`, `coverDeficitIsReachable` |
| `PROP-040` | Certora | Hub.spec | `vaultTokenAssetKeepsSharesEqualAssets` |
| `PROP-041` | Certora | MarketRegistry.spec | `reasonIsNoneExactlyWhenNotPaused`, `pauseTransitions`, `pauseRefusesNoneAndTheCurrentReason`, `unfreezeRevertsWhilePaused`, `freezeGuardianCannotLift`, `pauseIsReachable` |
| `PROP-042` | Halmos | ParameterStore.spec | `tightenHardHealthFloorIsSafer`, `tightenGateRecoverySecondsIsSafer`, `tightenSlippageStaysAboveMarketMinimum`, `tightenConsistencyStaysAboveGlobalMinimum`, `tightenFeedToleranceStaysAboveTokenMinimum`, `tightenMinPledgeUsdOnlyRaisesWithinBound`, `loosenMinPledgeUsdOnlyLowers`, `minPledgeUsdChangesOnlyThroughItsSetters`, `livenessFloorsStayBelowTheirAllowances`, `graceSettersStayInsideGlobalBounds`, `tightenLowersScalars`, `tightenIsReachable` |
| `PROP-043` | SMTChecker | Collateralization.spec, VaultToken.spec, Lock.spec, PayoutEscrow.spec | `creditedWithinOriginalUnits`; `totalSupplyIsSumOfBalances`; `isLockedMatchesHolder`; `creditWithinTotal` |
| `PROP-044` | SMTChecker | RiskModule.spec, ParameterStore.spec, LPOracle.spec, DebtOracle.spec, LPVaultSwap.spec | `bookingArithmeticFits`; `loosenHealthFactorStepHasNoUnderflow`, `capStepArithmeticFits`; `pokeHasNoArithmeticFailureOnceSeeded`; `stressRiseArithmetic`; `settlementMathFitsIn256Bits` |
| `PROP-045` | Certora | Collateralization.spec | `accountCreditedIsSumOfRecords`, `settlePendingKeepsSupplyBacked`, `seizureDebitEqualsSnapshotDrop`, `releaseReconcilesShortfall`, `releaseZeroCreditReconcilesShortfall`, `noReconcileWhileSharesDifferFromAssets`, `settlePendingChecksBurnAndPaysOnlyLpVaultSwap`, `settlePendingRefusedDuringSeizure` |
| `PROP-046` | Certora | AaveAdapterGates.spec, RiskModule.spec | `borrowEnforcesGates`; `borrowRefusesFrozenCollateral` |
| `PROP-047` | Certora | LPVaultSwap.spec | `everySeizedUnitIsBurnedAndSettled` |
| `PROP-048` | Halmos | LPVaultSwap.spec | `floorNeverExceedsNetValueAndDustPasses` |
| `PROP-049` | Certora | LPOracle.spec, DebtOracle.spec, LPVaultSwap.spec | `disagreementStartSetOnceAndNeverMoved`; `debtDisagreementStartSetOnce`; `disagreementOrStressBlocksOnlyItsOwnReserve`, `otherMarketDisagreementDoesNotBlock` |
| `PROP-050` | Certora | RiskModule.spec | `preBorrowCheckRefusesPausedReserves`, `preWithdrawCheckRefusesPausedReserves` |
| `PROP-051` | Certora | LPVaultSwap.spec | `settlePendingSendsProceedsOnlyToCoverage`, `settlePendingOpenInEveryState` |
| `PROP-052` | Certora | PayoutEscrow.spec | `totalClaimableIsSumOfCredits`, `creditedEqualsClaimedPlusHeld`, `balanceCoversTotalClaimable`, `depositOnlyFromLpVaultSwapUnderLock`, `claimPaysWholeCreditToNamedRecipient`, `onlyTheBorrowerMovesItsCredit`, `claimIsReachable` |
| `PROP-053` | Certora | LPVaultSwap.spec | `liquidatePaysTheBorrowerOnlyTheDebtAsset`, `liquidateCallerCoversTheRepayment` (`D ≤ Kf`, `keeperOut ≥ 0`), `liquidateNeedsAWorkingRoute`, `liquidateTakesNoFlashLoan`; `liquidatePermissionless` is absent from the methods block because no such selector exists |
| `PROP-054` | Certora | Collateralization.spec, AaveAdapter.spec | `pledgeCreditsUnitsReadAfterCustody`, `recreditAddsUncreditedLiveUnits`, `releasePartialDebitsUnitsAndPaysDepositor`; `adapterCallsKeepTheBackingGap`, `pledgeMintsCreditedToCallerProxy`, `recreditMintsAddedToCallerProxy`, `withdrawBurnsTheRecordCredit`, `removeLiquidityBurnsTheDebitedUnits` |
| `PROP-055` | Certora | VaultToken.spec | `supplyChangesOnlyThroughAdapter`, `adapterOnlyFunctionsRefuseOtherCallers`, `burnNeedsNoAllowanceAndLowersExactly`, `burnWithoutAllowanceIsReachable`, `transferNeedsAllowedRecipientOnly`, `transferOnlyOnAllowedPath`, `transferFromOnlyOnAllowedPath`, `supplyByProxyAllowanceIsReachable`, `allowedRecipientIsTheFixedSet`, `allowedTransferIsTheFixedFormula`, `bindingsNeverChange` |
| `PROP-056` | Certora | PositionProxy.spec | `everyFunctionOnlyFromAdapter`, `adapterCanExecute` |
| `PROP-057` | Certora | AaveAdapterGates.spec, LPVaultSwap.spec | `pledgePauseEffects`, `recreditPauseEffects`, `topUpIsReachableWhileFrozen`, `rescueTopUpIsReachableUnderGeneralPause`, `repayWithCollateralRefusesMintPathPause`, `repayWithCollateralIsReachableUnderGeneralPause`, `repayWithCollateralIsReachableWhileFrozen`; `liquidationReadsNoPauseBreakerOrOtherFreeze` |
| `PROP-058` | Certora | AvanaTimelock.spec | `delayConstants`, `normalDelayChangesOnlyBySelfCall`, `setNormalDelayOnlyFromTheTimelock`, `updateDelayAlwaysReverts`, `scheduleBatchNeedsRequiredDelay`, `scheduleNeedsRequiredDelay`, `requiredDelayIsShortOrNormal`, `executeWindow`, `executeBatchWindow`, `expiredOperationOnlyCleanedUp`, `cancelRights` |
| `PROP-059` | Halmos | — | none: the leg that bought the debt asset with GHO does not exist, so no rule states it |
| `PROP-060` | Certora | LPVaultSwap.spec, CoverageSpoke.spec | `settlePendingSendsProceedsOnlyToCoverage`; `coverDeficitOnlyAllowlistedOwnAssetAndBounded`, `fundAddsOnlyItsOwnAsset` |
| `PROP-061` | Certora | AaveAdapterGates.spec, RiskModule.spec, MarketRegistry.spec | `borrowEnforcesGates`; `checkAaveConfigRequiresEqualDebtSets`; `activateMarketRunsTheDriftCheck`, `removeDebtReserveOnlyWhenNothingOwed` |
| `PROP-062` | Halmos | RiskModule.spec | `minimumPledgeUsesAcceptedPrice`, `minimumPledgeArithmeticFits`, `remainingRecordAtLeastMinimum` |
| `PROP-063` | Certora | LPVaultSwap.spec | `waterfallWithOracleFee`, `liquidateCallerCoversTheRepayment` (no settlement budget; the caller's funding `Kf` and top-up cover the repayment, Q-397) |
| `PROP-064` | Certora | AaveAdapter.spec, ProxyManager.spec | `bindingIsWrittenOnce`; `deployProxyOnlyAdapterAtPredictedAddress`, `atMostOneProxyPerWalletSpokeMarket`, `adapterCanDeploy` |
| `PROP-065` | Certora | Collateralization.spec, LPVault.spec, AaveAdapter.spec | `collateralizationNeverMovesSupply`, `settlePendingKeepsSupplyBacked`, `seizureDebitEqualsSnapshotDrop`, `recreditAddsUncreditedLiveUnits`, `releasePartialDebitsUnitsAndPaysDepositor`, `releaseForDeleveragePaysLpVaultSwap`, `releasePartialIsReachable`; `releaseToDepositorPaysOnlyTheDepositor`; `adapterCallsKeepTheBackingGap`, `burnSeizedRaisesGapOnlyByItsUnits`, `noAdapterFunctionLowersTheGap` |
| `PROP-066` | Certora | AaveAdapterGates.spec, RiskModule.spec, LPVaultSwap.spec | `repayMakesNoPolicyRead`, `debtFreeWithdrawMakesNoPolicyRead`, `debtFreeRemovalMakesNoPolicyRead`, `repayAllAndWithdrawMakesNoPolicyRead`, `burnSeizedMakesNoPolicyRead`; `riskModuleNeverReadsPauseOrFreeze`, `statusBodyReadsNoPauseAndChangesNoState`, `statusPauseReachesOnlyPauseFields`; `liquidationReadsNoPauseBreakerOrOtherFreeze`, `liquidationWritesNoBreakerState` |
| `PROP-067` | Halmos | Collateralization.spec, AaveAdapterGates.spec, RiskModule.spec | `rescueUnitsWithinCredited`, `accountRescueUnitsIsSumOfRecords`; `withdrawLeavingDebtEnforcesFloor`, `removeLiquidityLeavingDebtEnforcesFloor`; `postHealthCheckEnforcesTheFloor`, `postHealthCheckWithoutRescueIsAaveHf`, `floorConstantIsOnePointZeroFive`, `hfExRoundsAgainstTheBorrower` |
| `PROP-068` | Certora | LPVaultSwap.spec, SettlementRoute.spec | `everySwapCarriesAPositiveMinOut`, `settlePendingLegMinimum`; `swapDeliversAtLeastMinOut`, `swapIsReachable` |
| `PROP-069` | Halmos | LPVaultSwap.spec | `waterfallWithOracleFee`, `oracleFeeMonotoneAndIndependentOfProceeds` |
| `PROP-070` | Certora | AaveAdapter.spec, RiskModule.spec, MarketRegistry.spec, ParameterStore.spec, LPOracle.spec, DebtOracle.spec, AvanaTimelock.spec, LPVaultSwap.spec | `adminRolesOnlyTimelock`; `adminRolesOnlyTimelock`; `adminRolesOnlyTimelock`; `adminRolesOnlyTimelock`; `adminRolesOnlyTimelock`; `adminRolesOnlyTimelock`; `timelockIsItsOwnOnlyAdmin`; `initializeGrantsAdminRolesOnlyToTimelock`, `adminRolesHaveOneHolder` |
| `PROP-071` | Certora | MarketRegistry.spec | `freezeAddressGates`, `onlyUnfreezeAddressLiftsAFreeze`, `freezeLimitIsTwenty`, `noCallFreezesAProtectedAddress`, `freezeAddressIsReachable` |
| `PROP-072` | Certora | Collateralization.spec, AaveAdapter.spec, LPVaultSwap.spec | `releaseForDeleveragePaysLpVaultSwap`; `deleverageStepsOnlyInsideASession`, `repayWithCollateralNeverRaisesDebtAndRepaysFirst`; `deleverageMakesNoDrawFeeOrBonusPayment` |
| `PROP-073` | Certora | AvanaTimelock.spec | `normalDelayBounds`, `shortListWithinEligible`, `shortEligibleIsImmutable`, `timelockNeverShortEligible`, `cancelRights`, `mixedOperationCancellableByAnyCanceller` |
| `PROP-075` | Certora | Lock.spec | `acquireRefusedOutsideTheTwoMembers`, `lockMembersDistinctAndSet` |
| `PROP-076` | Certora | ProxyManagerIsolation.spec | `deployProxyAtPredictedAddress`, `oneProxyPerWalletSpokeMarket`, `distinctAccountsHaveDistinctProxies` |
| `PROP-078` | Certora, Halmos | RiskModuleDrift.spec, RiskModule.halmos.t.sol | `driftCheckRefusesDriftedSettings`, `driftCheckRefusesAReplacedImplementation`, `borrowSideRefusesAReplacedImplementation`, `pokeConfigReportsAReplacedImplementation`; `check_PROP_078_implementationNotCurrentIsDrift` |
| `PROP-080` | Certora | FlashSource.spec | `flashLoanOnlyForLPVaultSwap`, `executeOperationOnlyFromLenderForOwnLoan`, `executeOperationRevertsWithoutActiveContext`, `flashLoanRefusesTheLiquidatedHub`, `flashLoanWithinAvailableLiquidity`, `flashLoanWithinPremiumCap`, `flashLoanCanComplete`, `flashLoanCanCompleteWithPremium` |
| `PROP-083` | Certora | UniswapV3Integration.spec, SlipstreamIntegration.spec | `validatePositionRequiresExactRange`, `receivePositionRequiresExactRange`; `validatePositionRequiresExactRange`, `receivePositionRequiresExactRange` |
| `PROP-084` | Certora | LPVaultSwap.spec | `waterfallWithOracleFee`, `waterfallBalances` (no settlement budget or market window, Q-397) |
| `PROP-099` | Certora | VaultTokenFactory.spec | `deployOnlyByTimelock`, `registerOnlyByTimelock`, `tokenOfIsWriteOnce`, `lpVaultOfIsWriteOnce`, `isVaultTokenOnlyTurnsTrue`, `deployLandsAtThePredictedAddress`, `secondDeployForAMarketReverts`, `bindingsNeverChange`, `timelockCanDeploy`, `timelockCanRegister` |

## Rules that fail against the 5.2 text

These rules state their 5.2 row exactly. Each fails on the text as written, for the reason given; the change in the last column makes it hold. The rule stays as written until the row changes.

| Rule | Row | Why it fails | Change that makes it hold |
|---|---|---|---|
| `expiredOperationOnlyCleanedUp` (AvanaTimelock.spec) | `PROP-058` | `SPEC-GOV-013` lets a canceller cancel an expired operation. | "after that only `cleanupExpiredOperation` or a permitted `cancel` touches the operation". |
| `borrowRefusesFrozenCollateral` (RiskModule.spec) | `PROP-046` | `REQ-ADAPTER-019` refuses only frozen collateral reserves with supplied shares; collateral enabled on a frozen reserve with 0 shares passes. | "enabled as collateral with supplied shares > 0". |
| `deleverageMakesNoDrawFeeOrBonusPayment` (LPVaultSwap.spec), GHO recipients | `PROP-072` | The row names three GHO recipients, but for a non-GHO debt reserve `deleverage` pays GHO to the reserve's buy route (`SPEC-LIQ-020`), so the row is false for non-GHO debt; the rule is stated for GHO debt, where the row holds as written. | "the debt Spoke (for a non-GHO debt reserve, through that reserve's buy route)". |
| `deleverageMakesNoDrawFeeOrBonusPayment`, `deleverageNeedsLiveOracles` (LPVaultSwap.spec) | `PROP-072`, `PROP-074` | No summary reproduces the flash source's callback into LPVaultSwap's `onFlashLoan`, so the flash-funded `deleverage` core is unreachable and the sanity check reports the rules vacuous. Liquidation rules are not affected: `liquidate` takes no flash loan. | A summary of `IFlashSource.flashLoan` (`src/flash/`) that calls LPVaultSwap's `onFlashLoan` back and pulls `amount + premium`; no GHO flash minter is involved (2.11 `REQ-FLASH-010`). |
| `adminRolesHaveOneHolder` (LPVaultSwap.spec) | `PROP-070` | `ILPVaultSwap` declares no `TIMELOCK()` view, so the invariant cannot name the timelock and is stated as "one holder", which is not inductive. | `TIMELOCK()` on `ILPVaultSwapViews`; the invariant becomes `hasRole(R, a) ⇒ a == TIMELOCK()`. |

## Running

Requirements: certora-cli 8.20.3 in `contracts/.venv` (`requirements.txt`), Java 21 (local CVL type checking), solc 0.8.28 on `PATH` as `solc-0.8.28`, the Soldeer dependencies (`forge soldeer install`), the implementation at the paths the confs name, and a key in `CERTORAKEY`.

```bash
cd contracts
python3 certora/check-methods.py                                    # methods entries against the interfaces
export CERTORAKEY=<key>                                              # Certora API key
.venv/bin/certoraRun certora/conf/Collateralization.conf             # one contract, every rule
.venv/bin/certoraRun certora/conf/Collateralization.conf --rule seizureDebitEqualsSnapshotDrop
.venv/bin/certoraRun certora/conf/VaultToken.conf --compilation_steps_only   # compile and type-check, no cloud job
for conf in certora/conf/*.conf; do .venv/bin/certoraRun "$conf" --wait_for_results all; done
```

A job that runs past `--global_timeout` is halted and writes no `output.json`; its finished rules are in the job log, and the rules without a result count as TIMEOUT. The ParameterStore and MarketRegistry parametric rules and most Collateralization rules need more than 40 minutes; run them one rule per job (`--rule <name>`) without a global timeout.

In CI the `fast-security` job runs the methods check on every push and pull request (`script/security-fast.sh`, step `cvl`), and the `certora` job of `.github/workflows/contracts.yml` runs every conf in `certora/conf/` with `--wait_for_results all`; that job installs Java 21 (Temurin) and the static solc 0.8.28 and is gated on the `CERTORAKEY` repository secret.

## Results

[RUNS.md](RUNS.md) logs every run of this folder: date, command, tool versions, counts and exit code. Prover results are filed under `audit/formal/` as one report per property: property ID, scope, conf and spec, the summaries and assumptions above, certora-cli and prover versions, the job URL, the result and the reproduction command (`.venv/bin/certoraRun certora/conf/<Contract>.conf --rule <rule>`). A counterexample is a `FINDING-NNN` in [5.3](../../spec/05-verification/03-audit-findings.md) with the rule, the call trace, the requirement or invariant it breaks, the severity and status of 5.3, and the test or property that confirms the fix; the 5.2 result column records Proved or Counterexample for the row. A rule that fails the sanity check counts as failed until its preconditions are fixed.
