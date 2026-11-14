# Triage summary

Generated on 2026-11-10 from the triage files in `contracts/security/` and the inline suppression comments in `contracts/src/`. Each entry carries a one-line reason, and `script/security-gate.py` fails the gate on an entry without one.

| File | Entries | Approval |
|---|---|---|
| `security/slither-triage.json` | 87 | 87 approved (Josue, 2026-11-10, by pattern) |
| `security/aderyn-triage.json` | 130 | 1 scoped by `while` condition; 129 approved (Josue, 2026-11-10, by pattern) |
| `security/slither-upgradeability-triage.json` | 2 | 2 approved (Josue, 2026-11-10, by pattern) |
| `security/mythril-triage.json` | 0 | — |

## `slither-triage.json` by detector

| Detector | Entries |
|---|---|
| `calls-loop` | 18 |
| `unused-return` | 16 |
| `reentrancy-events` | 11 |
| `reentrancy-no-eth` | 8 |
| `assembly` | 6 |
| `timestamp` | 6 |
| `low-level-calls` | 5 |
| `reentrancy-benign` | 4 |
| `unimplemented-functions` | 4 |
| `too-many-digits` | 3 |
| `uninitialized-state` | 3 |
| `unused-state` | 2 |
| `arbitrary-send-erc20` | 1 |

## `aderyn-triage.json` by detector

| Detector | Entries |
|---|---|
| `unused-error` | 38 |
| `reentrancy-state-change` | 30 |
| `unchecked-return` | 19 |
| `unused-import` | 18 |
| `costly-loop` | 9 |
| `delegate-call-unchecked-address` | 4 |
| `require-revert-in-loop` | 3 |
| `eth-send-unchecked-address` | 2 |
| `contract-locks-ether` | 2 |
| `empty-block` | 2 |
| `state-change-without-event` | 2 |
| `unsafe-casting` | 1 |

## `slither-upgradeability-triage.json` by detector

| Detector | Entries |
|---|---|
| `initialize-target` | 2 |

## Detectors excluded in `slither-triage.json`

| Detector | Reason |
|---|---|
| `naming-convention` | Getters of immutables and constants keep the SCREAMING_SNAKE_CASE name of the value they expose (HUB(), ADAPTER(), RESCUE_MIN_PLEDGE_USD()), as Aave V4 and OpenZeppelin name them; naming is not a security property. |
| `unindexed-event-address` | Which event fields are indexed is fixed by the spec's event definitions and the indexer's topic layout, not chosen per detector. |

## Inline suppressions in `contracts/src/`

171 comments (a `disable-start`/`disable-end` pair counts as two).

| Tool | Rule | Comments |
|---|---|---|
| forge lint | `reentrancy-events` | 42 |
| forge lint | `unsafe-typecast` | 31 |
| forge lint | `calls-loop` | 30 |
| forge lint | `unused-return` | 16 |
| forge lint | `reentrancy-no-eth` | 12 |
| solhint | `comprehensive-interface` | 11 |
| forge lint | `costly-loop` | 10 |
| solhint | `no-inline-assembly` | 6 |
| forge lint | `missing-events-access-control` | 6 |
| solhint | `avoid-low-level-calls` | 3 |
| forge lint | `require-revert-in-loop` | 2 |
| forge lint | `unused-state-variables` | 2 |
