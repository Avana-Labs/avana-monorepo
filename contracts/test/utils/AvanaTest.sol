// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaRoles} from "../../src/AvanaRoles.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

/// @title AvanaTest
/// @notice Base contract of every Avana Foundry test: the named actors, the fixture values of 5.1 and bound helpers.
/// @dev Values are the defaults of 1.5 Parameters (`docs/spec/01-architecture/05-parameters.md`) and the fixture values
/// listed at the top of 5.1 Test Requirements. A test that needs another value sets it in its own setUp, so a change
/// here moves every suite at once and only through a reviewed edit of this file.
abstract contract AvanaTest is Test {
    // ─── Time (1.5 Governance, Q-228) ───

    /// @notice Execution delay of the tighten role for the governance Safe (12 hours).
    uint256 internal constant SHORT_DELAY = 43_200;
    /// @notice Default governance delay of the governance role (5 days, the top of the 4 to 5 day range).
    uint256 internal constant NORMAL_DELAY = 432_000;
    /// @notice Execution delay of the First-Loss Reserve withdraw role (14 days).
    uint256 internal constant WITHDRAW_DELAY = 1_209_600;

    // ─── Units ───

    /// @notice Aave V4 and AaveOracle prices have 8 decimals.
    uint256 internal constant PRICE_UNIT = 1e8;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;

    // ─── Fixture values (5.1 header, 1.5) ───

    /// @notice `minPledgeUsd` per market: $10 in 8 decimals.
    uint256 internal constant MIN_PLEDGE_USD = 10e8;
    /// @notice Active keepers below which new borrowing halts; Avana's own keeper (Q-400).
    uint256 internal constant KEEPER_FLOOR = 1;
    /// @notice Largest number of approved keepers per chain (Q-316, Q-400).
    uint256 internal constant MAX_KEEPERS = 32;
    /// @notice Largest number of open records per account and market.
    uint256 internal constant MAX_RECORDS_PER_ACCOUNT_MARKET = 16;
    /// @notice Lens recommendation and Avana's guidance for the Spoke's `targetHealthFactor`.
    uint256 internal constant TARGET_HEALTH_FACTOR = 1.1e18;
    /// @notice Flash-fee ceiling of the chain, proposed default.
    uint256 internal constant MAX_FLASH_FEE_BPS = 10;
    /// @notice Avana's share of a liquidation surplus at oracle value.
    uint256 internal constant AVANA_FEE_SHARE_BPS = 2000;
    /// @notice Largest per-leg slippage increase a shortfall top-up buys.
    uint256 internal constant MAX_SHORTFALL_BPS = 1000;
    /// @notice Publication margin added to every feed heartbeat.
    uint256 internal constant HEARTBEAT_MARGIN = 1800;
    /// @notice Ethereum GHO credit line of the Lend Spoke, proposed.
    uint256 internal constant CREDIT_LINE_GHO = 2_000_000e18;
    /// @notice Fixture First-Loss Reserve minimum for GHO (5.1 fixture; the funding ARFC sets the real value).
    uint256 internal constant FIRST_LOSS_RESERVE_MINIMUM_GHO = 100_000e18;
    /// @notice `floorRoundingAllowance` per debt asset: $1 (10^18 for GHO, 10^6 for USDC).
    uint256 internal constant FLOOR_ROUNDING_ALLOWANCE_GHO = 1e18;
    uint256 internal constant FLOOR_ROUNDING_ALLOWANCE_USDC = 1e6;

    // ─── Actors ───

    /// @notice 4-of-7 governance Safe: holds the tighten and governance roles with their execution delays.
    address internal governanceMultisig = makeAddr("governanceMultisig");
    /// @notice 3-of-5 Emergency Guardian: pause and freeze guardian.
    address internal emergencyGuardian = makeAddr("emergencyGuardian");
    /// @notice Aave Protocol Guardian: pause and freeze guardian.
    address internal aaveGuardian = makeAddr("aaveGuardian");
    /// @notice Aave governance executor: the DAO, admin and guardian of every role of Avana's AccessManager.
    address internal aaveGovernanceExecutor = makeAddr("aaveGovernanceExecutor");
    /// @notice Stand-in for the governance Safe where a test is not about delays: holds every Avana role with no
    /// execution delay, so its calls run at once.
    address internal governor = makeAddr("governor");
    /// @notice The Avana AccessManager every suite starts with: the DAO is its admin and the guardian of each role;
    /// `governor` holds each role with no delay, `governanceMultisig` with the delay of the role.
    AccessManager internal accessManager = _newAccessManager();
    /// @notice Aave DAO: admin of the Aave-side AccessManager, configurator admin and proxy admin owner.
    address internal aaveDao = makeAddr("aaveDao");
    /// @notice Aave DAO treasury: supplies the credit lines through the Lend Spoke.
    address internal daoTreasury = makeAddr("daoTreasury");
    /// @notice `COVERAGE_ROLE` holder on each First-Loss Reserve.
    address internal coverageCaller = makeAddr("coverageCaller");
    /// @notice Avana Labs: funds the First-Loss Reserves.
    address internal avanaLabs = makeAddr("avanaLabs");
    /// @notice Treasury Safe receiving Avana's fee share (`feeRecipient`).
    address internal feeRecipient = makeAddr("feeRecipient");
    /// @notice Avana's own keeper.
    address internal keeper = makeAddr("keeper");
    /// @notice Borrowers and third parties.
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    /// @notice An account with no role anywhere.
    address internal attacker = makeAddr("attacker");

    // ─── Access ───

    /// @notice Deploys the Avana AccessManager with the DAO (`aaveGovernanceExecutor`) as admin, labels the Avana roles,
    /// makes the DAO the guardian of each and grants each role to `governor` with no execution delay and to the
    /// governance Safe (`governanceMultisig`) with the delay of the role (12 hours, 5 days, 14 days).
    function _newAccessManager() internal returns (AccessManager manager) {
        // From the artifact, so the manager's creation code is not compiled into every test contract.
        manager = AccessManager(deployCode("AccessManager.sol:AccessManager", abi.encode(aaveGovernanceExecutor)));
        vm.label(address(manager), "AccessManager");
        uint64[] memory ids = AvanaAccess.roles();
        vm.startPrank(aaveGovernanceExecutor);
        for (uint256 i = 0; i < ids.length; ++i) {
            manager.labelRole(ids[i], AvanaAccess.roleLabel(ids[i]));
            manager.setRoleGuardian(ids[i], AvanaRoles.ADMIN_ROLE);
            manager.grantRole(ids[i], governor, 0);
            manager.grantRole(ids[i], governanceMultisig, AvanaAccess.roleDelay(ids[i], NORMAL_DELAY));
        }
        vm.stopPrank();
    }

    /// @notice Schedules `data` on `target` as `caller` at the earliest time the AccessManager allows and returns the
    /// operation id and the time it is ready.
    function _scheduleOp(
        address caller,
        address target,
        bytes memory data
    ) internal returns (bytes32 id, uint256 readyAt) {
        vm.prank(caller);
        accessManager.schedule(target, data, 0);
        id = accessManager.hashOperation(caller, target, data);
        readyAt = accessManager.getSchedule(id);
    }

    /// @notice The execution delay the governance Safe (`governanceMultisig`) needs for a call.
    function _delayOf(
        address target,
        bytes memory data
    ) internal view returns (uint256 delay) {
        (, uint32 d) = accessManager.canCall(governanceMultisig, target, bytes4(data));
        delay = d;
    }

    /// @notice Schedules `data` on `target` as the governance Safe, waits the delay of its role and executes it.
    function _runScheduled(
        address target,
        bytes memory data
    ) internal returns (bytes32 id) {
        uint256 readyAt;
        (id, readyAt) = _scheduleOp(governanceMultisig, target, data);
        vm.warp(readyAt);
        vm.prank(governanceMultisig);
        accessManager.execute(target, data);
    }

    // ─── Helpers ───

    /// @notice `x` bounded to `[minimum, maximum]` in basis points.
    function _boundBps(
        uint256 x,
        uint256 minimum,
        uint256 maximum
    ) internal pure returns (uint256) {
        return bound(x, minimum, maximum);
    }

    /// @notice An address that is neither zero, a precompile, the test contract, a cheatcode address nor a named actor.
    function _boundStranger(
        address candidate
    ) internal view returns (address) {
        if (uint160(candidate) <= 0xff || candidate == address(this) || candidate == address(vm) || _isActor(candidate))
        {
            return address(uint160(uint256(keccak256(abi.encode(candidate, "stranger")))));
        }
        return candidate;
    }

    function _isActor(
        address a
    ) internal view returns (bool) {
        return a == governanceMultisig || a == emergencyGuardian || a == aaveGuardian || a == aaveGovernanceExecutor
            || a == aaveDao || a == daoTreasury || a == coverageCaller || a == avanaLabs || a == feeRecipient
            || a == keeper || a == alice || a == bob || a == carol || a == attacker;
    }
}
