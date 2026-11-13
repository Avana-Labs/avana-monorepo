# Traceability

## What it proves

Every rule of the spec links to the checks that verify it and to the Solidity that implements it, which of those checks ran and passed, and no rule changes without its checks being re-run.

- [`trace.py`](../../spec/05-verification/trace.py) reads every `REQ-`, `SPEC-`, `INV-`, `ATTACK-`, flow-step and `Q-` ID in `spec/01`–`04`, every `<CHECK> verifies: <IDs>` tag (Z3, SymPy, Quint, Hypothesis, simulation, Foundry, Certora, Halmos) and every `/// @custom:spec` NatSpec link, and regenerates [`traceability.md`](../../spec/05-verification/traceability.md). It fails on a duplicate ID, a link to an undefined ID, or a rule whose text changed since its checks were last accepted.
- [`traceability.lock.json`](../../spec/05-verification/traceability.lock.json) holds a hash of each rule's text and the checks accepted for it; `--accept <ID>` records a re-verified change.
- [`evidence.py`](../../spec/05-verification/evidence.py) decides which `TEST-`/`PROP-` tags count: a tag sits directly above a test function or CVL rule, the test carries the tag's own row (or the tag gives `shared: <reason>`), the check ran and passed in the run's results (`forge test --json-file`, Halmos logs; a CVL rule needs a prover result with a job id in `contracts/certora/RUNS.md` or a CI result file), and the test uses no harness or mock that stands in for the contract the row belongs to (`STAND_INS`). A `@custom:spec` tag on a body-less declaration is shown as a declaration, not an implementation.
- [`contract_checklist.py`](../../spec/05-verification/contract_checklist.py) prints, for one contract, every REQ/SPEC ID on its page, its TEST, PROP, INV and ATTACK rows, each verified `[x]`, failed `[!]`, not run `[~]` or unlinked `[ ]`; `--check --results <run>` exits 1 while a row in scope is not verified, `--check --links-only` while one is unlinked or failed. `--all` runs every contract key and `--uncovered` the TEST rows on no contract's checklist.

## How to run

```bash
cd spec/05-verification
.venv/bin/python trace.py                 # matrix and errors
.venv/bin/python trace.py --strict        # also coverage gaps
python3 contract_checklist.py --list      # ID counts per contract
python3 contract_checklist.py Collateralization --check --links-only
python3 contract_checklist.py --all --check --results ../../contracts/out-results   # with a run's results
```

## Scope

3,558 requirements (2026-11-12; 3,478 on 2026-11-10) across `spec/01`–`04`; checks in `spec/05-verification/`, `audit/formal-verification/`, `contracts/test/`, `contracts/certora/`; Solidity in `contracts/src/`.

## How often it runs

