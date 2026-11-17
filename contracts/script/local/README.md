# Local stack

The chains, contracts and services the webapp runs on locally, started by one command, and the operator flow that adds a Hub to them.

| Piece | What runs |
|---|---|
| Ethereum (local) | anvil, chain 31337, network name `ethereum`, a block every 12 s, port 8545 (`STACK_PORT_ETHEREUM`) |
| Base (local) | anvil, chain 31338, network name `base`, a block every 2 s, port 8546 (`STACK_PORT_BASE`) |
| Avana | The deploy steps of `script/deploy/step.sh` on each chain. The first release holds one Aave Hub per chain ("Avana Ethereum Hub", "Avana Base Hub", tier 3) with its Lend Spoke and debt assets; the chain's Hub file adds its CDP Spokes and markets. Protocol parameters come from `script/deploy/config/anvil.json`; the values the Aave DAO sets come from `test-values.json` |
| Indexer | One Ponder process for both chains (PGlite), port 42070, reading each node through `script/e2e/rpc-recorder.ts` |
| Convex | One anonymous local deployment of `services/convex` (no account), fed by the indexer export; `convex-driver.ts` runs its chain jobs on the local chains |
| Keeper | Active on both chains, signing from its own keystore |
| Monitor | Both chains, every alert to its log |
| Faucet | `services/faucet` in fork mode on both chains, port 42080, its tokens and prices from each chain's manifest; the webapp gets `FAUCET_URL` |
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
- `replay` runs the indexer replay ([services/REPLAY.md](../../../services/REPLAY.md)) on the running stack. It reads the last samples closed on each chain while the chain has passed no sampler block since, or else closes a daily sample (the chain clock moves two days, an hour of blocks per sample), then stops the live indexer at the head. `check` does the same. Delete `deployments-local/stack/replay/sample-block-<chain>` to close new samples. A second indexer indexes every block again into a fresh schema, and its tables must equal the live ones. The live indexer then starts again, and `replay-check.ts` checks the local Convex against each chain.
- While `check` or `replay` runs, the chains mine only on transactions and the activity loops pause, so the heads stand still. An indexer started then waits for the node's head to change, so while it lags a chain mines one empty block every 30 seconds; the table comparison leaves out `chain_progress`, the head each indexer stopped at.
- `down` stops every process and saves each chain's state (`anvil_dumpState`, streamed to `deployments-local/<network>/anvil-state.json`, so a state of any size is saved). `up` starts the node with `--load-state` on it. A state saved as `anvil-state.hex` by an earlier stack is converted once. A restored node has every block and log but no state before the block it was restored at: the indexer starts its hourly samples there (`INDEXER_STATE_FLOOR`, probed per chain when the live indexer starts; a replay uses the same floors), and `check` closes new samples when its last one is below it. `--keep-chains` stops only the services.

Logs are in `deployments-local/stack/logs/<process>.log`, one per process and one per deploy step (`<chain>.<release>.<step>.log`). `convex.log` runs verbose, so it records the local backend's exit code; `up` restarts a Convex whose backend no longer answers and keeps the previous log as `convex.prev.log`. Each chain's step record is `deployments-local/<network>/stack-status.json`. `deployments-local/stack/stack.env` lists the endpoints and holds no secret.

| Variable | Default | Effect |
|---|---|---|
| `STACK_FORK` | off | `1` forks Ethereum and Base at the blocks pinned in `fork.json`. The chains keep their local IDs (31337, 31338) |
| `ETHEREUM_FORK_RPC_URL`, `BASE_FORK_RPC_URL` | none | The networks' RPC endpoints (comma-separated for several). Never in the repository: set in the environment, or stored encrypted next to the keystores with `stack.ts secrets --only <name>`. anvil reads them through a local proxy (`fork-proxy.ts`, retries with backoff), so they appear on no command line. `up` stops if one is missing in fork mode |
| `STACK_FORK_BLOCK_ETHEREUM`, `STACK_FORK_BLOCK_BASE` | `fork.json` | Another fork block |
| `STACK_GENESIS_DAYS_AGO` | 35 | Chain time at genesis. Each release moves the clock past its timelock delays (about 15.5 days), so the first release lands near the present |
| `STACK_MAX_MARKETS` | 128 | The MarketRegistry's market limit, fixed at deployment |
| `STACK_CONVEX_DIR`, `STACK_WEBAPP_DIR` | this checkout | Run another checkout's `services/convex` or `webapp` (its `node_modules` installed) |
| `STACK_BASH` | Git Bash | The bash that runs the deploy steps |

