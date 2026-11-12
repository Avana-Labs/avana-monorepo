# Traceability

## What it proves

Every rule of the spec links to the checks that verify it and to the Solidity that implements it, and no rule changes without its checks being re-run.

- [`trace.py`](../../spec/05-verification/trace.py) reads every `REQ-`, `SPEC-`, `INV-`, `ATTACK-`, flow-step and `Q-` ID in `spec/01`–`04`, every `<CHECK> verifies: <IDs>` tag (Z3, SymPy, Quint, Hypothesis, simulation, Foundry, Certora, Halmos) and every `/// @custom:spec` NatSpec link, and regenerates [`traceability.md`](../../spec/05-verification/traceability.md). It fails on a duplicate ID, a link to an undefined ID, or a rule whose text changed since its checks were last accepted.
- [`traceability.lock.json`](../../spec/05-verification/traceability.lock.json) holds a hash of each rule's text and the checks accepted for it; `--accept <ID>` records a re-verified change.
- [`contract_checklist.py`](../../spec/05-verification/contract_checklist.py) prints, for one contract, every REQ/SPEC ID on its page, its TEST, cross-cutting TEST, PROP, INV and ATTACK rows, each ticked when a tag in `contracts/test` or `contracts/certora` links it; `--check` exits 1 while a row is unlinked.

## How to run

```bash
cd spec/05-verification
.venv/bin/python trace.py                 # matrix and errors
.venv/bin/python trace.py --strict        # also coverage gaps
python3 contract_checklist.py --list      # ID counts per contract
python3 contract_checklist.py Collateralization --check
```

## Scope

3,478 requirements across `spec/01`–`04`; checks in `spec/05-verification/`, `audit/formal-verification/`, `contracts/test/`, `contracts/certora/`; Solidity in `contracts/src/`.

## How often it runs

Every contract gate (0 errors, every ID of the contract linked), the `traceability` CI job, and with every spec change. The `models` CI workflow runs `contract_checklist.py <Contract> --check` for every contract with a file in `results/contract-checklists/` on every pull request and push to `main`.

## Latest result

Run on 2026-11-10 at 22:4x, while the spec rewrite of 2.11 and the review fix batches were in progress, from a copy of `trace.py` that writes the matrix outside the repository:

| Measure | Value |
|---|---|
| Requirements | 3,478 |
| With checks | 1,579 |
| Errors | 384: 382 rules whose text changed since last accepted (decisions and attack scenarios edited by the rewrite, waiting for `--accept` after their checks re-run), 2 citations of the `MATH-UO` prefix without a number |
| Warnings | 4,184 (mostly `FINDING-*` entries that link only decisions) |
| Status | Verified 449, Modelled 592, Planned (prover) 156, Changed — re-verify 382, Unverified 1,899 |

At each contract's gate `trace.py` reported 0 errors. Lock file (written 2026-11-10 21:04): 3,454 rules with an accepted hash, 8,842 accepted check links.

Per-contract checklists (`contract_checklist.py <C> --check`, 2026-11-10), rows linked / rows listed:

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
- [`contract-checklists/`](results/contract-checklists/): the full checklist of each written contract.
