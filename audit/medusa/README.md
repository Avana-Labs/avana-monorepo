# Medusa

## What it proves

Medusa fuzzes the same `*Properties` harnesses as Echidna (plus any Medusa-only harness in `test/invariant/medusa/`), property and assertion tests in one campaign, with a different mutation engine and parallel workers. Arithmetic panic `0x11` is not a failure (solc 0.8 reverts on overflow); harnesses assert their bounds explicitly.

## How to run

From `contracts/`, Medusa 1.5.1 from `tools/bin/`:

```bash
script/security-slow.sh build medusa
MEDUSA_TIMEOUT=1800 script/security-slow.sh build medusa       # nightly budget
```

Configuration: `contracts/medusa.json` (8 workers); `MEDUSA_TIMEOUT` 900 s per harness by default; corpus in `out-security/corpus/medusa/`.

## Scope

The 19 harnesses listed in [echidna](../echidna/).

## How often it runs

Slow tier at each layer gate and nightly in CI; a 24-hour campaign per layer before audit.

## Latest result

| Run | Harness | Result |
|---|---|---|
| 2026-11-10 17:05 | AvanaRolesProperties | 5 / 5 pass |
| 2026-11-10 17:21 | AvanaTimelockProperties | 9 / 9 pass; 14 m 57 s, 1,788,580 calls, 1,083 branches, 0 failures |
| 2026-11-10 16:02 (Lock gate) | LockProperties, LockSlotProperties | 7 / 7 and 6 / 6 pass |
| 2026-11-10 17:21 | LockProperties | Log ends after compilation (the run was stopped) |

## Results folder

- [`AvanaRolesProperties.log`](results/AvanaRolesProperties.log), [`AvanaTimelockProperties.log`](results/AvanaTimelockProperties.log), [`LockProperties.log`](results/LockProperties.log): the logs in `out-security/medusa/`. The 16:02 Lock run is in [echidna/results/security-slow-run-lock-2026-11-10.log](../echidna/results/security-slow-run-lock-2026-11-10.log).
