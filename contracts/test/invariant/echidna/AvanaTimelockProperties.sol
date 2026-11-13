// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTimelock} from "../../../src/governance/timelock/AvanaTimelock.sol";
import {IAvanaTimelockGovernance} from "../../../src/governance/timelock/IAvanaTimelockGovernance.sol";
import {GovernedTargets} from "../../../src/governance/timelock/types/GovernedTargets.sol";
import {ILPVaultSwapAdmin} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IMarketRegistryRoutes} from "../../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {TimelockLaunchLists} from "../../utils/fixtures/TimelockLaunchLists.sol";
import {CallRecorder} from "../../utils/mocks/CallRecorder.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The Aave governance executor stand-in: proposer, canceller and the only DAO canceller.
contract TimelockDaoActor {
    function cancel(
        AvanaTimelock tl,
        bytes32 id
    ) external {
        tl.cancel(id);
    }
}

/// @title AvanaTimelockProperties
/// @notice Echidna and Medusa properties of the AvanaTimelock (2.15). The harness is the governance multisig
/// (proposer, executor, canceller); `TimelockDaoActor` is the Aave governance executor. Between transactions the
/// normal delay stays inside its bounds, the minimum delay is the short delay, the timelock is its own only admin,
/// the short list stays inside `SHORT_ELIGIBLE`, and public execution equals the open executor role. Inside a
/// transaction a schedule meets its required delay, an execution happens only inside its window, and a role-change or
/// restoring operation is cancelled only by the DAO canceller.
/// @dev Assertion entry points: `scheduleKind`, `executeAt`, `cancelAt`, `cleanupAt`; time moves through the
/// fuzzers' block-timestamp delay (up to 14 days per call).
contract AvanaTimelockProperties {
    AvanaTimelock internal immutable TL;
    TimelockDaoActor internal immutable DAO;
    CallRecorder internal immutable PS;
    CallRecorder internal immutable MR;
    CallRecorder internal immutable SWAP;
    CallRecorder internal immutable OTHER;

    struct Op {
        address target;
        bytes data;
        bytes32 salt;
    }

    Op[] internal ops;

    constructor() {
        PS = new CallRecorder();
        MR = new CallRecorder();
        SWAP = new CallRecorder();
        OTHER = new CallRecorder();
        DAO = new TimelockDaoActor();
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (address(this), address(DAO));
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        address[] memory dao = new address[](1);
        dao[0] = address(DAO);
        TL = new AvanaTimelock(
            proposers,
            executors,
            new address[](0),
            dao,
            432_000,
            true,
            TimelockLaunchLists.shortEligible(address(PS), address(MR), address(SWAP)),
            TimelockLaunchLists.daoOnlyCancel(address(MR), address(SWAP)),
            GovernedTargets(address(PS), address(MR), address(SWAP))
        );
    }

    // ─── Properties ───

    function property_normalDelayInBounds() external view returns (bool) {
        uint256 d = TL.normalDelay();
        return d >= TL.MIN_NORMAL_DELAY() && d <= TL.MAX_DELAY();
    }

    function property_minDelayIsShort() external view returns (bool) {
        return TL.getMinDelay() == TL.SHORT_DELAY();
    }

    function property_selfOnlyAdmin() external view returns (bool) {
        bytes32 admin = TL.DEFAULT_ADMIN_ROLE();
        return TL.hasRole(admin, address(TL)) && !TL.hasRole(admin, address(this)) && !TL.hasRole(admin, address(DAO));
    }

    function property_shortListWithinEligible() external view returns (bool) {
        bytes4 s = IParameterStoreTighten.tightenMarketUsdCap.selector;
        bytes4 loosen = bytes4(keccak256("loosenTopUpSliceUsd(uint256,uint256)"));
        return (!TL.isShortDelaySelector(address(PS), s) || TL.isShortEligible(address(PS), s))
            && !TL.isShortDelaySelector(address(PS), loosen) && !TL.isShortDelaySelector(address(TL), s);
    }

    function property_publicExecutionIsOpenRole() external view returns (bool) {
        return TL.publicExecution() == TL.hasRole(TL.EXECUTOR_ROLE(), address(0));
    }

    // ─── Assertion entry points ───

    /// @notice Schedules one of eight call shapes at a chosen delay; a success always meets the required delay.
    function scheduleKind(
        uint8 kind,
        uint8 delayChoice,
        uint256 saltSeed
    ) external {
        (address target, bytes memory data) = _call(kind % 8);
        uint256 required = _requiredOne(target, data);
        uint256 delay = delayChoice % 3 == 0 ? TL.SHORT_DELAY() : (delayChoice % 3 == 1 ? TL.normalDelay() : 0);
        bytes32 salt = keccak256(abi.encode(saltSeed, ops.length));
        try TL.schedule(target, 0, data, bytes32(0), salt, delay) {
            assert(delay >= required);
            ops.push(Op(target, data, salt));
        } catch {}
    }

    /// @notice Executes a scheduled operation; a success is always inside `[readyAt, readyAt + GRACE_PERIOD)`.
    function executeAt(
        uint256 i
    ) external {
        if (ops.length == 0) return;
        Op memory op = ops[i % ops.length];
        uint256 readyAt = TL.getTimestamp(TL.hashOperation(op.target, 0, op.data, bytes32(0), op.salt));
        try TL.execute(op.target, 0, op.data, bytes32(0), op.salt) {
            assert(readyAt > 1 && block.timestamp >= readyAt && block.timestamp < readyAt + TL.GRACE_PERIOD());
        } catch {}
    }

    /// @notice Cancels as the multisig or as the DAO; the multisig never cancels a role-change or restoring operation.
    function cancelAt(
        uint256 i,
        bool viaDao
    ) external {
        if (ops.length == 0) return;
        Op memory op = ops[i % ops.length];
        bytes32 id = TL.hashOperation(op.target, 0, op.data, bytes32(0), op.salt);
        bool restricted = TL.isRoleChangeOperation(id) || TL.isRestoringOperation(id);
        if (viaDao) {
            try DAO.cancel(TL, id) {} catch {}
        } else {
            try TL.cancel(id) {
                assert(!restricted);
            } catch {}
        }
    }

    /// @notice Cleans up an operation; a success leaves it unset.
    function cleanupAt(
        uint256 i
    ) external {
        if (ops.length == 0) return;
        Op memory op = ops[i % ops.length];
        bytes32 id = TL.hashOperation(op.target, 0, op.data, bytes32(0), op.salt);
        try TL.cleanupExpiredOperation(id) {
            assert(TL.getTimestamp(id) == 0 && !TL.isRoleChangeOperation(id) && !TL.isRestoringOperation(id));
        } catch {}
    }

    // ─── Call shapes ───

    function _call(
        uint8 kind
    ) internal view returns (address, bytes memory) {
        if (kind == 0) return (address(PS), abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (1, 11e8)));
        if (kind == 1) return (address(OTHER), abi.encodeWithSignature("setFeeRecipient(address)", address(1)));
        if (kind == 2) return (address(OTHER), abi.encodeCall(IAccessControl.grantRole, (keccak256("R"), address(2))));
        if (kind == 3) return (address(MR), abi.encodeWithSelector(IMarketRegistryRoutes.restoreRoute.selector, 7));
        if (kind == 4) {
            return (address(SWAP), abi.encodeWithSelector(ILPVaultSwapAdmin.addKeeper.selector, address(3)));
        }
        if (kind == 5) {
            return (address(TL), abi.encodeCall(IAvanaTimelockGovernance.setNormalDelay, (TL.MIN_NORMAL_DELAY())));
        }
        if (kind == 6) return (address(TL), abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (false)));
        return (address(MR), abi.encodeWithSelector(IMarketRegistryRoutes.disableRoute.selector, 7));
    }

    function _requiredOne(
        address target,
        bytes memory data
    ) internal view returns (uint256) {
        address[] memory t = new address[](1);
        bytes[] memory p = new bytes[](1);
        (t[0], p[0]) = (target, data);
        return TL.requiredDelay(t, p);
    }
}
