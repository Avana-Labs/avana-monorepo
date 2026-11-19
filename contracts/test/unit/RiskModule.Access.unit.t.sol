// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {LegacyRiskModule} from "../../src/legacy/risk-module/LegacyRiskModule.sol";
import {RiskModuleBorrowLogic} from "../../src/legacy/risk-module/RiskModuleBorrowLogic.sol";
import {RiskModuleBreakerLogic} from "../../src/legacy/risk-module/RiskModuleBreakerLogic.sol";
import {RiskModulePledgeLogic} from "../../src/legacy/risk-module/RiskModulePledgeLogic.sol";
import {RiskModuleStatusLogic} from "../../src/legacy/risk-module/RiskModuleStatusLogic.sol";
import {RiskModuleImmutables, RiskModuleLogics} from "../../src/legacy/risk-module/types/RiskModuleTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @title RiskModuleAccessUnitTest
/// @notice Access, initialization, upgrades, implementation immutables and the logic-contract identity checks.
contract RiskModuleAccessUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-242 verifies: REQ-RISK-072, REQ-RISK-002, REQ-ACCESS-153, INV-084, REQ-ACCESS-002, REQ-ACCESS-014, REQ-ACCESS-032
    function test_TEST_242_authorityIsTheAccessManager() public view {
        assertEq(riskModule.authority(), address(accessManager));
        assertEq(
            accessManager.getTargetFunctionRole(address(riskModule), riskModule.upgradeToAndCall.selector),
            AvanaRoles.GOVERNANCE_ROLE
        );
    }

    // TEST-242 verifies: REQ-RISK-002, REQ-RISK-054, PROP-034, REQ-ACCESS-015, REQ-ACCESS-031
    function test_TEST_242_upgradeNeedsTheGovernanceRole() public {
        LegacyRiskModule next = new LegacyRiskModule(rmIm, rmLogics);
        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, other));
        riskModule.upgradeToAndCall(address(next), "");
        vm.prank(governor);
        riskModule.upgradeToAndCall(address(next), "");
        assertEq(riskModule.authority(), address(accessManager));
    }

    // TEST-242 verifies: REQ-RISK-002, Q-226, REQ-ACCESS-150
    function test_TEST_242_initializeOnce() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        riskModule.initialize(address(accessManager));
        LegacyRiskModule impl = new LegacyRiskModule(rmIm, rmLogics);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(accessManager));
    }

    // TEST-062 verifies: REQ-RISK-002
    function test_TEST_062_constructorChecksLogicIdentity() public {
        RiskModuleLogics memory l = rmLogics;
        (l.drift, l.breaker) = (rmLogics.breaker, rmLogics.drift);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, rmLogics.breaker));
        new LegacyRiskModule(rmIm, l);
        // A logic contract built with other immutables is refused.
        l = _deployRiskLogics(rmIm);
        rmIm.adapter = makeAddr("otherAdapter");
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.InvalidLogic.selector, l.drift));
        new LegacyRiskModule(rmIm, l);
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
        assertEq(riskModule.authority(), address(accessManager));
        assertEq(riskModule.rescueHealthFactor(), 1.1e18);
        assertEq(riskModule.RESCUE_MIN_PLEDGE_USD(), 10e8);
    }

    // TEST-035 verifies: REQ-RISK-003, REQ-RISK-039, REQ-RISK-054, REQ-ACCESS-035, REQ-ACCESS-022, REQ-ACCESS-113, REQ-RISK-035, REQ-RISK-037
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
