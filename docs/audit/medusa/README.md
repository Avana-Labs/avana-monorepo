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
| 2026-11-14 (run 43595414156, `aa340fb`) | LPOracleProperties | 6 / 7 pass; `property_servedByState` failed after 6 calls: a Drifting market whose token A routes disagree served the lower-route price 191,999,808, above the accepted price 182,999,817. `SPEC-ORC-017` serves the fresh price while Live or Drifting (at most it while a token disagrees), so the property, which still required a Drifting market to serve at most the accepted price, was wrong, not the oracle. The property now requires exactly the `SPEC-ORC-017` value in Live and Drifting: the fresh price, or `min(lower, fresh)` while a token disagrees (`pauseActive` or `disagreementExpired`), and 1 in place of 0; `test/unit/LPOracle.FuzzHarness.unit.t.sol` replays the sequence ([register](../findings-register.md) `SLOW-04`) |
| 2026-11-15 (run 43653574421, `48864ef`) | LPOracleProperties | `property_servedByState` failed again after 3 calls, the same stale rule (the fix above was not yet on `main`): Drifting, token A's primary at 1.12 disagreeing with its alternate at 1.00, served `min(lower, fresh)` = 199,999,800 (the stable ceiling makes the two equal), above the accepted 198,999,801; the replay test holds this sequence too |
| 2026-11-15 (run 43653574421, `48864ef`) | DebtOracleProperties | 9 / 10 pass; `property_nonLiveServesAtLeastAccepted` failed after one call, `move(0, 64)`: the primary feed rose 50 % to 149,985,000, the routes disagreed, and the Drifting DebtOracle served 99,990,000, the lower route and the accepted price. `SPEC-ORC-018` serves `max(min(p, b), A)` while Drifting; the property still expected `max(p, b, A)`, so the property was wrong, not the oracle. It now expects `max(min(p, b), A)`; `test/unit/DebtOracle.FuzzHarness.unit.t.sol` replays the call ([register](../findings-register.md) `SLOW-03`) |

## Results folder

- [`AvanaRolesProperties.log`](results/AvanaRolesProperties.log), [`AvanaTimelockProperties.log`](results/AvanaTimelockProperties.log), [`LockProperties.log`](results/LockProperties.log): the logs in `out-security/medusa/`. The 16:02 Lock run is in [echidna/results/security-slow-run-lock-2026-11-10.log](../echidna/results/security-slow-run-lock-2026-11-10.log).
