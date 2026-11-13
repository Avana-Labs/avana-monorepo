// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../roles/AvanaRoles.sol";
import {IAvanaTimelock} from "./IAvanaTimelock.sol";
import {IAvanaTimelockGovernance} from "./IAvanaTimelockGovernance.sol";
import {IAvanaTimelockViews} from "./IAvanaTimelockViews.sol";
import {TimelockSelectors} from "./TimelockSelectors.sol";
import {GovernedTargets} from "./types/GovernedTargets.sol";
import {SelectorPair} from "./types/SelectorPair.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title AvanaTimelock
/// @notice The one executor of every privileged change to Avana on its chain: OpenZeppelin 5.1.0
/// `TimelockController` with the delay of each operation read from its calldata (12 hours when every call is on the
/// short-delay list, otherwise the normal delay of 4 to 5 days), a 14-day execution window, public execution, and
/// cancels of role-change and restoring operations reserved to the Aave governance executor.
/// @dev Not upgradeable. Constructor `admin = address(0)`: the timelock is its only `DEFAULT_ADMIN_ROLE` holder for
/// life. Public execution is OpenZeppelin's open role (`EXECUTOR_ROLE` held by `address(0)`). OpenZeppelin keeps its
/// timestamps private, so a cleaned-up operation is hidden through `getTimestamp` until it is scheduled again.
/// @custom:spec REQ-ACCESS-001, REQ-ACCESS-013, REQ-ACCESS-016, REQ-ACCESS-017, REQ-ACCESS-018, REQ-ACCESS-021, REQ-ACCESS-027, REQ-ACCESS-114, REQ-ACCESS-140, SPEC-GOV-001, SPEC-GOV-002, SPEC-GOV-005, SPEC-GOV-007, SPEC-GOV-013, INV-051, INV-068, INV-084, INV-090, Q-228, Q-259, Q-262, Q-263
contract AvanaTimelock is TimelockController, IAvanaTimelock {
    /// @inheritdoc IAvanaTimelockViews
    uint256 public constant override SHORT_DELAY = 43_200;
    /// @inheritdoc IAvanaTimelockViews
    uint256 public constant override MAX_DELAY = 432_000;
    /// @inheritdoc IAvanaTimelockViews
    uint256 public constant override MIN_NORMAL_DELAY = 345_600;
    /// @inheritdoc IAvanaTimelockViews
    uint256 public constant override GRACE_PERIOD = 1_209_600;

    uint256 private _normalDelay;
    mapping(address target => mapping(bytes4 selector => bool)) private _shortEligible;
    mapping(address target => mapping(bytes4 selector => bool)) private _shortDelaySelector;
    mapping(address target => mapping(bytes4 selector => bool)) private _daoCancelSelector;
    mapping(bytes32 id => bool) private _roleChangeOperation;
    mapping(bytes32 id => bool) private _restoringOperation;
    mapping(bytes32 id => bool) private _cleaned;
    /// @dev True only during `togglePublicExecution` or the constructor's grant of the open executor role; cleared in
    /// the same call. A storage bool (not `transient`, which the SMTChecker cannot compile).
    bool private _toggling;

    /// @param proposers `PROPOSER_ROLE` (and, as in OpenZeppelin, `CANCELLER_ROLE`): the governance multisig and the
    /// Aave governance executor.
    /// @param executors `EXECUTOR_ROLE`: the governance multisig.
    /// @param cancellers Further `CANCELLER_ROLE` holders: the Emergency Guardian and the Aave Protocol Guardian.
    /// @param daoCancellers `DAO_CANCELLER_ROLE`: the Aave governance executor.
    /// @param normalDelay_ Launch normal delay, within `[MIN_NORMAL_DELAY, MAX_DELAY]` (432,000).
    /// @param publicExecution_ Whether anyone may execute ready operations (launch `true`).
    /// @param shortEligible The immutable `SHORT_ELIGIBLE` set, also the launch short-delay list.
    /// @param daoOnlyCancel The immutable DAO-only cancel set.
    /// @param targets The chain's deterministic ParameterStore, MarketRegistry and LPVaultSwap addresses: every pair of
    /// either set must name the one its selector belongs to (`REQ-ACCESS-155`, `REQ-ACCESS-156`).
    /// @custom:spec REQ-ACCESS-027, REQ-ACCESS-141, REQ-ACCESS-142, REQ-ACCESS-155, REQ-ACCESS-156, REQ-ACCESS-181, REQ-ACCESS-183
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address[] memory cancellers,
        address[] memory daoCancellers,
        uint256 normalDelay_,
        bool publicExecution_,
        SelectorPair[] memory shortEligible,
        SelectorPair[] memory daoOnlyCancel,
        GovernedTargets memory targets
    )
        TimelockController(
            SHORT_DELAY, _checkedRoleLists(proposers, executors, cancellers, daoCancellers), executors, address(0)
        )
    {
        if (normalDelay_ < MIN_NORMAL_DELAY || normalDelay_ > MAX_DELAY) revert DelayOutOfBounds(normalDelay_);
        _normalDelay = normalDelay_;
        emit NormalDelayChanged(0, normalDelay_);
        // A holder already granted (a proposer listed again as canceller) is not an error, so the "newly granted"
        // flag `_grantRole` returns is not needed here.
        for (uint256 i = 0; i < cancellers.length; ++i) {
            _grantRole(CANCELLER_ROLE, cancellers[i]);
        }
        for (uint256 i = 0; i < daoCancellers.length; ++i) {
            _grantRole(AvanaRoles.DAO_CANCELLER_ROLE, daoCancellers[i]);
        }
        bool daoCanCancel = true;
        for (uint256 i = 0; i < daoCancellers.length; ++i) {
            daoCanCancel = daoCanCancel && hasRole(CANCELLER_ROLE, daoCancellers[i]);
        }
        if (!daoCanCancel) revert InvalidRoleHolders();
        _checkTargets(targets);
        uint256 bad = _firstInvalidShort(shortEligible, targets);
        if (bad < shortEligible.length) {
            revert InvalidShortDelaySelector(shortEligible[bad].target, shortEligible[bad].selector);
        }
        bad = _firstInvalidDao(daoOnlyCancel, targets);
        if (bad < daoOnlyCancel.length) {
            revert InvalidDaoCancelSelector(daoOnlyCancel[bad].target, daoOnlyCancel[bad].selector);
        }
        for (uint256 i = 0; i < shortEligible.length; ++i) {
            (address target, bytes4 selector) = (shortEligible[i].target, shortEligible[i].selector);
            // forge-lint: disable-next-line(costly-loop)
            _shortEligible[target][selector] = true;
            // forge-lint: disable-next-line(costly-loop)
            _shortDelaySelector[target][selector] = true;
            emit ShortDelaySelectorSet(target, selector, true);
        }
        for (uint256 i = 0; i < daoOnlyCancel.length; ++i) {
            // forge-lint: disable-next-line(costly-loop)
            _daoCancelSelector[daoOnlyCancel[i].target][daoOnlyCancel[i].selector] = true;
        }
        _toggling = true;
        if (publicExecution_) _grantRole(EXECUTOR_ROLE, address(0));
        else emit PublicExecutionToggled(false);
        _toggling = false;
    }

    /// @custom:spec REQ-ACCESS-018, REQ-ACCESS-029
    modifier onlySelf() {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        _;
    }

    // ─── Scheduling (SPEC-GOV-001, REQ-ACCESS-117, REQ-ACCESS-143, REQ-ACCESS-156) ───

    /// @notice Queues one call; the delay must meet the call's required delay.
    /// @custom:spec SPEC-GOV-001, SPEC-GOV-002, REQ-ACCESS-117, REQ-ACCESS-141, REQ-ACCESS-143, REQ-ACCESS-156
    function schedule(
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        bytes32 id = hashOperation(target, value, data, predecessor, salt);
        (bool hasSelector, bytes4 selector) = _selectorOf(data);
        uint256 required = hasSelector && _shortDelaySelector[target][selector] ? SHORT_DELAY : _normalDelay;
        _checkSchedulable(id, delay, required);
        super.schedule(target, value, data, predecessor, salt, delay);
        delete _cleaned[id];
        _roleChangeOperation[id] = hasSelector && TimelockSelectors.isRoleSelector(selector);
        _restoringOperation[id] = hasSelector && _daoCancelSelector[target][selector];
    }

    /// @notice Queues a batch; the delay must meet the batch's required delay.
    /// @custom:spec SPEC-GOV-001, SPEC-GOV-002, REQ-ACCESS-117, REQ-ACCESS-141, REQ-ACCESS-143, REQ-ACCESS-156
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) public override onlyRole(PROPOSER_ROLE) {
        if (targets.length != values.length || targets.length != payloads.length) {
            revert TimelockInvalidOperationLength(targets.length, payloads.length, values.length);
        }
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        (uint256 required, bool roleChange, bool restoring) = _classify(targets, payloads);
        _checkSchedulable(id, delay, required);
        super.scheduleBatch(targets, values, payloads, predecessor, salt, delay);
        delete _cleaned[id];
        _roleChangeOperation[id] = roleChange;
        _restoringOperation[id] = restoring;
    }

    // ─── Execution (SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-144) ───

    /// @notice Runs a ready, unexpired call; anyone may while public execution is on.
    /// @custom:spec SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-118, REQ-ACCESS-144
    function execute(
        address target,
        uint256 value,
        bytes calldata payload,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override {
        bytes32 id = hashOperation(target, value, payload, predecessor, salt);
        _checkExecutable(id);
        super.execute(target, value, payload, predecessor, salt);
        _clearMarks(id);
    }

    /// @notice Runs a ready, unexpired batch; anyone may while public execution is on.
    /// @custom:spec SPEC-GOV-002, SPEC-GOV-013, REQ-ACCESS-118, REQ-ACCESS-144
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) public payable override {
        bytes32 id = hashOperationBatch(targets, values, payloads, predecessor, salt);
        _checkExecutable(id);
        super.executeBatch(targets, values, payloads, predecessor, salt);
        _clearMarks(id);
    }

    // ─── Cancel and clean-up (SPEC-GOV-005, SPEC-GOV-007, SPEC-GOV-013) ───

    /// @notice Deletes a pending operation, expired or not; role-change and restoring operations need
    /// `DAO_CANCELLER_ROLE` too.
    /// @custom:spec SPEC-GOV-005, SPEC-GOV-007, REQ-ACCESS-019, REQ-ACCESS-020, REQ-ACCESS-119, REQ-ACCESS-156
    function cancel(
        bytes32 id
    ) public override onlyRole(CANCELLER_ROLE) {
        bool dao = hasRole(AvanaRoles.DAO_CANCELLER_ROLE, msg.sender);
        if (_roleChangeOperation[id] && !dao) revert RoleChangeCancelRestricted(id);
        if (_restoringOperation[id] && !dao) revert RestoringCancelRestricted(id);
        super.cancel(id);
        _clearMarks(id);
    }

    /// @inheritdoc IAvanaTimelockGovernance
    function cleanupExpiredOperation(
        bytes32 id
    ) external override {
        if (!isOperationExpired(id)) revert OperationNotExpired(id);
        _cleaned[id] = true;
        _clearMarks(id);
        emit ExpiredOperationCleaned(id);
    }

    // ─── The timelock's own settings (self-calls) ───

    /// @inheritdoc IAvanaTimelockGovernance
    function setNormalDelay(
        uint256 newDelay
    ) external override onlySelf {
        if (newDelay < MIN_NORMAL_DELAY || newDelay > MAX_DELAY) revert DelayOutOfBounds(newDelay);
        emit NormalDelayChanged(_normalDelay, newDelay);
        _normalDelay = newDelay;
    }

    /// @inheritdoc IAvanaTimelockGovernance
    function setShortDelaySelector(
        address target,
        bytes4 selector,
        bool enabled
    ) external override onlySelf {
        if (enabled && !_shortEligible[target][selector]) revert InvalidShortDelaySelector(target, selector);
        _shortDelaySelector[target][selector] = enabled;
        emit ShortDelaySelectorSet(target, selector, enabled);
    }

    /// @inheritdoc IAvanaTimelockGovernance
    function togglePublicExecution(
        bool enabled
    ) external override onlySelf {
        _toggling = true;
        if (enabled) _grantRole(EXECUTOR_ROLE, address(0));
        else _revokeRole(EXECUTOR_ROLE, address(0));
        _toggling = false;
    }

    /// @notice Disabled: the minimum delay stays `SHORT_DELAY` for life.
    /// @custom:spec REQ-ACCESS-017, REQ-ACCESS-030, REQ-ACCESS-125
    function updateDelay(
        uint256
    ) external pure override {
        revert UpdateDelayDisabled();
    }

    // ─── Views ───

    /// @notice Always `SHORT_DELAY`.
    /// @custom:spec REQ-ACCESS-017, REQ-ACCESS-114
    function getMinDelay() public pure override returns (uint256) {
        return SHORT_DELAY;
    }

    /// @notice OpenZeppelin's timestamp, or 0 for an operation cleaned up and not scheduled again.
    /// @custom:spec SPEC-GOV-002, SPEC-GOV-013
    function getTimestamp(
        bytes32 id
    ) public view override returns (uint256) {
        return _cleaned[id] ? 0 : super.getTimestamp(id);
    }

    /// @inheritdoc IAvanaTimelockViews
    function normalDelay() external view override returns (uint256) {
        return _normalDelay;
    }

    /// @inheritdoc IAvanaTimelockViews
    function isShortDelaySelector(
        address target,
        bytes4 selector
    ) external view override returns (bool) {
        return _shortDelaySelector[target][selector];
    }

    /// @inheritdoc IAvanaTimelockViews
    function isShortEligible(
        address target,
        bytes4 selector
    ) external view override returns (bool) {
        return _shortEligible[target][selector];
    }

    /// @inheritdoc IAvanaTimelockViews
    function isDaoOnlyCancelSelector(
        address target,
        bytes4 selector
    ) external view override returns (bool) {
        return _daoCancelSelector[target][selector];
    }

    /// @inheritdoc IAvanaTimelockViews
    function requiredDelay(
        address[] calldata targets,
        bytes[] calldata payloads
    ) external view override returns (uint256 delay) {
        if (targets.length != payloads.length) {
            revert TimelockInvalidOperationLength(targets.length, payloads.length, 0);
        }
        (delay,,) = _classify(targets, payloads);
    }

    /// @inheritdoc IAvanaTimelockViews
    function publicExecution() public view override returns (bool) {
        return hasRole(EXECUTOR_ROLE, address(0));
    }

    /// @inheritdoc IAvanaTimelockViews
    function isOperationExpired(
        bytes32 id
    ) public view override returns (bool) {
        uint256 readyAt = getTimestamp(id);
        // Subtraction, not readyAt + GRACE_PERIOD: a proposer may pick any delay, so readyAt may be near 2^256.
        return readyAt > _DONE_TIMESTAMP && block.timestamp >= readyAt && block.timestamp - readyAt >= GRACE_PERIOD;
    }

    /// @inheritdoc IAvanaTimelockViews
    function isRoleChangeOperation(
        bytes32 id
    ) external view override returns (bool) {
        return _roleChangeOperation[id];
    }

    /// @inheritdoc IAvanaTimelockViews
    function isRestoringOperation(
        bytes32 id
    ) external view override returns (bool) {
        return _restoringOperation[id];
    }

    // ─── Roles (REQ-ACCESS-153, REQ-ACCESS-144) ───

    /// @dev The timelock's `DEFAULT_ADMIN_ROLE` goes to the timelock only; the open executor role (public execution)
    /// is granted only by `togglePublicExecution` or the constructor.
    /// @custom:spec REQ-ACCESS-153, REQ-ACCESS-168, REQ-ACCESS-144
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        // The constructor's role loops reach these checks; they must revert there too (REQ-ACCESS-153, 144).
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (role == DEFAULT_ADMIN_ROLE && account != address(this)) revert AdminRoleOnlyTimelock(role, account);
        bool open = role == EXECUTOR_ROLE && account == address(0);
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (open && !_toggling) revert PublicExecutionOnlyByToggle();
        granted = super._grantRole(role, account);
        if (granted && open) emit PublicExecutionToggled(true);
    }

    /// @dev The timelock's own admin role is never revoked or renounced; the open executor role is revoked only by
    /// `togglePublicExecution`.
    /// @custom:spec REQ-ACCESS-182, REQ-ACCESS-144
    function _revokeRole(
        bytes32 role,
        address account
    ) internal override returns (bool revoked) {
        if (role == DEFAULT_ADMIN_ROLE && account == address(this)) revert TimelockAdminRequired();
        bool open = role == EXECUTOR_ROLE && account == address(0);
        if (open && !_toggling) revert PublicExecutionOnlyByToggle();
        revoked = super._revokeRole(role, account);
        if (revoked && open) emit PublicExecutionToggled(false);
    }

    // ─── Internal ───

    /// @dev The schedule checks in their specified order, after the proposer role and the array lengths: already
    /// scheduled, below `SHORT_DELAY`, below the required delay.
    function _checkSchedulable(
        bytes32 id,
        uint256 delay,
        uint256 required
    ) private view {
        if (isOperation(id)) revert TimelockUnexpectedOperationState(id, _encodeStateBitmap(OperationState.Unset));
        if (delay < SHORT_DELAY) revert TimelockInsufficientDelay(delay, SHORT_DELAY);
        if (delay < required) revert DelayBelowRequired(delay, required);
    }

    function _checkExecutable(
        bytes32 id
    ) private view {
        if (!publicExecution() && !hasRole(EXECUTOR_ROLE, msg.sender)) revert ExecutionNotPublic(msg.sender);
        if (isOperationExpired(id)) revert OperationExpired(id);
    }

    /// @dev Required delay and the two cancel marks of a batch (SPEC-GOV-001, SPEC-GOV-005): each holds only for a
    /// non-empty batch in which every call qualifies; a payload under four bytes qualifies for none.
    function _classify(
        address[] calldata targets,
        bytes[] calldata payloads
    ) private view returns (uint256 required, bool roleChange, bool restoring) {
        uint256 n = targets.length;
        bool allShort = n > 0;
        roleChange = n > 0;
        restoring = n > 0;
        for (uint256 i = 0; i < n; ++i) {
            (bool hasSelector, bytes4 selector) = _selectorOf(payloads[i]);
            allShort = allShort && hasSelector && _shortDelaySelector[targets[i]][selector];
            roleChange = roleChange && hasSelector && TimelockSelectors.isRoleSelector(selector);
            restoring = restoring && hasSelector && _daoCancelSelector[targets[i]][selector];
        }
        required = allShort ? SHORT_DELAY : _normalDelay;
    }

    /// @dev The constructor's role lists must allow the role table (REQ-ACCESS-183); runs before OpenZeppelin's
    /// constructor grants them, and returns `proposers` for it.
    function _checkedRoleLists(
        address[] memory proposers,
        address[] memory executors,
        address[] memory cancellers,
        address[] memory daoCancellers
    ) private pure returns (address[] memory) {
        if (proposers.length < 2 || daoCancellers.length == 0) revert InvalidRoleHolders();
        if (_hasZero(proposers) || _hasZero(executors) || _hasZero(cancellers) || _hasZero(daoCancellers)) {
            revert InvalidRoleHolders();
        }
        return proposers;
    }

    function _hasZero(
        address[] memory accounts
    ) private pure returns (bool) {
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) return true;
        }
        return false;
    }

    /// @dev Index of the first `SHORT_ELIGIBLE` pair that targets the timelock, names a never-short selector or a
    /// selector outside the launch short-delay list (REQ-ACCESS-142), or a target other than the deployed contract
    /// its selector belongs to (REQ-ACCESS-155), or `pairs.length` when there is none.
    function _firstInvalidShort(
        SelectorPair[] memory pairs,
        GovernedTargets memory targets
    ) private view returns (uint256) {
        for (uint256 i = 0; i < pairs.length; ++i) {
            bytes4 s = pairs[i].selector;
            if (
                pairs[i].target == address(this) || TimelockSelectors.isNeverShort(s)
                    || !TimelockSelectors.isLaunchShortSelector(s) || pairs[i].target != _ownerOf(s, targets)
            ) return i;
        }
        return pairs.length;
    }

    /// @dev Index of the first DAO-only pair that targets the timelock, names a never-short selector or a selector
    /// outside the four of REQ-ACCESS-156 (REQ-ACCESS-181), or a target other than the deployed contract its selector
    /// belongs to (REQ-ACCESS-156), or `pairs.length` when there is none.
    function _firstInvalidDao(
        SelectorPair[] memory pairs,
        GovernedTargets memory targets
    ) private view returns (uint256) {
        for (uint256 i = 0; i < pairs.length; ++i) {
            bytes4 s = pairs[i].selector;
            if (
                pairs[i].target == address(this) || TimelockSelectors.isNeverShort(s)
                    || !TimelockSelectors.isDaoCancelSelector(s) || pairs[i].target != _ownerOf(s, targets)
            ) return i;
        }
        return pairs.length;
    }

    /// @dev `InvalidGovernedTargets` unless the three targets are non-zero, distinct and not the timelock.
    function _checkTargets(
        GovernedTargets memory t
    ) private view {
        if (
            t.parameterStore == address(0) || t.marketRegistry == address(0) || t.lpVaultSwap == address(0)
                || t.parameterStore == t.marketRegistry || t.parameterStore == t.lpVaultSwap
                || t.marketRegistry == t.lpVaultSwap || t.parameterStore == address(this)
                || t.marketRegistry == address(this) || t.lpVaultSwap == address(this)
        ) revert InvalidGovernedTargets();
    }

    /// @dev The deployed contract a short-eligible or DAO-only selector belongs to; `address(0)` for any other.
    function _ownerOf(
        bytes4 selector,
        GovernedTargets memory t
    ) private pure returns (address) {
        uint8 kind = TimelockSelectors.ownerKind(selector);
        if (kind == 1) return t.parameterStore;
        if (kind == 2) return t.marketRegistry;
        if (kind == 3) return t.lpVaultSwap;
        return address(0);
    }

    function _selectorOf(
        bytes calldata payload
    ) private pure returns (bool hasSelector, bytes4 selector) {
        if (payload.length < 4) return (false, bytes4(0));
        return (true, bytes4(payload[:4]));
    }

    function _clearMarks(
        bytes32 id
    ) private {
        delete _roleChangeOperation[id];
        delete _restoringOperation[id];
    }
}
