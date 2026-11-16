# Local stack

The chains, contracts and services the webapp runs on locally, started by one command, and the operator flow that adds a Hub to them.

| Piece | What runs |
|---|---|
| Ethereum (local) | anvil, chain 31337, network name `ethereum`, a block every 12 s, port 8545 (`STACK_PORT_ETHEREUM`) |
| Base (local) | anvil, chain 31338, network name `base`, a block every 2 s, port 8546 (`STACK_PORT_BASE`) |
| Avana | The deploy steps of `script/deploy/step.sh` on each chain. The first release holds one Aave Hub per chain ("Avana Ethereum Hub", "Avana Base Hub", tier 3) with its Lend Spoke and debt assets; the chain's Hub file adds its CDP Spokes and markets. Protocol parameters come from `script/deploy/config/anvil.json`; the values the Aave DAO sets come from `test-values.json` |
| Indexer | One Ponder process for both chains (PGlite), port 42070, reading each node through `script/e2e/rpc-recorder.ts` |
| Convex | One anonymous local deployment of `services/convex` (no account), fed by the indexer export; `convex-driver.ts` runs its chain jobs on the local chains |
| Keeper | Active on both chains, signing from the `keeper` keystore |
| Monitor | Both chains, every alert to its log |
| Activity | One loop per chain: lends, borrows, repays and swaps (`activity.ts`) |
| Webapp | Started from `webapp/scripts/local-stack.mjs` when that file exists (the webapp's own entry, which reads `stack.env`) |

Needs: anvil, forge, cast, node 22.12 or later, `npm ci` at the repo root and `make build build-aave build-external` in `contracts/`. Nothing runs in Docker.

## Commands

From `contracts/`:

```bash
node script/local/stack.ts up
```

```bash
node script/local/stack.ts status
```

```bash
node script/local/stack.ts check
```

```bash
node script/local/stack.ts replay
```

```bash
node script/local/stack.ts add-hub script/local/hubs/growth.json --chain ethereum
```

```bash
node script/local/stack.ts down
```

- `up` starts both nodes, deploys Avana on each, starts every service, switches the chains to their own block time and releases the chain's pending Hub files (`--no-hubs` skips them). It resumes: a deploy step that passed is never run again, the first step that failed runs again, and a process that is running is kept. `deploy` runs only the chains and their first release.
- When a step fails, `up` stops with the step and its log. The nodes, the indexer store and Convex keep running. Fix the cause and run `up` again: only the failed step and what follows run.
- `check` is the fast re-check: each manifest against its chain, the indexer at both heads with no error line, and Convex against each chain (`script/e2e/replay-check.ts`). It changes nothing, so a fix to a check or to the data layer is checked in minutes.
- `replay` runs the indexer replay ([services/REPLAY.md](../../../services/REPLAY.md)) on the running stack. It closes a daily sample on each chain (the chain clock moves two days), then stops the live indexer at the head. A second indexer indexes every block again into a fresh schema, and its tables must equal the live ones. The live indexer then starts again, and `replay-check.ts` checks the local Convex against each chain.
- While `check` or `replay` runs, the chains mine only on transactions and the activity loops pause, so the heads stand still.
- `down` stops every process and saves each chain's state (`anvil_dumpState`). `up` loads it back. `--keep-chains` stops only the services.

Logs are in `deployments-local/stack/logs/<process>.log`, one per process and one per deploy step (`<chain>.<release>.<step>.log`). Each chain's step record is `deployments-local/<network>/stack-status.json`. `deployments-local/stack/stack.env` lists the endpoints and holds no secret.

| Variable | Default | Effect |
|---|---|---|
| `STACK_FORK` | off | `1` forks Ethereum and Base at the blocks pinned in `fork.json`. The chains keep their local IDs (31337, 31338) |
| `ETHEREUM_FORK_RPC_URL`, `BASE_FORK_RPC_URL` | none | The networks' RPC endpoints (comma-separated for several). Never in the repository: set in the environment, or stored encrypted next to the keystores with `stack.ts secrets`. anvil reads them through a local proxy (`fork-proxy.ts`, retries with backoff), so they appear on no command line. `up` stops if one is missing in fork mode |
| `STACK_FORK_BLOCK_ETHEREUM`, `STACK_FORK_BLOCK_BASE` | `fork.json` | Another fork block |
| `STACK_GENESIS_DAYS_AGO` | 35 | Chain time at genesis. Each release moves the clock past its timelock delays (about 15.5 days), so the first release lands near the present |
| `STACK_MAX_MARKETS` | 64 | The MarketRegistry's market limit, fixed at deployment |
| `STACK_CONVEX_DIR`, `STACK_WEBAPP_DIR` | this checkout | Run another checkout's `services/convex` or `webapp` (its `node_modules` installed) |
| `STACK_BASH` | Git Bash | The bash that runs the deploy steps |

## Signers

No key is written in clear, passed on a command line or kept in an env file. Each signer is an encrypted Foundry keystore in `deployments-local/stack/keystore`, made by `cast wallet new`. All share one random password in a file only the user can read.

| Keystore | Signs |
|---|---|
| `deployer` | Every deploy and release step on both chains; the test tokens' minter and the First-Loss Reserves' funder |
| `keeper` | The liquidation bot's transactions; it is also the operator helper's signer in each chain's config |
| `treasury` | The fee recipient (`ParameterStore.feeRecipient`): the liquidation fee share and the front-end fee. Never the deployer or the keeper: the stack refuses to start if any two of the three are one account |
| `faucet` | The webapp's test funds |
| `activity-funds` | Transfers test tokens to the activity loop's simulated users |
| `ocr-0` … `ocr-3` | The four OCR2 oracles that sign every price report |

The governance Safe, the guardians and the Aave governance executor stand in for multisigs and governance. They send through anvil's unlocked senders (`--auto-impersonate`), as in the rehearsal. So do the activity loop's simulated users, which are addresses with no key.

## Adding a Hub

One input file per Hub and one command. The chain's Hub files live in `contracts/script/deploy/hubs/<chain>/<hub>.json` (`<chain>` is `ethereum` or `base`); `up` releases every one not released yet, in name order, once the services run. `hubs/growth.json` here is an example to add by hand:

```bash
node script/local/stack.ts add-hub script/local/hubs/growth.json --chain ethereum
```

It runs three steps, each a plain function with JSON input and output in `operator/hub.ts`, so an operations dashboard can call them too:

1. **`planHub(config, input)`** turns the chain's current config and the Hub file into the next config. It is pure: an invalid input is refused with every error listed, and nothing is touched. The result is written to `deployments-local/<network>/config-hub-<label>.json`, with a summary in `plan-hub-<label>.json`.
2. **`releaseHub(chain, release, config)`** runs the release steps on that config, each acting only on what it adds:
   - the Aave side: Hub, Spokes, assets and loss layers;
   - the timelock operations;
   - the listing: tokens, feeds, CDP Spokes, First-Loss Reserves, credit lines, DebtOracles, routes and markets;
   - the listing metadata and activation;
   - the manifest, produced and verified.
   Each step is recorded, and a rerun resumes at the failed one. The chain mines on every transaction meanwhile, then returns to its block time.
3. **`addHub({ chain, hubFile })`** runs both and returns the Hub's listed markets.

The indexer follows the new Hub, its CDP Spokes and its markets from their events (`HubRecorded`, `SpokeApproved`, `MarketRegistered`). Convex samples them from the chain and loads their names from the listing metadata the release commits to (scopes `hub`, `lend`, `asset` and `pool`). No Convex row is written by hand.

| Field | Contents |
|---|---|
| `hub` | `label` (config name), `tier` (1 stable, 2 correlated, 3 volatile), `name` and `description` (its page). A label already on the chain extends that Hub: only its new Spokes, assets and markets are added |
| `lendSpoke` | The Hub's Lend Spoke label (default `lend<Label>`) |
| `spokes` | CDP Spokes, many per venue: `label`, `integration` (`uniswap-v3` or `slipstream`), `category` (Stable, Volatile, Blue-chip, …), optional `name` (default `<venue> <category>`) and `description` (the Spoke's page) |
| `lendAssets` | What the Hub lends: `symbol`, `category`. A token new to Aave on the chain also takes `new`: `drawCap`, `bootstrapSupply`, `coverageMinimum`, `offsetMinimum` (whole tokens), `stressRiseBps`, `floorRoundingAllowance` (base units, at most $1), optional `creditLineWhole`, `debtMinWhole`, `debtMaxWhole` |
| `borrowable` | Per CDP Spoke, the symbols it lends; the first is each market's default debt asset |
| `collateral` | Pool tokens. A listed token only gains this Hub; a new one takes `deviationBps`, `collateralFactorBps`, `tokenCapUsd`, `isUsdStable` |
| `markets` | `pool` (a pool of the chain's world), `spoke`, optional `tickLower` and `tickUpper` (full range when omitted), `poolRiskFactorBps`, `maxLiquidationBonus`, `consistencyToleranceBps`, `marketUsdCap`, `topUpSliceUsd`, optional `name`, `slug`, `category`, `description`. The market key is (integration, pool, range) on the whole chain: one pool on two Spokes needs two ranges |

The collateral factor, slippage allowance and routes are derived as the rehearsal does:
- the collateral factor is min(token collateral factors) × the pool risk factor;
- the slippage allowance is the largest the liquidation bonus allows;
- each pool token gets two pool-disjoint routes into each asset its Spoke lends.

A debt asset with no `hubs` list in the config is lent on every Hub, a new one included.

Tokens and pools a Hub file needs that the test world lacks go in `contracts/script/deploy/hubs/<chain>/world.json` (`tokens`, `uniswapPools`, `slipstreamPools`, as in the config's `world`). Step 02 deploys them with the rest of the world, so they must be there before the chain's first deploy.

## Values the DAO sets

Caps, credit lines, First-Loss Reserve and DAO offset amounts, and speed limits are set by the Aave DAO and governance on a real network, never by a release config or a Hub file. The local stack needs some to run: `test-values.json` holds them (per debt asset, per collateral token with a default, per market with a default), and the stack merges them into each chain's config. Hub files carry structure and risk parameters only.
