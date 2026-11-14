# Halmos

## What it proves

Halmos symbolically executes each `check_PROP_NNN_<behavior>` function in `contracts/test/halmos/` over all inputs within the stated bounds (loops unrolled to 8, the record-list bound). A pass means no input reaches a failing assertion; a counterexample is a concrete input that breaks the property. The properties are the Halmos rows of [5.2 Formal Properties](../../spec/05-verification/02-formal-properties.md).

## How to run

From `contracts/`, Halmos 0.3.3 in `contracts/.venv`:

```bash
FOUNDRY_DYNAMIC_TEST_LINKING=false .venv/bin/halmos --root . --match-contract 'HalmosTest$' --loop 8 --solver-timeout-assertion 0   # what security-slow.sh runs
FOUNDRY_DYNAMIC_TEST_LINKING=false .venv/bin/halmos --root . --match-contract 'VaultTokenHalmosTest$' --loop 8                    # one harness
script/security-slow.sh halmos
HALMOS_CONTRACTS=VaultTokenHalmosTest HALMOS_LOOP=16 script/security-slow.sh halmos            # one test contract, as each CI job runs it
```

`FOUNDRY_DYNAMIC_TEST_LINKING=false` is required: dynamic test linking turns `new C(...)` into `deployCode`, which Halmos does not support. Budget: `HALMOS_LOOP` (default 8, nightly 16) and `HALMOS_TIMEOUT` (seconds of wall clock per run; none by default, 18,000 in CI); a single check listed in `contracts/security/halmos-bounds.json` takes that entry's budget (and its loop bound, when it sets one). `script/security-slow.sh` runs one solver thread (`--solver-threads 1`; Halmos's default is one per CPU). In CI, it runs Halmos and its solver in a systemd scope capped at `SECURITY_MEMORY_MAX` (14 GB of the runner's 16 GB, no swap), so a check that needs more ends with "OUT OF MEMORY" in its log instead of the runner shutting down. In run 43387180884 the runner shut down 30 s into `check_PROP_019_legSlippage`, with no log.

## Scope

17 harnesses, 95 `check_` functions: AaveV3FlashSource, AvanaTimelock, Collateralization, CoverageSpoke, DexPathRoute, LPPriceMath, Lock, MarketRegistry, ParameterStore, PayoutEscrow, PegModuleRoute, PositionProxy, ProxyManager, SettlementMath, VaultToken, VaultTokenFactory, WrapperThenDexRoute.

## How often it runs

Contract gate (every `check_` of the contract passes) and the slow tier at each layer gate. In CI, the `halmos` jobs of `security-slow.yml` (loop 16, one job per check, a 5-hour budget in a 6-hour job) run every night on `main`, on every release tag and by hand; no pull-request or push workflow runs Halmos. A counterexample fails the job. A check listed in `contracts/security/halmos-bounds.json` (the 23 checks cancelled at 6 hours in run 43492412351) that its budget or a solver timeout ends without a counterexample passes its job as "bounded, no violation found": not run to completion, reported in the job summary, as a warning and in `out-security/halmos-outcome.json`; an unlisted check that runs out fails. A check that timed out or has no recorded pass counts as not run in the traceability evidence.

## Latest result

| Harness | Date | Result |
|---|---|---|
| Lock | 2026-11-10 | 6 checks pass; a swapped-check mutation is caught |
| AvanaTimelock | 2026-11-10 | 7 checks pass |
| ParameterStore | 2026-11-10 | 8 checks pass |
| VaultToken | 2026-11-10 17:04 | 7 / 7 pass (`PROP-005`, `PROP-008`, `PROP-009`, `PROP-055`) |
| AaveV3FlashSource | 2026-11-10 20:20 | 8 / 8 pass after the balance-snapshot fix (`PROP-036`, `PROP-080`) |
| PegModuleRoute | 2026-11-10 20:10 | 2 pass (`PROP-036`, `PROP-037`); the run was stopped before the other 2 |
| LPPriceMath | 2026-11-10 20:31 | `PROP-024` ceiling passes; `PROP-023`, `PROP-024` symmetry and `PROP-026` time out (1,113 s, 182 s, 117 s); their fuzz twins pass at 10,000 runs |
| SettlementMath | 2026-11-10 20:51 | 2 / 14 pass under machine load; `PROP-015` gap and three `PROP-018` checks hit the 240 s wall clock; fuzz twins pass at 10,000 runs |
| CoverageSpoke | 2026-11-10 | The two `PROP-039` checks time out on the RAY division; fuzz twins carry them |

The slow-tier Halmos step of 2026-11-10 16:01 failed to build (`TimelockFixture.sol` imported `AvanaTimelock.sol` while the timelock was being merged); its output is kept as is.

## Results folder

- [`halmos-runs-2026-11-10.txt`](results/halmos-runs-2026-11-10.txt): the PASS, TIMEOUT and result lines of each harness run of 2026-11-10.
- [`security-slow-halmos-step-2026-11-10.txt`](results/security-slow-halmos-step-2026-11-10.txt): output of `security-slow.sh halmos` at 16:01.
