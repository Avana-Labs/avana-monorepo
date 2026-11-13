# 5. Verification

Avana is verified in two stages. Spec-stage checks model the design itself: the formulas, the state machine across contracts and the economics, written from the pages in `spec/01`–`04` and the design decisions. Implementation-stage checks prove the same rules on the Solidity in [`contracts/`](../../contracts/). Every critical requirement has at least one verification method, every check links to the requirements it verifies, and every failed check becomes a `FINDING-…` in [5.3](03-audit-findings.md) (`Q-152`, `Q-173`).

## Pipeline

| Stage | What | Where |
|---|---|---|
| Specification | Architecture, contract responsibilities, exact steps, invariants, worked examples, failure conditions | `spec/01`–`04` |
| Specification review | Adversarial attack review and human engineering review; interface checks against the pinned Aave V4, Uniswap v3, Chainlink and GHO code | Results recorded as `ATTACK-…` in [4.2](../04-security/02-attack-scenarios.md), decisions in [4.4](../04-security/04-design-decisions.md) and findings in [5.3](03-audit-findings.md) |
| Formal modelling of the design | Quint state machine of the whole system; Z3 and SymPy for every formula | `quint/`, `z3/`, `sympy/` |
| Scenario and economic testing | Hypothesis state-machine and numeric tests against an executable Python model; stress simulations | `hypothesis/`, `simulation/` |
| Solidity implementation | Foundry, written from the versioned specification | `contracts/` |
| Implementation verification | Foundry unit, fuzz, fork, invariant and hostile-component tests ([5.1](01-test-requirements.md)), including the multi-actor sequence suite that asserts every global invariant after each step of borrowers, outside LPs, keepers, permissionless liquidators, a flash-loan attacker, a pool manipulator, a lender, the guardians and the timelock (`TEST-215`, `Q-278`), and a `forge script` simulation of the full deployment and first listing through the Safes and the timelock (`TEST-224`); the hostile implementations installed only through the Avana timelock so each test also exercises the delay, the cancellers and the exits open inside it; Certora CVL, Halmos and the Solidity SMTChecker ([5.2](02-formal-properties.md)); the CI file-size check `contracts/script/check-file-size.sh`, which fails when an implementation file in `contracts/src` exceeds 500 lines of code or an interface file exceeds 300 lines (`TEST-207`, `Q-240`); security tools in two tiers ([5.1](01-test-requirements.md) section K): on every commit `forge fmt` and `forge lint`, a warnings-denied build, solhint, Slither with its upgradeability check, Aderyn and the size checks, gating every merge; nightly and before every release Echidna, Medusa, Halmos, hevm and Mythril, gating every release tag and every timelock-scheduled upgrade (`TEST-253`…`TEST-263`); external audits | `contracts/test/`, `contracts/certora/`, `contracts/script/`, `audit/` |

