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

CI, per contract. First run at the layer 2.1 gate.

## Latest result

Not run yet; the first run is at the layer 2.1 gate. `results/` is empty until then.
