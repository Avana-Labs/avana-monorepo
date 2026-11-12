# Mythril

## What it proves

Mythril 0.24.8 symbolically executes the runtime bytecode of every `src/` contract and library over three symbolic transactions, looking for reachable ether theft, arbitrary storage writes, delegatecalls or jumps, self-destruct, unchecked return values, state changes after calls, transaction-order dependence and user assertion failures. `IntegerArithmetics` (SWC-101) is off: solc 0.8 reverts on overflow, and the optimizer's `SUB`+`ISZERO` pattern reads as a false underflow on bytecode. It runs locally; no code goes to an external service.

## How to run

```bash
cd contracts && script/security-slow.sh build mythril       # calls script/security-mythril.sh
```

Configuration: `contracts/security/mythril.conf` (modules, `MYTHRIL_TX_COUNT=3`, 900 s per contract, 100 s per solver query, depth 128); triage `contracts/security/mythril-triage.json`; gate High, Medium and Low.

## Scope

Runtime code of AmmConstants, AvanaRoles, BreakerReasons, LensConstants, Lock, LockSlot, RiskModuleConstants (the deployable code at the last run).

## How often it runs

Slow tier at each layer gate and on every push to `main` in CI (`security-slow.yml`), one job per group of eight `src/` contracts (`MYTHRIL_CONTRACTS`).

## Latest result

2026-11-10 16:02: **0 findings, 0 blocking, 0 accepted**; every contract analysed with `success: true`. Contracts merged after that run are not in this result.

## Results folder

- [`mythril-gate.txt`](results/mythril-gate.txt), [`mythril.json`](results/mythril.json), [`per-contract/`](results/per-contract/), [`mythril-triage.json`](results/mythril-triage.json).