Security tools and versions (configuration and gates in [`contracts/README.md`](../../contracts/README.md#security-tooling)): Slither 0.11.6, Aderyn 0.6.8 and solhint 6.2.5 in the fast tier; Echidna 2.3.3, Medusa 1.5.1, Halmos 0.3.3, hevm 0.58.0 and Mythril 0.24.8 in the slow tier. Two tools named in earlier plans are not used. MythX shut down and `api.mythx.io` no longer resolves, so Mythril, the open-source engine MythX ran, runs locally instead, and no step sends code to an external service. Manticore is archived, so hevm and Halmos carry symbolic execution of harnesses and tests, and Mythril and hevm carry bytecode-level analysis (`TEST-260`…`TEST-262`).

## Spec-stage tools

| Folder | Tool | Checks | IDs | Recorded result |
|---|---|---|---|---|
| [`z3/`](z3/) | Z3 4.13 | Financial constraints with exact integer rounding and Solidity bit widths: vault-token units, LPOracle and DebtOracle math, price states and the backing ledger (`units-oracle/`), Aave V4 health factor, liquidation sizing, premium, caps, breakers and repay with collateral ported from `aave-v4@a3ef63e` (`aave-risk/`), recovery floor, per-leg minimums, shortfall top-up, buy leg, waterfall, budget caps, in-kind bound, debit equalities, First-Loss coverage and sizing (`settlement/`), timelock timing, delay floor, cancel rights and the pause state (`governance/`), fair-composition LP pricing per AMM protocol: concentrated liquidity with the range clamp and the exact-range rule, constant product, StableSwap and weighted pools (`amm-pricing/`); every worked example recomputed | `MATH-UO-…`, `MATH-AR-…`, `MATH-ST-…`, `MATH-GOV-…`, `MATH-AMM-<P>-PRICE-…` | 2026-11-10: 37 scripts, 504 proved, 87 counterexamples (81 deliberate, 6 findings), 63 worked examples computed, 3 mismatches (findings), 0 timeouts ([`z3/README.md`](z3/README.md#results)) |
| [`sympy/`](sympy/) | SymPy 1.13.3 | Algebraic consistency: each formula equals the rule it implements, exactly and before rounding; closed forms the spec states; worked examples in exact rationals | `SYM-…` | 2026-11-10: 230 checks, 228 hold, 2 counterexamples (1 deliberate wrong reading, 1 finding); 16 derived closed forms ([`sympy/README.md`](sympy/README.md#results)) |
| [`quint/`](quint/) | Quint 0.22.4 (simulator) | Cross-contract state machine with honest and hostile components: 43 invariants and 35 deterministic scenarios (`avana.qnt`); multi-Hub, multi-Spoke topology: custody and backing per Spoke, no cross-Hub routing, draw caps, cross-Hub credit lines, loss attribution, stops never reaching exits, delisting, shock isolation, funding-Hub pause and token caps, 15 invariants and 20 deterministic scenarios (`topology.qnt`) | `QNT-01`…`QNT-43`, `QNT-T01`…`QNT-T30`, `QNT-TOPO-01`…`QNT-TOPO-X2`, `QNT-TOPO-T00`…`QNT-TOPO-T19` | Invariants hold within the simulated bounds; known counterexamples replay deterministically |
| [`hypothesis/`](hypothesis/) | Hypothesis 6.112.5 + pytest 8.3.3 | Generated action sequences and numeric edge cases against an executable integer model of Avana, Aave V4 and Uniswap v3; LP pricing under swaps, donations, mints and burns for concentrated-liquidity, constant-product, StableSwap and weighted pools (`test_hyp_amm_pricing.py`) | `HYP-…`, `HYP-AMM-01`…`11` with `HYP-AMM-<P>-PRICE-…` and `HYP-AMM-<P>-MANIP-…` | 71 tests; global invariants, including solvency per debt asset, checked after every step |
| [`simulation/`](simulation/) | Python (standard library) | Economic stress: depegs, oracle outages, correlated drops, keeper outages, gas and dust, route stress, interest accrual; starting values for the risk reviewer | `SIM-…` | Seeded and reproducible; results are inputs to parameter calibration |

Result vocabulary:

- **Proved**: Z3 found the negation `unsat`, or SymPy reduced the residual to 0. Holds for every input inside the stated bounds.
- **Computed**: exact-integer evaluation or exhaustive enumeration over a finite set.
- **Holds within bounds**: no violation in bounded random exploration (Quint simulator, Hypothesis, simulations). This is evidence, not proof.
- **Counterexample**: a concrete violating state; each one is a `FINDING-…` in 5.3 with the decision that resolves or accepts it.

Each folder's `README.md` lists its properties, the decision each backs, its bounds and assumptions, and the recorded result. Model scripts exit non-zero only when a result differs from the recorded one, so a run flags drift, not the known findings.

Limits: bounded and random checks do not establish correctness beyond their modelled depth and scope, and each model states its bounds. Mathematical correctness is not economic correctness: pool risk factors, caps, `minPledgeUsd`, the buy-leg allowance, the bonus curve, grace and the 48-hour incident window used for cap sizing rest on the simulations, the halt-deterioration test and the Aave V4 risk service providers (`Q-197`). Off-chain code (indexer, Convex, keeper, browser calldata builder) is covered by tests only. The Quint and Hypothesis models are written against decisions up to `Q-221`: they check custody, backing, seizure, settlement and exits on the state that Collateralization, the AaveAdapter and LPVaultSwap now hold, with GHO as the only debt asset; the Adapter call path, the PositionProxies, the pause state, the timelock and several debt reserves of `Q-223`…`Q-240` are carried by the implementation-stage properties `PROP-054`…`PROP-064` and the tests `TEST-186`…`TEST-214`, and the rules of `Q-241`…`Q-278` by `PROP-065`…`PROP-074` and `TEST-215`…`TEST-263` ([5.2](02-formal-properties.md) part A states each model's scope).

## Run

```bash
./run_all.sh              # quick path
./run_all.sh --nightly    # quick path plus the topology simulator runs
./run_all.sh --list       # the parts: each z3/ folder, sympy, simulation, hypothesis, quint, trace
./run_all.sh z3/settlement   # one part (with --nightly, the quint part adds the topology runs)
```

`run_all.sh`, run from this folder or by path:

1. creates `.venv/` from [`requirements.txt`](requirements.txt) (`z3-solver`, `sympy`, `hypothesis`, `pytest`) and installs Quint from [`package.json`](package.json) on first run;
2. runs every script in `z3/` (the AMM pricing proofs of `z3/amm-pricing/` included), `sympy/` and `simulation/`;
3. runs `pytest -q hypothesis` (the AMM pricing tests included);
4. typechecks and tests every `.qnt` file (the topology scenarios of `quint/topology_tests.qnt` included), then runs the Quint simulator checks in `quint/run.sh` (500 samples per check; `QUINT_FULL=1` for 10,000 × 20 steps);
5. with `--nightly`, runs the topology simulator checks in `quint/topology_run.sh` (1,000 traces × 25 steps per check);
6. runs `trace.py`, then prints the exit status of every step.

It exits non-zero if any step fails. Given a part, it runs only that part's steps; the parts together are the quick path. In CI, the `spec` workflow runs the quick path one part per job in parallel: `trace` (with the licence-header check and a check that the committed `traceability.md` is current) on every pull request and push to `main` that touches `spec/`, `contracts/src/`, `contracts/test/` or `contracts/certora/`, and the model parts (each `z3/` folder, `sympy`, `simulation`, `hypothesis`, `quint`, each bounded at 4 hours) only on those pushes to `main` and on manual runs, never on a pull request; `spec-gate` passes on a pull request when `trace` passed, and on `main` only when every part passed; the `models` workflow (`.github/workflows/models.yml`) runs `quint/topology_run.sh`, the part `--nightly` adds, on every push to `main`, and on every pull request and push to `main` it runs the formal-verification areas of `audit/formal-verification/`, the user simulation of `audit/user-simulation/` and `contract_checklist.py --all --check --links-only` (every contract key, and the TEST rows on no contract's checklist). The `contracts` workflow's `evidence` job runs `contract_checklist.py --all --check` and `trace.py --strict` on the results of every test shard. Single tools:

```bash
.venv/bin/python z3/aave-risk/ar01_health_factor.py         # one Z3 model
.venv/bin/python -m pytest -q hypothesis                     # Hypothesis suite
AVANA_HYP_SCALE=6 .venv/bin/python -m pytest -q hypothesis   # deeper search
npx quint test quint/avana_tests.qnt                         # Quint scenarios
npx quint test quint/topology_tests.qnt                      # topology scenarios
quint/topology_run.sh                                        # topology simulator (nightly)
.venv/bin/python z3/amm-pricing/ap01_concentrated_liquidity.py   # concentrated-liquidity pricing
quint/run.sh --quick                                         # 500 samples per Quint check
.venv/bin/python trace.py --strict                           # traceability with coverage gaps
.venv/bin/python trace.py --strict --results ../../contracts/out-results --out /tmp/traceability-run.md   # with a run
```

## Traceability

[`trace.py`](trace.py) builds the requirement → check → implementation matrix and regenerates [`traceability.md`](traceability.md).

- **Requirements** are defined in `spec/01`–`04` as the first backticked ID of a list item, table row or heading: `REQ-…`, `SPEC-…`, `INV-…`, `ATTACK-…`, flow steps (`DEP-001`, `LIQ-F-002`, `WDR-POST-001` …) and decisions `Q-…` from [4.4](../04-security/04-design-decisions.md). AMM rules: `REQ-AMM-CORE-…` and `SPEC-AMM-CORE-…` for the interface every integration meets, `REQ-`, `SPEC-`, `INV-` and `ATTACK-AMM-<P>-…` for one AMM protocol, with `<P>` one of `V3` (Uniswap v3), `SLIP` (Aerodrome Slipstream), `V2` (Uniswap v2), `CURVE`, `BAL` (Balancer), `V4` (Uniswap v4), `AERO`, `SUSHI`. The flash source and the per-chain rules use `REQ-FLASH-…` and `REQ-CHAIN-…`.
- **Checks** carry a tag in any comment style: `<CHECK-ID> verifies: <ID>, <ID>`, for example `MATH-AR-03 verifies: SPEC-HUB-001, Q-126`. Check prefixes: `MATH-` (Z3), `SYM-` (SymPy), `QNT-` (Quint), `HYP-` (Hypothesis), `SIM-` (simulation), `TEST-` (Foundry), `PROP-` (Certora, Halmos, SMTChecker).
- **Solidity** links with NatSpec: `/// @custom:spec REQ-VAULT-001, INV-003`.
- **Attack scenarios** also take their checks from the `| Checks |` row under each `ATTACK-…` heading.
- **Design-review findings**: a check may name an `AMMN-…` finding of `audit/design-review/amm-neutral/` it closes; `trace.py` fails on an unknown one and lists these links under the matrix.
- Scanned files: `spec/05-verification/**/*.py` and `**/*.qnt`, `contracts/test/**/*.sol`, `contracts/certora/**`, `contracts/src/**/*.sol`.

[`traceability.lock.json`](traceability.lock.json) stores a hash of each requirement's text and the checks accepted for it. `trace.py`:

- fails on a duplicate ID, a link to an undefined ID, or a requirement whose text changed since it was last accepted; rerun the linked checks, then record the change with `--accept <ID>` (or `--accept-all`);
- fails when an ID in the lock is no longer defined, unless its lock entry names its replacement in `retired_to`;
- checks every `FINDING-…` of [5.3](03-audit-findings.md): one that names no verification check, or links only decisions and no spec rule, is an error when it concerns an `AMM-` rule and a warning otherwise;
- applies the listing gate of [`amm-integrations.json`](amm-integrations.json), which gives each AMM protocol a status `draft`, `review` or `listed` and, once listed, the result of each of its checks. An integration carries four methods before listing: a pricing proof (`MATH-` or `SYM-AMM-<P>-PRICE-…`), manipulation tests (`TEST-` or `HYP-AMM-<P>-MANIP-…`), a fork test of unwind rounding against the pinned AMM code (`TEST-AMM-<P>-UNWIND-…` under `contracts/test/fork/`) and the invariant suite run with its markets (`TEST-AMM-<P>-INVAR-…` under `contracts/test/invariant/`). Every `REQ-AMM-<P>-…` needs a check, every `SPEC-AMM-<P>-…` a `PRICE` check, every `ATTACK-AMM-<P>-…` a `MANIP` check, every `INV-AMM-<P>-…` an `INVAR` check, and every core rule, `INV-001` and `INV-074` a check that runs against this protocol. A gap is a warning under `review` and an error under `listed`, where every `-AMM-<P>-` check also needs a passing result or a failed one whose `FINDING-…` is Resolved or Accepted;
- fails on a `verifies:` tag under `contracts/test` or `contracts/certora` that sits on no test function or CVL rule;
- with `--strict`, also fails when a requirement has no spec-stage check, and, once `contracts/src` holds Solidity, when a `REQ-…`, `SPEC-…` or `INV-…` has no counting implementation check, a check that did not run or failed (with `--results`), only declaration `@custom:spec` links or none, and on a `TEST-` tag placed on another row's test.

Each row of the matrix has an implementation status: **Verified** (a counting check ran and passed), **Failed**, **Not run** (counting checks exist, none has a result), **Unlinked** (no counting check) or **Changed — re-verify**. The committed `traceability.md` is written without run results, so its Foundry rows read Not run and only CVL rules with a recorded prover pass and Halmos checks with a recorded log count as Verified; `trace.py --results <dir> --out <file>` writes the matrix of a run, as the CI evidence job does. In [`contracts/certora/RUNS.md`](../../contracts/certora/RUNS.md) a prover result counts when it names the rule and a job id: a row of a per-conf results table (`all N` counts while the conf's spec still has N rules), a row of a per-rule table whose status is `Verified`, or a line `- **Prover verified** <Conf> job <job id>: \`rule\`, …`; a later TIMEOUT or violation of the same rule replaces an earlier pass. ID formats and change control are described in [`spec/README.md`](../README.md#traceability-and-change-control).

## Licence

The models and scripts here are Avana code under the Business Source License 1.1 in the root [`LICENSE`](../../LICENSE), except the models that port third-party code, which keep that code's licence (each file's SPDX line):

| Files | Licence | Ported from |
|---|---|---|
| `z3/units-oracle/_common.py`, `hypothesis/model/uniswap.py` | GPL-2.0-or-later ([text](../../LICENSES/GPL-2.0.txt)) | Uniswap v3-core `TickMath`, `SqrtPriceMath`, `Tick` (`5ea68a7`) |
| `hypothesis/model/aave.py`, `hypothesis/model/mathlib.py`, `z3/aave-risk/_v4ref.py` | the Aave V4 licence, `LicenseRef-BUSL` ([text](../../LICENSES/LicenseRef-BUSL-AaveV4.md)) | Aave V4 Hub, Spoke and math libraries (`a3ef63e`) |

The Aave V4 ports are used only to check the specification, in a test environment, as that licence requires. Python and npm tools (Z3, SymPy, Hypothesis, pytest, Quint) are installed from `requirements.txt` and `package-lock.json` and keep their own licences ([`THIRD_PARTY_LICENSES.md`](../../THIRD_PARTY_LICENSES.md#packages)).
