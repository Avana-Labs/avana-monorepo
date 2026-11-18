Function links point to the interface that declares each function.

# AvanaTimelock lifecycle

The AvanaTimelock is the one executor of every privileged change to Avana on its chain: an OpenZeppelin `TimelockController` with a 12-hour short delay for tightenings and safety actions, a 4-to-5-day normal delay for everything else, a 14-day grace window and a DAO-only cancel for role changes and restorations.

```mermaid
sequenceDiagram
  autonumber
  actor M as Governance multisig
  actor A as Anyone
  actor C as Canceller
  participant TL as AvanaTimelock
  participant PS as ParameterStore
  participant SW as LPVaultSwap
  M->>TL: schedule(PS, 0, tightenMarketUsdCap(1, 4,000,000e8), 0, salt, 43,200)
  Note right of TL: requiredDelay = SHORT_DELAY,<br/>the selector is on the short-delay list
  M->>TL: schedule(SW, 0, addKeeper(K2), 0, salt, 432,000)
  Note right of TL: requiredDelay = normalDelay (5 days)
  A->>TL: execute(PS, 0, data, 0, salt) once ready
  Note right of TL: anyone while publicExecution is on,<br/>OperationExpired after 14 days
  TL->>PS: tightenMarketUsdCap(1, 4,000,000e8)
  C->>TL: cancel(id) before execution
  Note right of TL: a role change or restoring operation<br/>needs DAO_CANCELLER_ROLE
  A->>TL: cleanupExpiredOperation(id) after the 14-day grace
```

## Walkthrough

Setup (Ethereum; proposers: the 4-of-7 governance multisig and the Aave governance executor; `normalDelay` 432,000 s).

1. **Multisig → `schedule`(ParameterStore, `tightenMarketUsdCap(1, 4,000,000e8)`, delay 43,200).** [`requiredDelay`](IAvanaTimelockViews.sol#L46) is [`SHORT_DELAY`](IAvanaTimelockViews.sol#L10) because the selector is on the short-delay list ([`isShortDelaySelector`](IAvanaTimelockViews.sol#L25)). Error: [`DelayBelowRequired`](IAvanaTimelockErrors.sol#L10) for a shorter delay.
2. **Multisig → `schedule`(LPVaultSwap, `addKeeper(K2)`, delay 432,000).** Not on the short list, so it waits [`normalDelay`](IAvanaTimelockViews.sol#L22) = 5 days, long enough for every borrower to exit first.
3. **Anyone → `execute`** once ready, while [`publicExecution`](IAvanaTimelockViews.sol#L52) is on; the target sees `msg.sender == TIMELOCK` (or `APPLICATION_ADMIN`). Error: [`ExecutionNotPublic`](IAvanaTimelockErrors.sol#L31) while off, [`OperationExpired`](IAvanaTimelockErrors.sol#L16) after [`GRACE_PERIOD`](IAvanaTimelockViews.sol#L19) (14 days).
4. **A canceller → `cancel`.** Any `CANCELLER_ROLE` holder cancels an ordinary operation. A role change ([`isRoleChangeOperation`](IAvanaTimelockViews.sol#L61)) or a restoring operation such as `unfreezeAddress` or `restorePriceRoute` ([`isRestoringOperation`](IAvanaTimelockViews.sol#L67)) needs `DAO_CANCELLER_ROLE`. Errors: [`RoleChangeCancelRestricted`](IAvanaTimelockErrors.sol#L22), [`RestoringCancelRestricted`](IAvanaTimelockErrors.sol#L25).
5. **Timelock → [`setNormalDelay`](IAvanaTimelockGovernance.sol#L11)** through its own operation, within [`MIN_NORMAL_DELAY`](IAvanaTimelockViews.sol#L16) (4 days) and [`MAX_DELAY`](IAvanaTimelockViews.sol#L13) (5 days). Event: [`NormalDelayChanged`](IAvanaTimelockEvents.sol#L10). Errors: [`DelayOutOfBounds`](IAvanaTimelockErrors.sol#L13); OpenZeppelin `updateDelay` reverts [`UpdateDelayDisabled`](IAvanaTimelockErrors.sol#L34).
6. **Timelock → [`setShortDelaySelector`](IAvanaTimelockGovernance.sol#L17)** adds or removes a pair only inside the immutable `SHORT_ELIGIBLE` set ([`isShortEligible`](IAvanaTimelockViews.sol#L32)). Event: [`ShortDelaySelectorSet`](IAvanaTimelockEvents.sol#L13). Error: [`InvalidShortDelaySelector`](IAvanaTimelockErrors.sol#L37).
7. **Timelock → [`togglePublicExecution`](IAvanaTimelockGovernance.sol#L25).** Event: [`PublicExecutionToggled`](IAvanaTimelockEvents.sol#L16).
8. **Anyone → [`cleanupExpiredOperation`](IAvanaTimelockGovernance.sol#L31)`(id)`** after the 14-day grace, so the same calls can be scheduled again. Event: [`ExpiredOperationCleaned`](IAvanaTimelockEvents.sol#L19). Error: [`OperationNotExpired`](IAvanaTimelockErrors.sol#L19).
9. **Guardians act without the timelock** for emergency actions (MarketRegistry `freeze`, `pause`, `freezeAddress`, `tripMarketBreaker`, `useStandbyRoute`); the timelock can do the same at the short delay and lifts restrictions at the normal delay.

## What the UI reads and calls

- Lens: none; a governance UI reads [`requiredDelay`](IAvanaTimelockViews.sol#L46), [`isOperationExpired`](IAvanaTimelockViews.sol#L55) and OpenZeppelin `getOperationState`.
- Events to index: OpenZeppelin `CallScheduled`, `CallExecuted`, `Cancelled`; [`NormalDelayChanged`](IAvanaTimelockEvents.sol#L10), [`ShortDelaySelectorSet`](IAvanaTimelockEvents.sol#L13), [`PublicExecutionToggled`](IAvanaTimelockEvents.sol#L16), [`ExpiredOperationCleaned`](IAvanaTimelockEvents.sol#L19). Borrowers watch `CallScheduled` for normal-delay operations to decide whether to exit.
- User calls: `execute` (anyone while public execution is on), [`cleanupExpiredOperation`](IAvanaTimelockGovernance.sol#L31).

## Spec

- [2.15 Governance and Timelock](../../../../docs/spec/02-contracts/15-governance-and-timelock.md): `REQ-ACCESS-001`, `REQ-ACCESS-029`, `REQ-ACCESS-125`, `REQ-ACCESS-126`, `REQ-ACCESS-140`–`REQ-ACCESS-144`, `REQ-ACCESS-152`–`REQ-ACCESS-155`, `SPEC-GOV-001`–`SPEC-GOV-003`, `SPEC-GOV-013`, `SPEC-GOV-015`.
- [1.4 Permissions and roles](../../../../docs/spec/01-architecture/04-permissions-and-roles.md) for delay classes.
