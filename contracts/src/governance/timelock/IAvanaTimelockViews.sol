// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaTimelockViews
/// @notice Delay constants, the normal delay, the short-delay list, public execution and operation status of the
/// AvanaTimelock. OpenZeppelin `getMinDelay()` returns `SHORT_DELAY` for life. Every view here except
/// `requiredDelay` (length mismatch) never reverts.
interface IAvanaTimelockViews {
    /// @notice Short delay: 43,200 seconds (12 hours).
    /// @custom:spec REQ-ACCESS-140, SPEC-GOV-001
    function SHORT_DELAY() external view returns (uint256);

    /// @notice Upper bound of the normal delay: 432,000 seconds (5 days).
    /// @custom:spec REQ-ACCESS-140, SPEC-GOV-003
    function MAX_DELAY() external view returns (uint256);

    /// @notice Lower bound of the normal delay: 345,600 seconds (4 days), the exit-window floor.
    /// @custom:spec REQ-ACCESS-140, REQ-ACCESS-154, SPEC-GOV-003, SPEC-GOV-015
    function MIN_NORMAL_DELAY() external view returns (uint256);

    /// @notice How long a ready operation stays executable: 1,209,600 seconds (14 days).
    /// @custom:spec REQ-ACCESS-140, SPEC-GOV-002, SPEC-GOV-013
    function GRACE_PERIOD() external view returns (uint256);

    /// @notice Current normal delay, seconds (432,000 at launch).
    /// @custom:spec REQ-ACCESS-140, SPEC-GOV-003
    function normalDelay() external view returns (uint256);

    /// @notice Whether `(target, selector)` is on the short-delay list.
    /// @param target Contract address.
    /// @param selector Function selector.
    /// @custom:spec REQ-ACCESS-141
    function isShortDelaySelector(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Whether `(target, selector)` is in the immutable `SHORT_ELIGIBLE` set, the only pairs the short-delay
    /// list may ever hold.
    /// @dev The constructor fixes the set equal to the launch short-delay list, each pair with its target's deployed
    /// address on the chain. ParameterStore: every tighten-only setter, namely `tightenHardHealthFloor`,
    /// `tightenSlippageAllowanceBps`, `tightenFloorRoundingAllowance`, `tightenBorrowPriceMaxAge`,
    /// `tightenConsistencyToleranceBps`, `tightenFeedAgreementToleranceBps`, `tightenPoolRiskFactor`,
    /// `tightenRouteDepthThreshold`, `tightenMarketUsdCap`, `tightenTopUpSliceUsd`, `tightenTokenUsdCap`,
    /// `tightenDepositorUsdCap`, `tightenPoolShareMaxBps`, `tightenPoolShareMaxBpsOf`, `tightenMinPledgeUsd`,
    /// `tightenBreakerDeficitMax`, `tightenGateRecoverySeconds`, `tightenMaxShortfallBps`, `tightenDebtStressRiseBps` and `tightenMaxFlashFeeBps`. MarketRegistry: `disableRoute`,
    /// `restoreRoute`, `setMarketOffboarding`, `activateMarket`, `cancelRegistration`, `freeze`,
    /// `pause`, `freezeAddress`, `tripMarketBreaker`, `tripDebtBreaker` and `useStandbyRoute`. LPVaultSwap:
    /// `removeKeeper`. It never holds the timelock as target, or a role, upgrade, flash-source, deployment-operation or
    /// initializer selector.
    /// @param target Contract address.
    /// @param selector Function selector.
    /// @custom:spec REQ-ACCESS-142, REQ-ACCESS-155, Q-398, Q-399
    function isShortEligible(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Whether `(target, selector)` is in the immutable DAO-only cancel set (MarketRegistry `restoreRoute`,
    /// `useStandbyRoute`, `unfreezeAddress`; LPVaultSwap `addKeeper`).
    /// @param target Contract address.
    /// @param selector Function selector.
    /// @custom:spec REQ-ACCESS-156, SPEC-GOV-005
    function isDaoOnlyCancelSelector(
        address target,
        bytes4 selector
    ) external view returns (bool);

    /// @notice Delay an operation with these calls needs: `SHORT_DELAY` when non-empty and every call is short-listed,
    /// otherwise `normalDelay()`.
    /// @dev Reverts `TimelockInvalidOperationLength` when the arrays differ in length. A payload shorter than four
    /// bytes is never short.
    /// @param targets Call targets.
    /// @param payloads Call data.
    /// @return delay Required delay, seconds.
    /// @custom:spec SPEC-GOV-001, REQ-ACCESS-141
    function requiredDelay(
        address[] calldata targets,
        bytes[] calldata payloads
    ) external view returns (uint256 delay);

    /// @notice Whether anyone may execute ready operations.
    /// @dev OpenZeppelin's open role: true exactly when `address(0)` holds `EXECUTOR_ROLE`.
    /// @custom:spec REQ-ACCESS-144
    function publicExecution() external view returns (bool);

    /// @notice Whether a scheduled, not executed operation reached `readyAt + GRACE_PERIOD`.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-013
    function isOperationExpired(
        bytes32 id
    ) external view returns (bool);

    /// @notice Whether every call of the pending operation is `grantRole`, `revokeRole` or `renounceRole`, so it can
    /// be cancelled only by `DAO_CANCELLER_ROLE`; a batch mixing role calls with other calls is cancellable by every
    /// canceller.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-005, REQ-ACCESS-143
    function isRoleChangeOperation(
        bytes32 id
    ) external view returns (bool);

    /// @notice Whether every call of the pending operation is in the DAO-only cancel set, so it can be cancelled only by `DAO_CANCELLER_ROLE`; a batch mixing
    /// such calls with any other call is cancellable by every canceller.
    /// @param id Operation identifier.
    /// @custom:spec SPEC-GOV-005, REQ-ACCESS-156
    function isRestoringOperation(
        bytes32 id
    ) external view returns (bool);
}
