# Slither

## What it proves

Slither 0.11.6 runs its static detectors over every contract and library under `contracts/src/` (external ABI mirrors excluded), from the fast tier's own build. The gate is at Informational: every High, Medium, Low and Informational finding is either fixed or accepted by a triage entry with a reason; Optimization findings are reported only.

## How to run

```bash
cd contracts && script/security-fast.sh build slither
```

Configuration: `contracts/slither.config.json` (excluded detectors `naming-convention` and `unindexed-event-address`, each with its reason in `security/slither-triage.json`); triage `contracts/security/slither-triage.json`; gate `script/security-gate.py slither … --fail-on informational`. Reports: `out-security/slither.json`, `slither.sarif`, `slither-gate.txt`.

## Scope

Every implementation in `contracts/src/` on 2026-11-10 (the 18 contracts listed in [foundry-tests](../foundry-tests/) and their facets and libraries).

## Triage rule

A finding at or above the gate fails the fast tier unless a triage entry accepts it. A real finding is fixed. A false positive gets an entry in `contracts/security/<tool>-triage.json` with a one-line reason naming the requirement and the tests that cover the behavior; an entry without a reason fails the gate. On 2026-11-10 Josue approved every entry and inline suppression recorded until then (218 entries, 151 suppressions) by pattern. A later entry in an approved pattern (unused error or import for `@inheritdoc` or a contract without an implementation, view-only calls before writes, bounded loops, returns measured by balance delta, assembly for ERC-7201 or transient slots, specified timestamps, analysis artefacts of abstract facets) is accepted with `"approval": "approved by pattern"` once the contract's independent review agrees; a new pattern or a higher-severity detector is approved entry by entry. Counts per file and detector: [slither/results/triage-summary-2026-11-10.md](../slither/results/triage-summary-2026-11-10.md).

## How often it runs

Fast tier on every push and pull request (`fast-security` CI job) and at every contract gate.

## Latest result

2026-11-10 21:39 (fast tier started 21:33): **342 findings, 0 blocking.** 341 accepted by triage, 1 Optimization reported (`immutable-states` on `CollateralizationBase.sol:93`).

| Severity | Accepted | Detectors |
|---|---|---|
| High | 6 | `uninitialized-state` 5 (state of the abstract Collateralization facets written by sibling facets), `arbitrary-send-erc20` 1 (PayoutEscrow pulls only from the immutable LPVaultSwap) |
| Medium | 26 | `unused-return` 18 (accounting by measured balance deltas), `reentrancy-no-eth` 8 (callees are Avana immutables or Aave under the Lock) |
| Low | 158 | `calls-loop` 137 (bounded loops over registry records, at most 16 records or 8 tokens), `reentrancy-events` 11, `timestamp` 6, `reentrancy-benign` 4 |
| Informational | 151 | `unused-state` 133 (shared storage bases of router and logic contracts), `assembly` 6 (ERC-7201 and transient slots), `low-level-calls` 5, `unimplemented-functions` 4, `too-many-digits` 3 |

## Results folder

- [`slither-gate.txt`](results/slither-gate.txt): every finding with its gate decision and reason.
- [`slither.sarif`](results/slither.sarif), [`slither.log`](results/slither.log): the SARIF report and the console log. The 7.8 MB JSON report stays in `contracts/out-security/slither.json`.
- [`slither-triage.json`](results/slither-triage.json): copy of the triage file.
- [`triage-summary-2026-11-10.md`](results/triage-summary-2026-11-10.md): entries per triage file and detector, approvals, inline suppressions.