Every contract gate (0 errors, every row of the contract verified by a test that ran and passed), the `traceability` and `evidence` CI jobs of `contracts.yml` (the evidence job runs `contract_checklist.py --all --check` and `trace.py` on every test shard's results; since 2026-11-13 these jobs, and the `spec` and `models` workflows, report without failing), and with every spec change: the `models` workflow runs `contract_checklist.py --all --check --links-only` for every contract key on every pull request and push to `main`.

## Latest result

Run on 2026-11-12 on the wave 1 tree, with the rules above (a tag counts only on its own test, run and passed, without a stand-in for the row's contract).

| Measure | Committed matrix (no run results) | With one local run's results |
|---|---|---|
| Requirements | 3,558 | 3,558 |
| Verified | 114 (CVL rules with a recorded prover pass, Halmos checks with a recorded log) | 1,724 |
| Failed | 0 | 3 (two lite-profile artifacts, see the results file) |
| Not run | 1,642 | 29 |
| Unlinked | 1,682 | 1,682 |
| Changed — re-verify | 120 (rules edited by the spec work in progress) | 120 |

Under the earlier rule (any tag anywhere linked a row) the same tree showed 945 rows Verified and 1,888 rows with a Foundry tag. 146 `TEST-` tags sit on a test named for another row and no longer count; 294 rows have only declaration `@custom:spec` links (for example `REQ-ORACLE-014`: the `ILPOracle` interface, the abstract `LPOracle` and the body-less `_consistency` hook), and every LPOracle test runs on `LPOracleHarness`, so `REQ-ORACLE-014` and `REQ-ORACLE-048` are Unlinked.

Per contract, rows in `--check` scope (REQ/SPEC of the page, TEST and PROP rows), with the local run's results: [`evidence-local-run-2026-11-12.md`](results/evidence-local-run-2026-11-12.md). With that run, 22 of the 26 contracts fail `--check` (AvanaRoles, LPPriceMath, PositionProxy and ProxyManager pass); with links only (the `models` check), 19 fail on unlinked rows and 7 pass (AvanaRoles, Lock, LPPriceMath, VaultTokenFactory, PositionProxy, ProxyManager, FlashLiquidator). The TEST rows on no contract's checklist: 52, of which 27 are keeper, off-chain or CI-tool rows in `OUTSIDE_CONTRACTS` and 18 block `--check` (TEST-003, 005, 008, 009, 076, 082, 103, 110, 111, 121, 126, 127, 134, 135, 183, 184, 263, 282). The full per-contract checklists, written with links only, are in [`results/contract-checklists/`](results/contract-checklists/).

### Earlier result (2026-11-10, earlier rule: a tag anywhere linked a row)

Run on 2026-11-10 at 22:4x, while the spec rewrite of 2.11 and the review fix batches were in progress, from a copy of `trace.py` that writes the matrix outside the repository:

| Measure | Value |
|---|---|
| Requirements | 3,478 |
| With checks | 1,579 |
| Errors | 384: 382 rules whose text changed since last accepted (decisions and attack scenarios edited by the rewrite, waiting for `--accept` after their checks re-run), 2 citations of the `MATH-UO` prefix without a number |
| Warnings | 4,184 (mostly `FINDING-*` entries that link only decisions) |
| Status | Verified 449, Modelled 592, Planned (prover) 156, Changed — re-verify 382, Unverified 1,899 |

At each contract's gate `trace.py` reported 0 errors. Lock file (written 2026-11-10 21:04): 3,454 rules with an accepted hash, 8,842 accepted check links.

Per-contract checklists (`contract_checklist.py <C> --check`, 2026-11-10, earlier rule), rows linked / rows listed:

| Contract | REQ/SPEC on the page | TEST | PROP | INV | ATTACK |
|---|---|---|---|---|---|
| Lock | 29/30 | 2/2 | 3/3 | 8/8 | 1/1 |
| AvanaTimelock (2.15, shared page) | 52/198 | 15/24 | 3/3 | 7/7 | 0/5 |
| LPPriceMath (2.10, shared page) | 45/129 | 1/1 | — | 1/1 | 1/1 |
| SettlementMath (2.11, shared page) | 39/170 | 1/1 | 1/1 | 2/2 | — |
| ParameterStore | 52/58 | 16/19 | 4/4 | 9/14 | 1/2 |
| MarketRegistry | 87/97 | 26/45 | 6/7 | 17/22 | 6/11 |
| VaultToken | 47/53 | 8/19 | 5/5 | 12/13 | 6/9 |
| VaultTokenFactory | 47/53 | 2/2 | 4/4 | 2/2 | 1/1 |
| Collateralization | 139/159 | 32/70 | 22/22 | 29/34 | 19/22 |
| AaveV3FlashSource (2.11, shared page) | 39/170 | 5/6 | 2/2 | 7/10 | 2/2 |
| PositionProxy | 36/50 | 11/34 | 2/2 | 6/7 | 9/13 |
| ProxyManager | 36/50 | 10/12 | 5/5 | 3/5 | 7/8 |
| Swap routes | 26/45 | 4/12 | 4/4 | 14/19 | 1/5 |
| PayoutEscrow | 18/18 | 4/7 | 3/3 | 7/9 | 1/1 |
| CoverageSpoke | 39/49 | 1/8 | 2/2 | 7/12 | 3/4 |

A shared page lists the rules of every contract on it, so most unlinked rows of the 2.10, 2.11 and 2.15 contracts belong to contracts that had no implementation on that date (LPOracle, DebtOracle, LPVaultSwap). Cross-cutting TEST rows: 9 of 17 linked for every contract; the other 8 involve the AaveAdapter, LPVaultSwap or the deployment script and were not yet linked. Unlinked rows of implemented contracts are the test gaps listed in each [review](../reviews/).

## Results folder

- [`trace-output-2026-11-10.txt`](results/trace-output-2026-11-10.txt): console output of `trace.py`.
- [`traceability-summary-2026-11-10.md`](results/traceability-summary-2026-11-10.md): totals and status counts of the regenerated matrix.
- [`lock-stats-2026-11-10.md`](results/lock-stats-2026-11-10.md): entries of `traceability.lock.json` per ID prefix.
- [`contract-checklists/`](results/contract-checklists/): the full checklist of every contract key, written on 2026-11-12 with links only (`--all --links-only --out-dir`), so a linked row reads not run `[~]`.
- [`evidence-local-run-2026-11-12.md`](results/evidence-local-run-2026-11-12.md): the per-contract verdicts and the TEST rows on no checklist, from one local run's results.
