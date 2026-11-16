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

`FOUNDRY_DYNAMIC_TEST_LINKING=false` is required: dynamic test linking turns `new C(...)` into `deployCode`, which Halmos does not support. Budget: `HALMOS_LOOP` (default 8, nightly 16) and `HALMOS_TIMEOUT` (seconds of wall clock per run; none by default, 3,600 in CI). `script/security-slow.sh` runs one solver thread (`--solver-threads 1`; Halmos's default is one per CPU). In CI, it runs Halmos and its solver in a systemd scope capped at `SECURITY_MEMORY_MAX` (14 GB of the runner's 16 GB, no swap), so a check that needs more ends with "OUT OF MEMORY" in its log instead of the runner shutting down. In run 43387180884 the runner shut down 30 s into `check_PROP_019_legSlippage`, with no log.

## Scope

17 harnesses, 95 `check_` functions: AaveV3FlashSource, AvanaTimelock, Collateralization, CoverageSpoke, DexPathRoute, LPPriceMath, Lock, MarketRegistry, ParameterStore, PayoutEscrow, PegModuleRoute, PositionProxy, ProxyManager, SettlementMath, VaultToken, VaultTokenFactory, WrapperThenDexRoute.

## How often it runs

Contract gate (every `check_` of the contract passes) and the slow tier at each layer gate. In CI, the `halmos` jobs of `security-slow.yml` (loop 16, one job per check, a 1-hour budget) run every night on `main`, on every release tag and by hand; no pull-request or push workflow runs Halmos. A counterexample fails the job, and so does a check that its budget or a solver timeout ends before it completes: there is no "bounded" outcome, and `contracts/security/halmos-bounds.json` must keep an empty list. The 23 checks cancelled at 6 hours in run 43492412351 were split into cases or rewritten as equalities with a reference formula whose inequalities a Z3 model proves (MATH-ST-130, MATH-ST-140…146, MATH-AR-86f, MATH-AR-87d, MATH-AR-90…92, MATH-UO-79…81). A check that timed out or has no recorded pass counts as not run in the traceability evidence.

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
| SettlementMath `PROP-019` leg slippage | 2026-11-15 | `check_PROP_019_legSlippage` ran out of its 5-hour budget in security-slow run 43677588077 with no counterexample (the symbolic divisor of `Math.mulDiv`); it is split into six checks with no symbolic divisor (`NoRelax`, `Wide`, and `QuotientV3`, `V10000`, `VPrime`, `VMax` at literal values). All six pass: locally (Halmos 0.3.3, loop 16) in 109 s in total, and in security-slow run 43708786168 |
| RiskModule `PROP-030`, `PROP-067`; Collateralization `PROP-028` | 2026-11-15 | Cancelled at the 6-hour limit in run 43492412351 with no counterexample: `check_PROP_030_chargeCoversFloor`, `check_PROP_067_rescueValueRoundsUp` and `check_PROP_028_exitChargeIndependentOfSplit` asserted inequalities between products of two symbolic values (the last one also divided by a symbolic value). Each is now `<name>Formula`: Halmos proves the code returns `⌊x y / s⌋ + (x y mod s > 0)` for every input of the old check, and `MATH-AR-90`, `92` and `91` (`docs/spec/05-verification/z3/aave-risk/ar17_halmos_references.py`, 10 proved) prove the old inequalities on that formula. `check_PROP_067_requiredIsMaximum` (comparisons only) is split into `Wad`, `HardFloor` and `MinHf` by which value is largest, over uint256. Not yet run in Halmos |
| LPPriceMath `PROP-023`, `PROP-024`; LPOracleCL `PROP-025` | 2026-11-15 | Ran out of the 5-hour budget in run 43677588077 with no counterexample: the three `check_PROP_023_price8PositiveAndBelowExact_<d0>_<d1>` checks and `check_PROP_024_valuationSymmetricInTokenOrder` (products of two symbolic values in `Math.mulDiv`, compared with other products), `check_PROP_025_meanTickRoundsTowardNegativeInfinity` (the symbolic mean times the symbolic window) and `check_PROP_025_oracleSqrtIsTickable` (the divisions by symbolic values inside `Math.sqrt`). The first four and the mean tick are now `<name>Formula`: Halmos proves the code returns a reference formula built from the code's own products and quotients (with `mulmod(x, y, 2^256 − 1) == x * y` assumed for each `mulDiv` term, which removes no input), and `MATH-UO-79`, `80` (`docs/spec/05-verification/z3/units-oracle/uo20_halmos_references.py`, 14 proved, 1 computed) prove the old assertions on it. The oracle square-root check is split into nine checks by branch of `SPEC-ORC-009` and by the range of the square-root input (`LowerX64` … `LowerX256`, `Clamped`, `UpperY64` … `UpperY256`), the lower branch assuming the root bound `Math.sqrt(a) < 2^129` that `MATH-UO-81` proves for every input. Not yet run in Halmos |

The slow-tier Halmos step of 2026-11-10 16:01 failed to build (`TimelockFixture.sol` imported `AvanaTimelock.sol` while the timelock was being merged); its output is kept as is.

## Results folder

- [`halmos-runs-2026-11-10.txt`](results/halmos-runs-2026-11-10.txt): the PASS, TIMEOUT and result lines of each harness run of 2026-11-10.
- [`security-slow-halmos-step-2026-11-10.txt`](results/security-slow-halmos-step-2026-11-10.txt): output of `security-slow.sh halmos` at 16:01.
