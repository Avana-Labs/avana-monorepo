# Medusa

## What it proves

Medusa fuzzes the same `*Properties` harnesses as Echidna (plus any Medusa-only harness in `test/invariant/medusa/`), property and assertion tests in one campaign, with a different mutation engine and parallel workers. Arithmetic panic `0x11` is not a failure (solc 0.8 reverts on overflow); harnesses assert their bounds explicitly.

## How to run

From `contracts/`, Medusa 1.5.1 from `tools/bin/`:

```bash
script/security-slow.sh build medusa
MEDUSA_TIMEOUT=1800 script/security-slow.sh build medusa       # full budget
```

Configuration: `contracts/medusa.json` (8 workers); `MEDUSA_TIMEOUT` 900 s per harness by default; corpus in `out-security/corpus/medusa/`.

Each harness is fuzzed on a build of its own file and imports (`out-security/build/medusa/<Name>`, slow-tier settings), with a copy of `medusa.json` (`out-security/medusa/<Name>.json`) that points crytic-compile, Medusa's Slither pass and their caches at that build. On the build of all of `src/`, `test/` and `script/` (446 MB compressed on commit `c07ddca`), every Medusa job of run 43387180884 lost its 16 GB runner 10 to 16 minutes in with no log, as Echidna did on that build. The log is streamed to the job output as well as kept in `out-security/medusa/<Name>.log`, so a run that dies still shows how far it got.

## Scope

The 27 harnesses listed in [echidna](../echidna/).

## How often it runs

Slow tier at each layer gate and on every push to `main` in CI (`security-slow.yml`), one job per harness at 1,800 seconds with the harness's corpus kept between runs. Before audit, a 24-hour campaign per layer: `security-slow.yml` started by hand with `campaign` set to the layer runs eight 3-hour jobs per harness (no call limit), each with a fresh seed, then merges their corpora into the stored corpus.

## Latest result

| Run | Harness | Result |
|---|---|---|
| 2026-11-10 17:05 | AvanaRolesProperties | 5 / 5 pass |
| 2026-11-10 17:21 | AvanaTimelockProperties | 9 / 9 pass; 14 m 57 s, 1,788,580 calls, 1,083 branches, 0 failures |
| 2026-11-10 16:02 (Lock gate) | LockProperties, LockSlotProperties | 7 / 7 and 6 / 6 pass |
| 2026-11-10 17:21 | LockProperties | Log ends after compilation (the run was stopped) |

## Results folder

- [`AvanaRolesProperties.log`](results/AvanaRolesProperties.log), [`AvanaTimelockProperties.log`](results/AvanaTimelockProperties.log), [`LockProperties.log`](results/LockProperties.log): the logs in `out-security/medusa/`. The 16:02 Lock run is in [echidna/results/security-slow-run-lock-2026-11-10.log](../echidna/results/security-slow-run-lock-2026-11-10.log).
