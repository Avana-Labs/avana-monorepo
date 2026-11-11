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

Layer gate (2.1 … 2.6), both kinds (decided 2026-11-10). First run at the layer 2.1 gate. At the Lock gate a hand-made mutation (two checks swapped) was caught by the Halmos checks.

## Latest result

Not run yet as a campaign; the first run is at the layer 2.1 gate. `results/` is empty until then.
