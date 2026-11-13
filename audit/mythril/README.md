# Mythril

## What it proves

Mythril 0.24.8 symbolically executes the runtime bytecode of every `src/` contract and library over three symbolic transactions, looking for reachable ether theft, arbitrary storage writes, delegatecalls or jumps, self-destruct, unchecked return values, state changes after calls, transaction-order dependence and user assertion failures. `IntegerArithmetics` (SWC-101) is off: solc 0.8 reverts on overflow, and the optimizer's `SUB`+`ISZERO` pattern reads as a false underflow on bytecode. It runs locally; no code goes to an external service.

## The code Mythril runs

Mythril runs runtime code at address 0, and solc leaves immutables as zero words in the runtime code. With zero immutables, every call a contract makes to a contract it was built with (the Lock, the Hub, the Pool, the ParameterStore, a sibling logic contract) called the analysed contract itself, and the dispatcher's revert on the unknown selector was reported as a requirement violation in a nested call (SWC-123). The run on `main` of 2026-11-12 (commit `a6d7acd`) failed nine groups on such findings in 15 contracts (for example `AaveV3FlashSource.maxFlashLoan(address)`: `IPool(POOL).getConfiguration` with `POOL = 0` re-entered `AaveV3FlashSource` itself), plus SWC-113 and SWC-116 findings in paths reached the same way. No deployment has a zero immutable there: constructors are given deployed contracts and reject zero addresses or check the code behind them.

`script/security-targets.py runtime-code` therefore fills every address immutable with an address of its own (`0xA7A4…01`, `…02`, …), read from the build info (an artifact's `ast` can come from another compilation unit than its bytecode), and keeps the own-address immutables (`_SELF`, `__self`, `_cachedThis`) at 0, the analysed contract's address. A filled address holds no code in Mythril's world, so calls to it return symbolic data, as calls to an unknown contract do. On the same build, with the immutables filled, the contracts that had findings were rerun locally: see "Latest result".

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

2026-11-12 (local rerun, a6d7acd build, address immutables filled, execution timeout 300 s for the first six and 60 s for the rest; the nightly job uses 900 s): the 18 contracts with findings on `main` (AaveV3FlashSource, CoverageSpoke, DebtOracle, FlashLiquidator, OperatorFlashLiquidator, Collateralization, SlipstreamIntegration, UniswapV3Integration, RiskModule and its Borrow, Breaker, Drift, Pledge and Status logic, MarketRegistry and MarketRegistryActivationLogic in both builds): **no SWC-123**; 9 Low findings, all accepted in `security/mythril-triage.json` pending Josue's review: SWC-113 (several calls in one transaction) in `RiskModule.pokeConfig`, `RiskModuleBorrowLogic.debtValueUsd`, `RiskModulePledgeLogic.usdToRestore` and `MarketRegistryActivationLogic.marketDrift` (two builds), each calling only contracts fixed at deployment and failing closed; SWC-116 (block.timestamp) in `MarketRegistry.freezesInWindow` (two builds), the specified clock of the guardian freeze limit.

## Results folder

- [`mythril-gate.txt`](results/mythril-gate.txt), [`mythril.json`](results/mythril.json), [`per-contract/`](results/per-contract/), [`mythril-triage.json`](results/mythril-triage.json).
