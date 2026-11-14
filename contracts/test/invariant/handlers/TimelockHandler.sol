// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {AvanaTimelock} from "../../../src/governance/timelock/AvanaTimelock.sol";
import {IAvanaTimelockGovernance} from "../../../src/governance/timelock/IAvanaTimelockGovernance.sol";
import {ILPVaultSwapAdmin} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IMarketRegistryRoutes} from "../../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title TimelockHandler
/// @notice Actor handler of the TEST-212 suite: proposers schedule short, normal, mixed, role-change, restoring and
/// self-configuration operations at random delays; cancellers and strangers cancel; anyone executes; anyone cleans
/// up; time moves 1 hour to 20 days. Ghosts record every success so the invariants can check timing and rights.
contract TimelockHandler is CommonBase, StdUtils {
    /// @notice A call that found nothing to act on, or that the contract refused: reverting keeps it out of the
    /// campaign's success count, so the metrics show the calls that did real work.
    error Skipped();

    AvanaTimelock public immutable TL;
    address public immutable PS;
    address public immutable MR;
    address public immutable SWAP;
    address public immutable OTHER;
    address[4] internal cancellers;
    address internal dao;
    address[2] internal proposers;

    struct Op {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 salt;
        uint256 scheduledAt;
        uint256 delay;
        uint256 required;
    }

    Op[] internal ops;
    bytes32[] public ids;

    // Ghosts
    uint256 public executedEarly;
    uint256 public executedExpired;
    uint256 public scheduledBelowRequired;
    uint256 public roleChangeCancelledByNonDao;
    uint256 public restoringCancelledByNonDao;
    uint256 public cancelledByNonCanceller;
    uint256 public executions;
    uint256 public cancels;

    constructor(
        AvanaTimelock tl,
        address ps,
        address mr,
        address swap,
        address other,
        address[2] memory proposers_,
        address[4] memory cancellers_,
        address dao_
    ) {
        (TL, PS, MR, SWAP, OTHER) = (tl, ps, mr, swap, other);
        proposers = proposers_;
        cancellers = cancellers_;
        dao = dao_;
    }

    function opCount() external view returns (uint256) {
        return ids.length;
    }

    // ─── Actions ───

    function schedule(
        uint8 kind,
        uint8 proposerIdx,
        uint256 delaySeed,
        uint256 saltSeed
    ) external {
        (address[] memory t, bytes[] memory p) = _calls(kind % 13);
        uint256[] memory v = new uint256[](t.length);
        bytes32 salt = keccak256(abi.encode(saltSeed, ids.length));
        uint256 required = TL.requiredDelay(t, p);
        // Mostly valid delays, so operations get scheduled; one in six is an arbitrary delay that may be too short.
        uint256[6] memory choices =
            [required, required, TL.normalDelay(), TL.normalDelay(), TL.SHORT_DELAY(), bound(delaySeed, 0, 40 days)];
        uint256 delay = choices[delaySeed % 6];
        vm.prank(proposers[proposerIdx % 2]);
        try TL.scheduleBatch(t, v, p, bytes32(0), salt, delay) {
            if (delay < required) ++scheduledBelowRequired;
            ops.push(Op(t, v, p, salt, block.timestamp, delay, required));
            ids.push(TL.hashOperationBatch(t, v, p, bytes32(0), salt));
        } catch {
            revert Skipped();
        }
    }

    function execute(
        uint256 idx,
        address caller,
        bool jumpToReady
    ) external {
        if (ops.length == 0) revert Skipped();
        // Half the time, move to the operation's ready time first, so executions are reached.
        uint256 at = TL.getTimestamp(ids[idx % ops.length]);
        if (jumpToReady && at > block.timestamp) vm.warp(at);
        Op storage op = ops[idx % ops.length];
        uint256 readyAt = TL.getTimestamp(ids[idx % ops.length]);
        vm.prank(caller);
        try TL.executeBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt) {
            ++executions;
            if (block.timestamp < readyAt) ++executedEarly;
            if (block.timestamp >= readyAt + TL.GRACE_PERIOD()) ++executedExpired;
        } catch {
            revert Skipped();
        }
    }

    function cancel(
        uint256 idx,
        uint8 who,
        address stranger
    ) external {
        if (ids.length == 0) revert Skipped();
        bytes32 id = ids[idx % ids.length];
        address caller = who % 5 == 4 ? stranger : cancellers[who % 5];
        bool roleChange = TL.isRoleChangeOperation(id);
        bool restoring = TL.isRestoringOperation(id);
        vm.prank(caller);
        try TL.cancel(id) {
            ++cancels;
            bool isDao = TL.hasRole(AvanaRoles.DAO_CANCELLER_ROLE, caller);
            if (!TL.hasRole(TL.CANCELLER_ROLE(), caller)) ++cancelledByNonCanceller;
            if (roleChange && !isDao) ++roleChangeCancelledByNonDao;
            if (restoring && !isDao) ++restoringCancelledByNonDao;
        } catch {
            revert Skipped();
        }
    }

    function cleanup(
        uint256 idx
    ) external {
        if (ids.length == 0) revert Skipped();
        try TL.cleanupExpiredOperation(ids[idx % ids.length]) {} catch {}
    }

    function warp(
        uint256 seconds_
    ) external {
        vm.warp(block.timestamp + bound(seconds_, 1 hours, 20 days));
    }

    function updateDelay(
        uint256 d
    ) external view {
        // Only the timelock itself may call it: the refusal is the expected outcome.
        try TL.updateDelay(d) {
            revert("updateDelay succeeded");
        } catch {}
    }

    // ─── Call shapes ───

    function _calls(
        uint8 kind
    ) internal view returns (address[] memory t, bytes[] memory p) {
        if (kind == 0) return _pack(PS, abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (1, 11e8)));
        if (kind == 1) return _pack(OTHER, abi.encodeWithSignature("setFeeRecipient(address)", address(1)));
        if (kind == 2) {
            t = new address[](2);
            p = new bytes[](2);
            (t[0], p[0]) = (PS, abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (1, 11e8)));
            (t[1], p[1]) = (OTHER, abi.encodeWithSignature("setFeeRecipient(address)", address(1)));
            return (t, p);
        }
        if (kind == 3) return _pack(OTHER, abi.encodeCall(IAccessControl.grantRole, (keccak256("R"), address(2))));
        if (kind == 4) return _pack(MR, abi.encodeWithSelector(IMarketRegistryRoutes.restoreRoute.selector, 7));
        if (kind == 5) return _pack(SWAP, abi.encodeWithSelector(ILPVaultSwapAdmin.addKeeper.selector, address(3)));
        if (kind == 6) {
            uint256 d = TL.normalDelay() == TL.MAX_DELAY() ? TL.MIN_NORMAL_DELAY() : TL.MAX_DELAY();
            return _pack(address(TL), abi.encodeCall(IAvanaTimelockGovernance.setNormalDelay, (d)));
        }
        if (kind == 7) return _pack(MR, abi.encodeWithSelector(IMarketRegistryRoutes.disableRoute.selector, 7));
        if (kind == 8) {
            return _pack(address(TL), abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (false)));
        }
        if (kind == 9) {
            return _pack(address(TL), abi.encodeCall(IAvanaTimelockGovernance.togglePublicExecution, (true)));
        }
        if (kind == 10) {
            return _pack(address(TL), abi.encodeCall(IAccessControl.revokeRole, (TL.DEFAULT_ADMIN_ROLE(), address(TL))));
        }
        if (kind == 11) {
            return _pack(address(TL), abi.encodeCall(IAccessControl.grantRole, (TL.EXECUTOR_ROLE(), address(0))));
        }
        return _pack(
            address(TL),
            abi.encodeCall(
                IAvanaTimelockGovernance.setShortDelaySelector,
                (PS, IParameterStoreTighten.tightenMinPledgeUsd.selector, false)
            )
        );
    }

    function _pack(
        address target,
        bytes memory data
    ) internal pure returns (address[] memory t, bytes[] memory p) {
        t = new address[](1);
        p = new bytes[](1);
        (t[0], p[0]) = (target, data);
    }
}
