# Coverage

## What it proves

`forge coverage` measures line and branch coverage of `contracts/src/` by the unit, fuzz, integration and hostile suites, with the optimizer and via-IR off for exact source maps. CI enforces a branch-coverage minimum per contract (decided 2026-11-10), so a branch with no test fails the build.

## How to run

```bash
cd contracts && FOUNDRY_PROFILE=coverage forge coverage --report lcov
```

Configuration: `contracts/foundry.toml` `[profile.coverage]` (64 fuzz runs; no fork, Halmos or invariant suites).

## Scope

Every implementation under `contracts/src/`.

## How often it runs

CI, per contract.

## Latest result

No run is recorded in this folder; the per-file branch minimums are in `contracts/security/coverage-thresholds.json`.
