# Fork tests

## What it proves

Fork tests run Avana against the real deployed code at a pinned block: Uniswap v3 on an Ethereum fork, every Aerodrome Slipstream generation on a Base fork, the Aave V3 Pool flash source (`TEST-118`), the GSM and LitePSM peg-module routes (`TEST-119`, `TEST-120`), Chainlink feeds and the Base sequencer feed (`TEST-117`, `TEST-275`), the unwind rounding of each AMM integration against the pinned AMM code (`TEST-264`, `TEST-265`), every mock's fork counterpart (`TEST-005`), and the deployment checks against a manifest (`TEST-134`, `TEST-135`).

## How to run

```bash
cd contracts
RPC_MAINNET=<archive RPC> MAINNET_FORK_BLOCK=<pinned block> FOUNDRY_PROFILE=fork forge test
AVANA_FIXTURE=fork RPC_MAINNET=… MAINNET_FORK_BLOCK=… FOUNDRY_PROFILE=fork forge test --match-path 'test/hostile/**'
AVANA_MANIFEST=<manifest under ../deployments/> RPC_MAINNET=… MAINNET_FORK_BLOCK=… FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/deployment/**'
```

Configuration: `contracts/foundry.toml` `[profile.fork]`; Base runs use `RPC_BASE` and `BASE_FORK_BLOCK` (`fork-base` CI job).

## Scope

`contracts/test/fork/` (created with the first fork test).

## How often it runs

CI (`mainnet fork tests` and `fork-base` jobs) and the layer gates from 2.2 on. First run when the Ethereum and Base archive RPC endpoints are configured; the layer 2.2 gate (AMM integrations) needs them.

## Latest result

Not run yet; no archive RPC endpoint is configured. `results/` is empty until the first run.
