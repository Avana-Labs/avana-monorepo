// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModule} from "../../src/policy/risk-module/RiskModule.sol";
import {RiskModuleBorrowLogic} from "../../src/policy/risk-module/RiskModuleBorrowLogic.sol";
import {RiskModuleBreakerLogic} from "../../src/policy/risk-module/RiskModuleBreakerLogic.sol";
import {RiskModulePledgeLogic} from "../../src/policy/risk-module/RiskModulePledgeLogic.sol";
import {RiskModuleStatusLogic} from "../../src/policy/risk-module/RiskModuleStatusLogic.sol";
import {RiskModuleImmutables} from "../../src/policy/risk-module/types/RiskModuleImmutables.sol";
import {RiskModuleLogics} from "../../src/policy/risk-module/types/RiskModuleLogics.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title RiskModuleAccessUnitTest
/// @notice Roles, initialization, upgrades, implementation immutables and the logic-contract identity checks.
contract RiskModuleAccessUnitTest is RiskModuleFixture {
    bytes32 internal constant APP = AvanaRoles.APPLICATION_ADMIN;

    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-242 verifies: REQ-RISK-072, REQ-RISK-002, REQ-ACCESS-153, INV-084
    function test_TEST_242_adminRolesOnlyTimelock() public {
        assertTrue(riskModule.hasRole(APP, address(timelock)));
        assertTrue(riskModule.hasRole(0x00, address(timelock)));
        address other = makeAddr("other");
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AdminRoleOnlyTimelock.selector, APP, other));
        riskModule.grantRole(APP, other);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AdminRoleOnlyTimelock.selector, bytes32(0), other));
        riskModule.grantRole(0x00, other);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, 0x00));
        riskModule.grantRole(APP, other);
    }

    // TEST-242 verifies: REQ-RISK-002, REQ-RISK-054, PROP-034
    function test_TEST_242_upgradeNeedsApplicationAdmin() public {
        RiskModule next = new RiskModule(rmIm, rmLogics);
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, APP));
        riskModule.upgradeToAndCall(address(next), "");
        vm.prank(address(timelock));
        riskModule.upgradeToAndCall(address(next), "");
        assertEq(riskModule.TIMELOCK(), address(timelock));
    }

    // TEST-242 verifies: REQ-RISK-002, Q-226
    function test_TEST_242_initializeOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        riskModule.initialize(address(timelock));
        RiskModule impl = new RiskModule(rmIm, rmLogics);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock));
    }

    // TEST-242 verifies: REQ-RISK-072, REQ-RISK-002, REQ-ACCESS-153, Q-226
    function test_TEST_242_initializeOnlyWithTimelock() public {
        RiskModule impl = new RiskModule(rmIm, rmLogics);
        address other = makeAddr("other");
        bytes memory init = abi.encodeCall(RiskModule.initialize, (other));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AdminRoleOnlyTimelock.selector, bytes32(0), other));
        new ERC1967Proxy(address(impl), init);
    }

    // TEST-062 verifies: REQ-RISK-002
    function test_TEST_062_constructorChecksLogicIdentity() public {
        RiskModuleLogics memory l = rmLogics;
        (l.drift, l.breaker) = (rmLogics.breaker, rmLogics.drift);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, rmLogics.breaker));
        new RiskModule(rmIm, l);
        // A logic contract built with other immutables is refused.
        l = _deployRiskLogics(rmIm);
        rmIm.adapter = makeAddr("otherAdapter");
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, l.drift));
        new RiskModule(rmIm, l);
    }

    // TEST-062 verifies: REQ-RISK-002
    function test_TEST_062_logicConstructorsCheckDependencies() public {
        RiskModuleLogics memory l = rmLogics;
        // A zero dependency has no code, so its `logicConfig()` call reverts.
        vm.expectRevert();
        new RiskModuleBreakerLogic(rmIm, address(0));
        vm.expectRevert();
        new RiskModulePledgeLogic(rmIm, l.drift, address(0));
        // A dependency of the wrong kind is refused.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, l.breaker));
        new RiskModuleBreakerLogic(rmIm, l.breaker);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, l.drift));
        new RiskModuleBorrowLogic(rmIm, l.drift, l.drift);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, l.pledge));
        new RiskModuleStatusLogic(rmIm, l.drift, l.breaker, l.pledge);
        // A dependency built with other immutables is refused.
        RiskModuleImmutables memory other = rmIm;
        other.adapter = makeAddr("otherAdapter");
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, l.drift));
        new RiskModulePledgeLogic(other, l.drift, l.breaker);
    }

    // TEST-062 verifies: REQ-RISK-055, REQ-RISK-059, REQ-RISK-067
    function test_TEST_062_immutablesAndConstants() public view {
        assertEq(riskModule.MARKET_REGISTRY(), address(registry));
        assertEq(riskModule.PARAMETER_STORE(), address(store));
        assertEq(riskModule.COLLATERALIZATION(), address(coll));
        assertEq(riskModule.ADAPTER(), address(adapter));
        assertEq(riskModule.LP_VAULT_SWAP(), address(swap));
        assertEq(riskModule.TIMELOCK(), address(timelock));
        assertEq(riskModule.rescueHealthFactor(), 1.1e18);
        assertEq(riskModule.RESCUE_MIN_PLEDGE_USD(), 10e8);
    }

    // TEST-035 verifies: REQ-RISK-003, REQ-RISK-039, REQ-RISK-054
    function test_TEST_035_noFundsNoPauseNoSetter() public {
        (bool ok,) = address(riskModule).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(riskModule).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        (ok,) = address(riskModule).call(abi.encodeWithSignature("freezeMarket(uint256)", mid));
        assertFalse(ok);
        (ok,) = address(riskModule).call(abi.encodeWithSignature("FLASH_SOURCE()"));
        assertFalse(ok);
    }
}
