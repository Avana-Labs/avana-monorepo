# Lock review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/lock/lock/Lock.sol`, `LockSlot.sol` |
| Spec | [2.16 Lock](../../../spec/02-contracts/16-lock.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | No Critical, High or Medium finding; every point applied |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Low, Info | Every point the review raised (none above Low) | All applied, with the other changes of the Lock gate: getters refuse delegatecall; a free Lock refuses every release; the constructor refuses zero or equal members (`REQ-LOCK-029`); members release only at the end of an outer entry point (`REQ-LOCK-030`); `REQ-LOCK-002`/`003`/`005`/`008`/`009`/`018` reworded | fixed |

## Evidence after the fixes

24 unit tests; 6 Halmos checks pass and a swapped-check mutation is caught; Medusa and hevm QED on `LockProperties`; Mythril 0 findings; SMTChecker no counterexample; Slither 2 triaged `assembly` entries (the `TLOAD`/`TSTORE` of the fixed ERC-7201 slot), approved.

## PoC tests

None: no finding needed a PoC.