## Signers

Every signer is an encrypted Foundry keystore, created and held by the operator outside the repository. No key is written in clear, passed on a command line or kept in an env file. The multisig and governance stand-ins send through anvil's unlocked senders, as in the rehearsal.

## Adding a Hub

One input file per Hub and one command. The chain's Hub files live in `contracts/script/deploy/hubs/<chain>/<hub>.json` (`<chain>` is `ethereum` or `base`); `up` releases every one not released yet, in name order, once the services run. `hubs/growth.json` here is an example to add by hand:

```bash
node script/local/stack.ts add-hub script/local/hubs/growth.json --chain ethereum
```

It runs three steps, each a plain function with JSON input and output in `operator/hub.ts`, so an operations dashboard can call them too:

1. **`planHub(config, input)`** turns the chain's current config and the Hub file into the next config. It is pure: an invalid input is refused with every error listed, and nothing is touched. The result is written to `deployments-local/<network>/config-hub-<file>.json`, with a summary in `plan-hub-<file>.json` (`<file>` is the Hub file's name: each file is its own release, `hub-<file>`, so several files can add Spokes to one Hub).
2. **`releaseHub(chain, release, config)`** runs the release steps on that config, each acting only on what it adds:
   - the Aave side: Hub, Spokes, assets and loss layers;
   - the timelock operations;
   - the listing: tokens, feeds, CDP Spokes, First-Loss Reserves, credit lines, DebtOracles, routes and markets;
   - the listing metadata and activation;
   - the manifest, produced and verified.
   Each step is recorded, and a rerun resumes at the failed one. The chain mines on every transaction meanwhile, then returns to its block time.
3. **`addHub({ chain, hubFile })`** runs both and returns the Hub's listed markets.

The indexer follows the new Hub, its CDP Spokes and its markets from their events (`HubRecorded`, `SpokeApproved`, `MarketRegistered`). Convex samples them from the chain and loads their pages from the listing metadata the release commits to (version 2, scopes `hub`, `spoke`, `lend`, `asset`, `pool` and `token`). No Convex row is written by hand.

A Hub file holds structure and page text; every number is in `test-values.json`. Page text is optional and generated where it is missing, except the risk text: on a chain that is not a development node (31337, 31338), every market, lend asset and borrowable asset needs `risk`, and `planHub` refuses the file without it.

| Field | Contents |
|---|---|
| `hub` | `label` (config name), `tier` (1 stable, 2 correlated, 3 volatile), and its page: `name`, `description`, `faqs`, `links`, `iconUrl`, `disclosures` (`borrow`, `lend`: the risk disclosures of every borrow and lend page). A label already on the chain extends that Hub: only its new Spokes, assets and markets are added |
| `lendSpoke` | The Hub's Lend Spoke label (default `lend<Label>`) |
| `spokes` | CDP Spokes, many per venue: `label`, `integration` (`uniswap-v3` or `slipstream`), `category` (Stable, Volatile, Blue-chip, …), and its page: `name` (default `<venue> <category>`), `description`, `faqs`, `links`, `iconUrl` |
| `lendAssets` | What the Hub lends: `symbol`, `category` (`stable`, `crypto` or `stock`), and its Lend page: `name`, `description`, `faqs`, `risk` |
| `borrowAssets` | The page of each borrowable asset, used for its debt reserve on every CDP Spoke: `symbol`, `name`, `description`, `faqs`, `risk` |
| `tokens` | Token pages: `symbol`, `name` (default the token's own), `iconUrl`, `links` (also the links and icon of the token's Lend and borrow pages) |
| `borrowable` | Per CDP Spoke, the symbols it lends; the first is each market's default debt asset |
| `collateral` | Pool tokens: `symbol`, `isUsdStable`. A listed token only gains this Hub |
| `markets` | `pool` (a pool of the chain's world), `spoke`, optional `tickLower` and `tickUpper` (full range when omitted), `name` (config name, the test values' key), `slug`, `category`, and its page: `description`, `longText`, `faqs`, `links`, `risk`. The market key is (integration, pool, range) on the whole chain: one pool on two Spokes needs two ranges |

