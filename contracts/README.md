# contracts

Foundry workspace for the Avana core on Aave V4. Flows: [LIFECYCLES.md](LIFECYCLES.md).

## Core

| Contract | Folder | Form |
|---|---|---|
| AaveAdapter | `src/adapter/` | User entry point; one account proxy per wallet and market (`AccountProxy`) |
| RiskModule | `src/risk/` | Listing, routing, borrow checks, fee and keepers (`BandMath`, `AaveConfigLogic`) |
| LPVault | `src/vault/` | NFT custody and floor credit (`FloorCreditMath`) |
| VaultToken | `src/token/` | ERC-20 collateral, one per band market |
| LPOracle | `src/oracle/` | Stateless vault-token price, one per market (`LPPriceMath`) |
| LiquidationModule | `src/liquidation/` | In-kind partial liquidation (`LiquidationMath`) |
| FirstLossReserve | `src/reserve/` | Avana reserve and DAO Deficit Offset |

Outside the core count: `src/integrations/` (Uniswap v3, Uniswap v4, Aerodrome Slipstream), `src/periphery/` (FlashloanRepay, SwapCalls), `src/access/` (role ids), `src/dependencies/`.

Each core folder holds the contract, its interface, storage, libraries and a `DESIGN.md`.

## Size limits

`script/check-core-size.sh` counts code lines (no blanks, no comment-only lines) per core folder and fails CI above the limits.

| Limit | Value | Today |
|---|---|---|
| Each core contract | ≤ 800 | max 726 (RiskModule) |
| Core total | ≤ 4,000 | 2,537 |
| Policy (AaveAdapter + RiskModule) | ≤ 1,500 | 1,082 |

A `.sol` file under `src/` outside the core folders and the listed outside folders fails the report.

## Setup

```bash
cd contracts
cp .env.example .env
forge soldeer install
script/install-security-tools.sh   # optional: Slither, Halmos, Echidna, Medusa, hevm, Mythril, Aderyn, Semgrep, certora-cli
```

Pinned: Foundry 1.9.0 (`.foundry-version`), Solidity 0.8.28 / `cancun`, dependencies in `soldeer.lock`, Python tools in `requirements*.txt`, binaries by sha256 in `script/install-security-tools.sh`.

### Reproducible Linux build

Run a clean dependency install and build from a Linux-native checkout (for example
`~/avana-monorepo` in WSL), not from `/mnt/c`. The pinned Aave V4 tree contains
`certora/basic/specs/aux/AaveMath.spec`; `aux` is a reserved Windows path, so a
fresh Windows Soldeer install is unsupported.

```bash
cd ~/avana-monorepo/contracts
forge --version                    # 1.9.0
forge soldeer install
FOUNDRY_PROFILE=permit2 forge build -j 2
FOUNDRY_PROFILE=univ4 forge build -j 2
forge build -j 2
```

`soldeer.lock` is the source of truth for every dependency. In particular, the
compatible Uniswap V4 pair is core `e50237c43811bd9b526eff40f26772152a42daba` and
periphery `ea2bf2e1ba6863bb809fc2ff791744f308c4a26d`; Aave V4 is
`a3ef63ea6415d25237a9775bf66e76e9993561c2`. Confirm the installed Git sources
with `git -C dependencies/<name-version> rev-parse HEAD`. A clean Linux install
builds the V4 profile with these pins; a missing `PoolOperation.sol` indicates
stale or different V4 dependency sources rather than this lockfile pair.

## Commands

```bash
forge build
forge test -j 2                                   # default profile
forge test --match-path test/unit/RiskModule.unit.t.sol
FOUNDRY_PROFILE=ci forge test                     # CI depth
FOUNDRY_PROFILE=invariant forge test              # deep invariants
FOUNDRY_PROFILE=fork forge test                   # needs RPC_MAINNET, RPC_BASE
FOUNDRY_PROFILE=differential forge test           # FFI against the Python reference
script/check-core-size.sh                         # size report
script/check-sizes.sh                             # EIP-170 margins
script/check-coverage.sh                          # per-file branch coverage, 80% floor
script/security-fast.sh                           # fmt, lint, Slither, Aderyn, Semgrep, solhint, 4naly3er
script/security-slow.sh                           # Echidna, Medusa, Halmos, hevm, Mythril
```

## Profiles

| Profile | Use |
|---|---|
| `default` | Local runs; fuzz 1,000, invariants 64 × 64 |
| `ci` | Fuzz 10,000, invariants 1,000 × 100 |
| `lite` | Fast edit loop, optimizer off, own `out-lite/` |
| `invariant` | `test/invariant/`, 2,000 × 400 |
| `fork` | Ethereum and Base forks at blocks pinned in `test/utils/fixtures/ForkConstants.sol` |
| `differential` | `test/differential/` against an exact Python reference |
| `smt` | SMTChecker build |
| `coverage` | Exact source maps for `forge coverage` |
| `aave` | Aave V4 artifacts with Aave's compiler settings, into `out-aave/` |

## Layout

| Path | Contents |
|---|---|
| `src/` | Contracts (above) |
| `test/` | Unit, fuzz, integration, invariant, fork, differential, Halmos: [test/README.md](test/README.md) |
| `certora/` | CVL specs and confs, run locally: [certora/README.md](certora/README.md) |
| `script/` | Deploy steps, local chain, CI helpers: [script/README.md](script/README.md) |
| `security/` | Triage files, coverage minimums, size margins, mutation layers |
| `aave-deploy/` | Aave V4 role setup for the local fixture |

## Deploying

`script/deploy/` runs numbered `forge script` steps per network config (`script/deploy/config/<network>.json`, `AVANA_NETWORK`): factories, Aave V4 and the local world, Avana core, operations, payloads, First-Loss reserves, market listing and keeper funding. `make e2e-local` rehearses the whole sequence on anvil. Details: [script/README.md](script/README.md).

## CI

[`contracts.yml`](../.github/workflows/contracts.yml): fast suite on every PR (build, tests in 3 shards, size report, gas, ABIs, liquidator); `full` adds 10 shards, coverage and the fast security tier; `long` adds deep invariants, fork, differential and SMTChecker. The slow security tier and mutation gates are manual workflows. Certora is not run in CI.
