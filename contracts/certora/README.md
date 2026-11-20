# Certora rules

CVL rules for the Avana core. Run locally in WSL; not run in CI. Run log: [RUNS.md](RUNS.md).

## Proof rule

1. **Small proven steps.** Each nonlinear fact is its own rule. The main rule requires those facts by name and asserts only the linear step.
2. **Exact-math summaries.** `mulDiv` and `sqrt` are summarized as exact floor division and integer square root. Each summary is proved once against the library bytecode in `LPOracleSummaries.spec`, then reused.
3. **Stop and split.** A rule stuck for 30–60 minutes is stopped and split into smaller steps. It is never rerun unchanged.
4. **Slow tests too.** A slow Foundry, Halmos or fuzz test is split the same way.
5. **Local only.** Certora runs in WSL on a developer machine. CI runs only the methods check (`check-methods.py`).

## Confs

| Conf | Verifies | Spec | Rules |
|---|---|---|---|
| `AaveAdapterAccounts` | AaveAdapter | Account proxies, pledge into the routed market | 5 |
| `AaveAdapterRouting` | RiskModuleHarness | `routeOf` picks the one market the ticks fit | 3 |
| `RiskModuleBands` | RiskModuleHarness | Band edges and spacing | 8 |
| `FloorCreditMath` | FloorCreditMathHarness | Floor credit bounds ([proof](../src/custody/lp-vault/FLOOR-CREDIT-PROOF.md)) | 14 |
| `VaultToken` | VaultToken | Mint, burn and the transfer path rule | 7 |
| `LPOracle` | LPOracleHarness | Price steps of `LPPriceMath` | 17 |
| `LPOracleSummaries` | LPOracleSummariesHarness | `mulDiv` and `sqrt` summaries, integer mode | 16 |
| `LPOracleSummariesPrecise` | LPOracleSummariesHarness | `mulDiv` limb facts, word mode | 2 of 16 |
| `LiquidationModule` | LiquidationModuleHarness | Unwind sizing and payout split | 10 |
| `FirstLossReserve` | FirstLossReserve | Funding, cover order, withdrawal delay | 6 |
| `Hub` | Aave V4 HubInstance (`a3ef63e`) | Vault-token asset: added assets equal added shares | 2 |

Shared models in `specs/setup/`: `AuthorityModel` (AccessManager decisions), `Erc20Model` (standard ERC-20 tokens), `TransientModel` (empty transient storage at rule start). Harnesses live in `test/utils/harness/`.

## Settings

Every conf: `solc-0.8.28`, `cancun`, `solc_optimize 10000`, `packages` from `remappings.txt`, `rule_sanity: basic` (a vacuous rule fails). Loop bounds, hashing bounds and prover arguments are set per conf with their reason inline.

## Running (WSL)

Requirements: Java 21, `solc-0.8.28` on `PATH`, `forge soldeer install`, and either certora-cli 8.20.3 (`.venv`, `CERTORAKEY` set) or a locally built Prover.

```bash
cd contracts
python3 certora/check-methods.py                                  # methods blocks against the ABIs
certoraRun certora/conf/VaultToken.conf --compilation_steps_only  # compile and type-check only
certoraRun certora/conf/LiquidationModule.conf                    # every rule of one conf
certoraRun certora/conf/LPOracle.conf --rule <name>               # one rule
```

Mutation testing (`certoraMutate`) also runs locally: `script/certora-mutate-local.sh <Conf>...`.

Log every run in [RUNS.md](RUNS.md): date, command, versions, per-rule result and time.
