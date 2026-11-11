# AvanaTimelock review

| Item | Value |
|---|---|
| Date | 2026-11-10 |
| Contract | `src/governance/timelock/AvanaTimelock.sol`, `TimelockSelectors.sol` |
| Spec | [2.15 Governance and Timelock](../../../spec/02-contracts/15-governance-and-timelock.md) |
| Method | Independent adversarial review: the reviewer receives only the spec page and the code, writes a PoC test for every finding it can demonstrate, and reports findings by severity |
| Result | 2 Medium, 5 Low; every finding fixed with a test |

## Findings

| # | Severity | Finding | Decision | Status |
|---|---|---|---|---|
| 1 | Medium | Public execution could be switched off by a role-change operation (revoking `EXECUTOR_ROLE` from `address(0)`) that only the DAO can cancel, so a guardian could not stop it | Fixed with a test | fixed |
| 2 | Medium | The timelock could revoke its own `DEFAULT_ADMIN_ROLE` | Fixed with a test; `REQ-ACCESS-182`: the timelock keeps its admin role | fixed |
| 3–7 | Low (5) | Five Low findings, among them: `isOperationExpired` overflowed for a huge `readyAt`; an executed operation could clean up another expired one; payload-length handling of short-listed pairs (four bytes versus three) | Fixed with tests | fixed |

## Spec changes at the timelock gate

Storage of public execution and clean-up written as implemented; check order (`REQ-ACCESS-117`); exact selector allowlists (`REQ-ACCESS-142`, `REQ-ACCESS-181`); the timelock keeps its admin role (`REQ-ACCESS-182`); constructor role checks (`REQ-ACCESS-183`); overflow-free expiry (`SPEC-GOV-013`); buy-route names removed from `INV-051`, `INV-090`, `ATTACK-097`.

## Evidence after the fixes

47 unit and fuzz tests, the `TEST-212` invariant suite, 7 Halmos checks, Hypothesis and Z3 governance models updated and passing, Medusa 9 / 9 on `AvanaTimelockProperties` (1,788,580 calls), fast tier green with 9 triage rows (approved).

## PoC tests

- `test_revokeOpenExecutorIsDaoOnly`, `test_selfAdminRevocable`, `test_expiredViewOverflow`, `test_executeCleansOther`, `test_fourBytes` in `Poc.t.sol`

The PoC files are copied from the review workspace into [`poc/`](poc/). Each one demonstrates its finding against the code as reviewed, with imports at their review-time paths; after a fix lands, the regression test in `contracts/test/` asserts the fixed behavior.
