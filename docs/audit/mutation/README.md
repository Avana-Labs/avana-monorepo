# Mutation testing

## What it proves

Mutation testing changes the code (flipped conditions, removed checks, swapped operators) and requires a test or rule to fail for each change. A surviving mutant is a behavior no check pins down.

| Kind | Tool | Target |
|---|---|---|
| Foundry suite | `slither-mutate` | Each contract's unit, fuzz and invariant tests |
| Formal rules | `certoraMutate` | Each contract whose Certora rules verify |

## How to run

```bash
cd contracts
.venv/bin/slither-mutate src/lock/lock/Lock.sol --test-cmd 'forge test --match-path "test/unit/Lock.unit.t.sol"'
.venv/bin/certoraMutate certora/conf/Lock.conf
```

Both tools are installed in `contracts/.venv/bin/`. `certoraMutate` reads the conf's `mutations` section, generates the mutants with Gambit and runs the prover on each.

## Scope

Every contract of the layer at each layer gate.

## How often it runs

Layer gate (2.1 … 2.6), both kinds (decided 2026-11-10), and every push to `main` in CI (`mutation-gate.yml`; by hand for one layer or all six). Each target runs in its own job of at most 4 hours: `slither-mutate` per contract and mutator group (three groups that together test every mutant), Gambit per contract, Necessist per test file and `certoraMutate` per Certora conf (with the `CERTORAKEY` secret; without it each job passes with a "certoraMutate not run" warning). `mutation-summary` passes only when every job passed. `certoraMutate` reads the conf's `mutations` section, which every conf of Avana code has: Gambit mutants of each `src/` implementation file the verified contract is built from, with the per-file count of `security/mutation-layers.json` (10 in layer 2.1 and outside the layers, 20 in layers 2.2 to 2.6). `Hub.conf` verifies the unmodified Aave V4 Hub, so it has no mutants and its rules run only in the `certora` job. [contracts/certora/README.md](../../../contracts/certora/README.md#mutation-testing-certoramutate) lists the rules and how to check a conf without a key. `AaveAdapter.conf`, `AaveAdapterGates.conf` and `LPVaultSwap.conf` name `AaveAdapter.sol` and `LPVaultSwap.sol`, which are not in `src/` yet, so their jobs fail with the secret set until those files exist. At the Lock gate a hand-made mutation (two checks swapped) was caught by the Halmos checks.

## Latest result

No campaign run is recorded in this folder; `results/` is empty.