`links` is `{ website, x, docs, github, audits: [{ label, href }] }`, all https. `risk` is `{ summary, reviewedAt (YYYY-MM-DD), factors: [{ id (camelCase), label, level (low, moderate, elevated, high), text }] }`. The listing metadata adds `risk.dependencies` to each market (its pool and factory, route pools, every feed, its Hub and CDP Spoke), read from the config, and, on the local stack only, `risk.factors[].bps` from the test values' `markets.<name>.riskFactorBps`.

The collateral factor, slippage allowance and routes are derived as the rehearsal does:
- the collateral factor is min(token collateral factors) × the pool risk factor;
- the slippage allowance is the largest the liquidation bonus allows;
- each pool token gets two pool-disjoint routes into each asset its Spoke lends.

A debt asset with no `hubs` list in the config is lent on every Hub, a new one included.

Tokens and pools a Hub file needs that the test world lacks go in `contracts/script/deploy/hubs/<chain>/world.json` (`tokens`, `uniswapPools`, `slipstreamPools`, `uniswapV4Pools`, as in the config's `world`). Step 02 deploys them with the rest of the world, so they must be there before the chain's first deploy.

## Values the DAO sets

Caps, credit lines, First-Loss Reserve and DAO offset amounts, and speed limits are set by the Aave DAO and governance on a real network, never by a release config or a Hub file. The local stack needs some to run: `test-values.json` holds them (per debt asset, per collateral token with a default, per market with a default), and the stack merges them into each chain's config. Hub files carry structure and page text only.

## The app on the test networks

`script/testnet/app.ts` runs the same services and the webapp on Sepolia (11155111) and Base Sepolia (84532) once both are deployed by the test-network deploy (`deployments-local/sepolia`, `deployments-local/base-sepolia`). From `contracts/`:

```bash
node script/testnet/app.ts up --chains sepolia,base-sepolia --deployments <deploying worktree>/contracts/deployments-local
```

```bash
node script/testnet/app.ts status
```

```bash
node script/testnet/app.ts down
```

| Piece | What runs |
|---|---|
| RPC proxies | One per network (`script/testnet/rpc-proxy.ts`, ports 8665 and 8666): HTTP with retries, WebSocket tunnelled, CORS for the webapp only. Every service and the browser read the network through it, so the RPC URL is held by the proxy alone |
| Indexer | Ponder on the `testnet` network set (PGlite, port 42170), from each release's first block. Its schema is `testnet_<hash>` of the manifests and the indexer's code (recorded in `deployments-local/testnet-app/indexer-schema`): after a Hub release rewrites a manifest, `up` starts it on the new schema, a full reindex |
| Convex | A local deployment of `services/convex`, its crons on the test networks (`AVANA_CHAIN_IDS=11155111,84532`), each chain's `deployments` row from its manifest |
| Monitor, keeper | The `testnet` network set. The keeper observes; with `KEEPER_KMS_KEY_ID_SEPOLIA` or `KEEPER_KMS_KEY_ID_BASE_SEPOLIA` set it is active on that chain (a test-network keeper never signs from a local keystore) |
| Faucet | Test-network mode on port 42180: it mints the grant's test tokens from the deployer keystore of the private config (`AVANA_TESTNET_CONFIG`); `--gas-eth 0.01` also tops each wallet up to that much test ETH |
| Webapp | `next dev` on http://127.0.0.1:3100, chain IDs 11155111 and 84532, the "Sepolia" network badge |

Inputs, none in the repository: the RPC URLs `SEPOLIA_RPC_URL` and `BASE_SEPOLIA_RPC_URL` (the environment, or the deploying worktree's encrypted secrets of `stack.ts secrets`; optional `SEPOLIA_WS_URL` and `BASE_SEPOLIA_WS_URL` when the provider's WebSocket is not its https URL as wss), and `AVANA_TESTNET_CONFIG`. Every line the command prints is redacted. Its logs, process records and stores are in `deployments-local/testnet-app/` (`app.env` lists the endpoints), apart from the local stack's, and none of its ports is the local stack's, so both run on one machine. The indexer and Convex refuse to share a worktree's stores with a running local stack (`APP_CONVEX_DIR` runs another worktree's Convex). `APP_PORT_<NAME>` moves a port.
