# SMTChecker

## What it proves

The Solidity SMTChecker (CHC engine) model-checks the contracts listed in `[profile.smt.model_checker]` for assertion failures, underflow, overflow, division by zero, constant conditions, empty-array pops, out-of-bounds access and balance, and reports contract and reentrancy invariants. It carries `PROP-043` (the immutable contracts and the MarketRegistry) and `PROP-044` (LPOracle, DebtOracle, LPVaultSwap, RiskModule, ParameterStore and the three swap routes) of [5.2](../../spec/05-verification/02-formal-properties.md).

## How to run

```bash
cd contracts && FOUNDRY_PROFILE=smt forge build --force 2>&1 | tee smt.log
! grep -q 'happens here' smt.log      # what the CI job checks
```

Configuration: `contracts/foundry.toml` `[profile.smt]` (`engine = "chc"`, `timeout = 100_000`, targets and contracts listed there).

## Scope

The profile names 19 contracts. A file not yet written is reported as a missing source and checked once it lands.

## How often it runs

Slow tier at each layer gate (2026-11-10 decision) and the `SMTChecker` CI job.

## Latest result

2026-11-10 15:29, Lock gate: no counterexample (`happens here` absent); the checker reports unsupported constructs (`Assertion checker does not yet implement type error` on custom-error reverts) and missing sources for the contracts not yet written. Two later runs during the timelock gate were stopped (exit 143). The next full run is at the layer 2.1 gate.

## Results folder

- [`smt-lock-2026-11-10.log`](results/smt-lock-2026-11-10.log): output of `FOUNDRY_PROFILE=smt forge build --force` at the Lock gate.
