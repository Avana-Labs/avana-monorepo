# Aderyn

## What it proves

Aderyn 0.6.8 runs its static detectors over `contracts/src/` (external ABI mirrors excluded). The gate is at Low: every High and Low finding is fixed or accepted by a triage entry with a reason.

## How to run

```bash
cd contracts && script/security-fast.sh aderyn
```

Configuration: `contracts/aderyn.toml` (each excluded detector carries its reason in place: `push-zero-opcode`, `centralization-risk`, `internal-function-used-once`, `modifier-used-only-once`, `unused-public-function` and the integer-type note); triage `contracts/security/aderyn-triage.json`; gate `script/security-gate.py aderyn … --fail-on low`.

## Scope

Every implementation in `contracts/src/` on 2026-11-10.

## Triage rule

A finding at or above the gate fails the fast tier unless a triage entry accepts it. A real finding is fixed. A false positive gets an entry in `contracts/security/<tool>-triage.json` with a one-line reason naming the requirement and the tests that cover the behavior; an entry without a reason fails the gate. On 2026-11-10 the protocol owner approved every entry and inline suppression recorded until then (218 entries, 151 suppressions) by pattern. A later entry in an approved pattern (unused error or import for `@inheritdoc` or a later contract, view-only calls before writes, bounded loops, returns measured by balance delta, assembly for ERC-7201 or transient slots, specified timestamps, analysis artefacts of abstract facets) is accepted with `"approval": "approved by pattern"` once the contract's independent review agrees; a new pattern or a higher-severity detector goes to the owner individually. Counts per file and detector: [slither/results/triage-summary-2026-11-10.md](../slither/results/triage-summary-2026-11-10.md).

## How often it runs

Fast tier on every push and pull request and at every contract gate.

## Latest result

2026-11-10 21:49: **331 findings, 0 blocking, 331 accepted.**

| Severity | Accepted | Detectors |
|---|---|---|
| High | 138 | `delegate-call-unchecked-address` 103 (router to immutable logic contracts checked at construction), `reentrancy-state-change` 30 (writes after STATICCALL views or under a transient guard), `contract-locks-ether` 2 (only `upgradeToAndCall` is payable), `eth-send-unchecked-address` 2 (timelock execution), `unsafe-casting` 1 (bounded by a prior check) |
| Low | 193 | `unused-error` 139 (errors declared for contracts not yet written), `unchecked-return` 19, `unused-import` 18 (`@inheritdoc` targets), `costly-loop` 10, `require-revert-in-loop` 3, `empty-block` 2 (UUPS hooks), `state-change-without-event` 2 |

## Results folder

- [`aderyn-gate.txt`](results/aderyn-gate.txt), [`aderyn.json`](results/aderyn.json), [`aderyn.sarif`](results/aderyn.sarif), [`aderyn.log`](results/aderyn.log), [`aderyn-triage.json`](results/aderyn-triage.json).
