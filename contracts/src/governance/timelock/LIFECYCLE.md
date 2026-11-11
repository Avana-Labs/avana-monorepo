Implementation pending: links point to interfaces; update to implementation functions once the hand-written contracts exist.

# AvanaTimelock lifecycle

The AvanaTimelock is the one executor of every privileged change to Avana on its chain: an OpenZeppelin `TimelockController` with a 12-hour short delay for tightenings and safety actions, a 4-to-5-day normal delay for everything else, a 14-day grace window and a DAO-only cancel for role changes and restorations.

## Walkthrough

Setup (Ethereum; proposers: the 4-of-7 governance multisig and the Aave governance executor; `normalDelay` 432,000 s at launch).

1. **Multisig → `schedule`(ParameterStore, `tightenMarketUsdCap(1, 4,000,000e8)`, delay 43,200).** [`requiredDelay`](IAvanaTimelockViews.sol#L77) is [`SHORT_DELAY`](IAvanaTimelockViews.sol#L11) because the selector is on the short-delay list ([`isShortDelaySelector`](IAvanaTimelockViews.sol#L33)). Error: [`DelayBelowRequired`](IAvanaTimelockErrors.sol#L13) for a shorter delay.
2. **Multisig → `schedule`(LPVaultSwap, `addKeeper(K2)`, delay 432,000).** Not on the short list, so it waits [`normalDelay`](IAvanaTimelockViews.sol#L27) = 5 days, long enough for every borrower to exit first.
3. **Anyone → `execute`** once ready, while [`publicExecution`](IAvanaTimelockViews.sol#L84) is on; the target sees `msg.sender == TIMELOCK` (or `APPLICATION_ADMIN`). Error: [`ExecutionNotPublic`](IAvanaTimelockErrors.sol#L50) while off, [`OperationExpired`](IAvanaTimelockErrors.sol#L23) after [`GRACE_PERIOD`](IAvanaTimelockViews.sol#L23) (14 days).
4. **A canceller → `cancel`.** Any `CANCELLER_ROLE` holder cancels an ordinary operation. A role change ([`isRoleChangeOperation`](IAvanaTimelockViews.sol#L98)) or a restoring operation such as `unfreezeAddress` or `restorePriceRoute` ([`isRestoringOperation`](IAvanaTimelockViews.sol#L106)) needs `DAO_CANCELLER_ROLE`. Errors: [`RoleChangeCancelRestricted`](IAvanaTimelockErrors.sol#L33), [`RestoringCancelRestricted`](IAvanaTimelockErrors.sol#L39).
5. **Timelock → [`setNormalDelay`](IAvanaTimelockGovernance.sol#L15)** through its own operation, within [`MIN_NORMAL_DELAY`](IAvanaTimelockViews.sol#L19) (4 days) and [`MAX_DELAY`](IAvanaTimelockViews.sol#L15) (5 days). Event: [`NormalDelayChanged`](IAvanaTimelockEvents.sol#L13). Errors: [`DelayOutOfBounds`](IAvanaTimelockErrors.sol#L18); OpenZeppelin `updateDelay` reverts [`UpdateDelayDisabled`](IAvanaTimelockErrors.sol#L54).
6. **Timelock → [`setShortDelaySelector`](IAvanaTimelockGovernance.sol#L27)** adds or removes a pair only inside the immutable `SHORT_ELIGIBLE` set ([`isShortEligible`](IAvanaTimelockViews.sol#L54)). Event: [`ShortDelaySelectorSet`](IAvanaTimelockEvents.sol#L20). Error: [`InvalidShortDelaySelector`](IAvanaTimelockErrors.sol#L62).
7. **Timelock → [`togglePublicExecution`](IAvanaTimelockGovernance.sol#L38).** Event: [`PublicExecutionToggled`](IAvanaTimelockEvents.sol#L25).
8. **Anyone → [`cleanupExpiredOperation`](IAvanaTimelockGovernance.sol#L47)`(id)`** after the 14-day grace, so the same calls can be scheduled again. Event: [`ExpiredOperationCleaned`](IAvanaTimelockEvents.sol#L30). Error: [`OperationNotExpired`](IAvanaTimelockErrors.sol#L28).
9. **Guardians act without the timelock** for emergency actions (MarketRegistry `freeze`, `pause`, `freezeAddress`, `tripMarketBreaker`, `useStandbyRoute`); the timelock can do the same at the short delay and lifts restrictions at the normal delay.

## What the UI reads and calls

- Lens: none; a governance UI reads [`requiredDelay`](IAvanaTimelockViews.sol#L77), [`isOperationExpired`](IAvanaTimelockViews.sol#L89) and OpenZeppelin `getOperationState`.
- Events to index: OpenZeppelin `CallScheduled`, `CallExecuted`, `Cancelled`; [`NormalDelayChanged`](IAvanaTimelockEvents.sol#L13), [`ShortDelaySelectorSet`](IAvanaTimelockEvents.sol#L20), [`PublicExecutionToggled`](IAvanaTimelockEvents.sol#L25), [`ExpiredOperationCleaned`](IAvanaTimelockEvents.sol#L30). Borrowers watch `CallScheduled` for normal-delay operations to decide whether to exit.
- User calls: `execute` (anyone while public execution is on), [`cleanupExpiredOperation`](IAvanaTimelockGovernance.sol#L47).

## Spec

- [2.15 Governance and Timelock](../../../../spec/02-contracts/15-governance-and-timelock.md): `REQ-ACCESS-001`, `REQ-ACCESS-029`, `REQ-ACCESS-125`, `REQ-ACCESS-126`, `REQ-ACCESS-140`–`REQ-ACCESS-144`, `REQ-ACCESS-152`–`REQ-ACCESS-155`, `SPEC-GOV-001`–`SPEC-GOV-003`, `SPEC-GOV-013`, `SPEC-GOV-015`.
- [1.4 Permissions and roles](../../../../spec/01-architecture/04-permissions-and-roles.md) for delay classes.
