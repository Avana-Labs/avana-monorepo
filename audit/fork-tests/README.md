# Fork tests

## What it proves

Fork tests run Avana against the real deployed code at a pinned block: Uniswap v3 on an Ethereum fork, every Aerodrome Slipstream generation on a Base fork, the Aave V3 Pool flash source (`TEST-118`), the GSM and LitePSM peg-module routes (`TEST-119`, `TEST-120`), Chainlink feeds and the Base sequencer feed (`TEST-117`, `TEST-275`), the unwind rounding of each AMM integration against the pinned AMM code (`TEST-264`, `TEST-265`), every mock's fork counterpart (`TEST-005`), and the deployment checks against a manifest (`TEST-134`, `TEST-135`).

## How to run

```bash
cd contracts
FOUNDRY_PROFILE=fork forge test
AVANA_FIXTURE=fork FOUNDRY_PROFILE=fork forge test --match-path 'test/hostile/**'
AVANA_MANIFEST=<manifest under ../deployments/> FOUNDRY_PROFILE=fork forge test --match-path 'test/fork/deployment/**'
```

Fork tests read the archive RPC endpoints `RPC_MAINNET` (Ethereum) and `RPC_BASE` (Base). The fork blocks are pinned in `contracts/test/utils/fixtures/ForkConstants.sol`, so every run sees the same chain state. Configuration: `contracts/foundry.toml` `[profile.fork]`.

## Scope

`contracts/test/fork/` (created with the first fork test).

## How often it runs

CI (the `fork` job of `.github/workflows/contracts.yml`, on every pull request and push to `main` once the `RPC_MAINNET` and `RPC_BASE` secrets are set; without them the job passes with a warning) and the layer gates from 2.2 (AMM integrations) on.

## Latest result

`results/` holds no recorded run.
