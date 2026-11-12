# hevm

## What it proves

`hevm symbolic` proves each assertion entry point of every `*Properties` harness (QED: no reachable assertion violation; a partial exploration fails), checks the runtime code of every `src/` contract and library for assertion violations, and runs `hevm test` on any `prove_` function in `test/symbolic/`.

## The state hevm runs in

Every target runs against a local anvil chain (`hevm symbolic --rpc`), so it starts from a state a deployment can have:

- **Harness entry points.** The harness is deployed on the chain first. Its constructor deploys and configures the contracts it tests, as it does for Echidna and Medusa, and each entry point is then explored from that state; every contract the call reaches executes from its deployed code and storage.
- **`src/` runtime code.** The contract's runtime code is placed on the chain with each address immutable filled with an address of its own, as a constructor fills it, and each own-address immutable (`_SELF`, `__self`, `_cachedThis`) set to the contract's address. Every filled address, and address 0 (an address read from the empty storage), holds the code `PUSH0 PUSH0 REVERT`, so a call to it reverts with empty data, which the caller passes on or handles; an address the caller passes resolves only to accounts on the chain (`--only-deployed`), so a caller-chosen contract cannot hand back free revert data either. A `Panic(1)` can then only come from an `assert` in the contract's own code. Paths that continue after a successful call to another contract are explored by the harness targets, where that contract is deployed.

Why: on bare runtime code the immutables are zero, the storage is empty and every contract called is unknown code whose revert data hevm leaves free. Every call whose failure the contract passes on (a bubbled revert) then became an "assertion violation" with `Panic(1)` as that free data. The run on `main` of 2026-11-12 (commit `a6d7acd`) reported such counterexamples on 41 targets, for example 18 on `Collateralization`, one per function that first calls the Lock (`nextRecordId()` included: `ILock(_LOCK).holder()` with `_LOCK = 0`); `ParameterStoreProperties` delegatecalls its logic contracts through immutables that were zero. None was an assertion of Avana's code: the only `assert` in `src/` is `CollateralizationLedger` line 94 (`pos < len` in the seizure list), which `CollateralizationProperties` and the Collateralization ledger invariants exercise. The other failed harness targets were partial explorations (z3 out of memory, symbolic exponents in `LPPriceMath`, the iteration bound), which still fail the run.

## How to run

From `contracts/`, hevm 0.58.0 with z3:

```bash
script/security-slow.sh build hevm
HEVM_SMT_TIMEOUT=600 script/security-slow.sh build hevm       # nightly budget
```

`HEVM_SMT_TIMEOUT` is 300 s per query by default.

## Scope

Harness entry points of AvanaRoles, Lock and LockSlot; runtime code of AmmConstants, AvanaRoles, BreakerReasons, LensConstants, Lock, LockSlot, RiskModuleConstants. `test/symbolic/` holds no `prove_` function yet.

## How often it runs

Slow tier at each layer gate and on every push to `main` in CI (`security-slow.yml`), one job per target: each harness's assertion entry points and each `src/` contract (`HEVM_TARGETS`).

## Latest result

2026-11-10 16:01: 7 harness entry points QED (`AvanaRolesProperties.checkRolePair`, `LockProperties.acquireWithoutRelease`, `memberCycle`, `outsiderAcquire`, `revertedOuterCall`, `LockSlotProperties.enter`, `enterAndRelease`); 7 runtime codes QED. Contracts merged after that run are not in this result.

2026-11-12 (local check of the chain set-up on the a6d7acd build, `HEVM_SMT_TIMEOUT=120`, a sample of the 41 targets that failed on `main`): `ParameterStoreProperties` 18 of 18 entry points QED (each had a bubbled-revert counterexample before); `ParameterStoreAdminOracleProperties` 6 of 6 and `ParameterStoreAdminRiskProperties` 5 of 5 QED; `ParameterStoreListingProperties` 3 of 4 QED, `setFeed` still fails: a partial exploration (symbolic exponent `10 ** decimals`, iteration bound) with one model (`setFeed(3, 2, 475715)`) that, replayed on the deployed harness with `cast call`, does not revert, so it is not a reachable assertion; `RiskModuleProperties.capSplit` QED, the other entry points not finished in the local run. `src/`: Collateralization (18 counterexamples before), CoverageSpoke, FlashLiquidator, Lock, PayoutEscrow, ProxyManager, RiskModuleBorrowLogic and RiskModuleStatusLogic QED; AaveV3FlashSource, DebtOracle, ParameterStore and VaultTokenFactory no assertion violation, explored partially. The harness entry points that only explore partially (`LPPriceMathProperties` and `SettlementMathProperties`: symbolic exponents and z3 running out of memory on CI; `ParameterStoreListingProperties.setFeed`) still fail the gate until their decimals are taken from concrete cases.

## Results folder

- The 14 per-target logs from `out-security/hevm/`, each ending in `QED: No reachable property violations discovered`.
