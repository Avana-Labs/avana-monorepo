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
/// @notice Executor of every privileged change to Avana: an OpenZeppelin `TimelockController` whose delay per
/// operation depends on its calldata, with a 14-day execution window.
/// @dev Not upgradeable; the timelock is its own only `DEFAULT_ADMIN_ROLE` holder.
contract AvanaTimelock is TimelockController, IAvanaTimelock {
    /// @inheritdoc IAvanaTimelockViews
    /// @dev 12 hours, or `TEST_NETWORK_DELAY` on a test network.
    uint256 public immutable override SHORT_DELAY;
    /// @inheritdoc IAvanaTimelockViews
    uint256 public constant override MAX_DELAY = 432_000;
    /// @inheritdoc IAvanaTimelockViews
    /// @dev 4 days, or `TEST_NETWORK_DELAY` on a test network.
    uint256 public immutable override MIN_NORMAL_DELAY;
    /// @inheritdoc IAvanaTimelockViews
    uint256 public constant override GRACE_PERIOD = 1_209_600;
    /// @notice `SHORT_DELAY` and `MIN_NORMAL_DELAY` on a test network or development node.
    uint256 internal constant TEST_NETWORK_DELAY = 60;

    uint256 private _normalDelay;
    mapping(address target => mapping(bytes4 selector => bool)) private _shortEligible;
    mapping(address target => mapping(bytes4 selector => bool)) private _shortDelaySelector;
    mapping(address target => mapping(bytes4 selector => bool)) private _daoCancelSelector;
    mapping(bytes32 id => bool) private _roleChangeOperation;
    mapping(bytes32 id => bool) private _restoringOperation;
    mapping(bytes32 id => bool) private _cleaned;
    /// @dev True only while the open executor role is being granted or revoked.
    bool private _toggling;

    /// @param proposers `PROPOSER_ROLE` holders (also granted `CANCELLER_ROLE`).
    /// @param normalDelay_ Initial normal delay, within `[MIN_NORMAL_DELAY, MAX_DELAY]`.
    /// @param shortEligible The immutable short-eligible set, also the initial short-delay list.
    /// @param daoOnlyCancel The immutable DAO-only cancel set.
    /// @param targets The ParameterStore, MarketRegistry and LPVaultSwap each pair's selector must belong to.
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
            _delayOn(block.chainid, 43_200),
            _checkedRoleLists(proposers, executors, cancellers, daoCancellers),
            executors,
            address(0)
        )
    {
        SHORT_DELAY = _delayOn(block.chainid, 43_200);
        MIN_NORMAL_DELAY = _delayOn(block.chainid, 345_600);
        if (normalDelay_ < MIN_NORMAL_DELAY || normalDelay_ > MAX_DELAY) revert DelayOutOfBounds(normalDelay_);
        _normalDelay = normalDelay_;
        emit NormalDelayChanged(0, normalDelay_);
        // A holder already granted is not an error, so `_grantRole`'s return value is ignored.
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

    modifier onlySelf() {
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        _;
    }

    // ─── Scheduling ───

    /// @notice Queues one call; the delay must meet the call's required delay.
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

    // ─── Execution ───

    /// @notice Runs a ready, unexpired call; anyone may while public execution is on.
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

    // ─── Cancel and clean-up ───

    /// @notice Deletes a pending operation, expired or not; role-change and restoring operations need
    /// `DAO_CANCELLER_ROLE` too.
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
    function updateDelay(
        uint256
    ) external pure override {
        revert UpdateDelayDisabled();
    }

    // ─── Views ───

    /// @notice Always `SHORT_DELAY`.
    function getMinDelay() public view override returns (uint256) {
        return SHORT_DELAY;
    }

    /// @notice OpenZeppelin's timestamp, or 0 for an operation cleaned up and not scheduled again.
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

    // ─── Roles ───

    /// @dev `DEFAULT_ADMIN_ROLE` goes to the timelock only; the open executor role is granted only while toggling.
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        // The constructor's role loops reach these checks and must revert there too.
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (role == DEFAULT_ADMIN_ROLE && account != address(this)) revert AdminRoleOnlyTimelock(role, account);
        bool open = role == EXECUTOR_ROLE && account == address(0);
        // forge-lint: disable-next-line(require-revert-in-loop)
        if (open && !_toggling) revert PublicExecutionOnlyByToggle();
        granted = super._grantRole(role, account);
        if (granted && open) emit PublicExecutionToggled(true);
    }

    /// @dev The timelock's own admin role is never revoked; the open executor role is revoked only while toggling.
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

    /// @dev Each mark holds only if the batch is non-empty and every call qualifies.
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

    /// @dev `production`, or `TEST_NETWORK_DELAY` on a test network or local development node.
    function _delayOn(
        uint256 chainId,
        uint256 production
    ) internal pure returns (uint256) {
        if (chainId == 11_155_111 || chainId == 84_532 || chainId == 31_337 || chainId == 31_338) {
            return TEST_NETWORK_DELAY;
        }
        return production;
    }

    /// @dev Validates the role lists before OpenZeppelin's constructor grants them; returns `proposers`.
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

    /// @dev Index of the first invalid short-eligible pair, or `pairs.length` when there is none.
    function _firstInvalidShort(
        SelectorPair[] memory pairs,
        GovernedTargets memory targets
    ) private view returns (uint256) {
        for (uint256 i = 0; i < pairs.length; ++i) {
            bytes4 s = pairs[i].selector;
            if (
                pairs[i].target == address(this) || TimelockSelectors.isNeverShort(s)
                    || !TimelockSelectors.isShortDelayListSelector(s) || pairs[i].target != _ownerOf(s, targets)
            ) return i;
        }
        return pairs.length;
    }

    /// @dev Index of the first invalid DAO-only pair, or `pairs.length` when there is none.
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
