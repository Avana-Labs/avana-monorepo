# hevm

## What it proves

`hevm symbolic` proves each assertion entry point of every `*Properties` harness (QED: no reachable assertion violation; a partial exploration fails), checks the runtime code of every `src/` contract and library for assertion violations, and runs `hevm test` on any `prove_` function in `test/symbolic/`.

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

## Results folder

- The 14 per-target logs from `out-security/hevm/`, each ending in `QED: No reachable property violations discovered`.
