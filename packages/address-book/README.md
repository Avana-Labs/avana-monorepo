# Address book

`addresses.md`, `parameters.md` and `access-controls.md` are the address book: the source of the website's developer pages Contract Addresses, Market Parameters and Access Control (under /developers/reference/). The website reads them from this folder on GitHub. They are generated: do not edit them by hand.

## How they are made

`contracts/script/address-book/address-book.ts` writes one network's section of all three files from that network's deployment folder:

- `manifest.json`: every Avana, Aave, AMM, token and feed address, the market IDs, vault tokens and LPOracles, and the role holders and timelock settings;
- `world.json`: pool addresses, Uniswap v4 PoolIds and their v3 reference pools;
- the last release's `config-*.json` (named by `stack-status.json`, or the folder's only `config-hub-*.json`): Spoke and market names and the listing values (caps, collateral factors, bonuses, slippage, route depth thresholds, rate curves, First-Loss Reserve minimums, chain settings);
- `operation-listing-activate.json`: the timelock's short delay;
- `listing-oracles.json`: a fixed price source the listing deployed, if any.

The other networks' sections stay as they are. The text around the sections (the intro and each page's "All networks" part) comes from `contracts/script/address-book/templates/`.

After a deployment, from the repo root:

```sh
node contracts/script/address-book/address-book.ts --network <id> --deployment <folder>
```

| `--network` | Chain ID | Section |
| --- | --- | --- |
| `ethereum-sepolia` | 11155111 | Ethereum Sepolia |
| `base-sepolia` | 84532 | Base Sepolia |
| `ethereum`, `base` | 1, 8453 | Ethereum, Base |
| `local-ethereum`, `local-base` | 31337, 31338 | the local stack's development chains (`contracts/deployments-local/<ethereum\|base>`) |

Options: `--out <dir>` (default `packages/address-book`), `--date YYYY-MM-DD` (the pages' `updated`, default today), `--config <file>` (another config than the last release's), `--allow-rehearsal`.

The script writes nothing and lists every problem when the folder holds a rehearsal's outputs (`.rehearsal`), when the manifest's chain ID or network is not the one named, when the manifest fails its schema, when a value the pages show is missing or still a placeholder, or when the manifest's role holders differ from the pages' wording. A row a network legitimately lacks is written as such: the AvanaGasVault shows "Not deployed on this network", a chain without a sequencer feed has no feed row, and the local chains, which list swap routes without a depth threshold, show `routeDepthThreshold` as not set. A role holder counts as a Safe only when the manifest records its address in `external` with the group `safe`.

Tests: `node --test script/address-book/address-book.test.ts` (from `contracts/`), on the fixture deployment in `contracts/script/address-book/fixtures/`.

## Format

The pages keep the website's format: front matter, one `## ` group per network that opens with `- network: <id>`, `- chainId:` and, for a public network, `- explorer:`, then `### ` sections with GFM tables and `> ` notes, and a closing `## All networks` group. Addresses are written into the cells; there are no `@{key}` references. Each network's section sits between `<!-- network-section:start <id> -->` and `<!-- network-section:end <id> -->` comments, which the script uses to replace it.

Next to the sections of the earlier pages, each network section has a Markets table on Contract Addresses (market ID, vault token and LPOracle of each market), a Slippage allowance table and more Chain settings rows on Market Parameters (timelock delays, public execution, `MAX_MARKET_COUNT`, `routeDepthThreshold`, the DebtOracle `pokeMinGas`), and a Timelock table on Access Control. The local chains have no explorer line.
