// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {ILPOracleEvents} from "../../src/oracle/lp-oracle/ILPOracleEvents.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {
    LPOracleHarness,
    LPOracleHarnessDeployer,
    LPOracleHarnessListingLogic,
    LPOracleHarnessPokeLogic
} from "../utils/harness/LPOracleHarness.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @notice Roles, upgrades, `setPokeMinGas` and `initialize` of the LPOracle base (2.10 Permissions).
contract LPOracleAccessUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    function _deploy(
        InitParams memory p
    ) internal returns (bool ok, bytes memory ret) {
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        try new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (p))) {
            return (true, "");
        } catch (bytes memory reason) {
            return (false, reason);
        }
    }

    // TEST-242 verifies: REQ-ORACLE-097, REQ-ORACLE-058, REQ-ACCESS-153, Q-259, REQ-ACCESS-002, REQ-ACCESS-014, REQ-ACCESS-032
    // Sources: 5.1 TEST-242, PROP-070
    function test_TEST_242_adminRolesOnlyTimelock() public {
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        bytes32 root = oracle.DEFAULT_ADMIN_ROLE();
        assertTrue(oracle.hasRole(root, tl));
        assertTrue(oracle.hasRole(admin, tl));
        assertEq(oracle.TIMELOCK(), tl);
        vm.prank(tl);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.AdminRoleOnlyTimelock.selector, admin, alice));
        oracle.grantRole(admin, alice);
        vm.prank(tl);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.AdminRoleOnlyTimelock.selector, root, alice));
        oracle.grantRole(root, alice);
        // initialize with another timelock reverts.
        InitParams memory p = _params();
        p.timelock = alice;
        (bool ok, bytes memory ret) = _deploy(p);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(ILPOracleErrors.AdminRoleOnlyTimelock.selector, root, alice));
    }

    // TEST-062 verifies: REQ-ORACLE-038, REQ-ORACLE-078, REQ-ORACLE-062, Q-226, Q-228, REQ-ACCESS-051, REQ-ACCESS-025
    function test_TEST_062_restrictedSelectors() public {
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, admin));
        oracle.setPokeMinGas(POKE_FLOOR + 1);
        vm.prank(tl);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.PokeMinGasOutOfBounds.selector, POKE_FLOOR - 1));
        oracle.setPokeMinGas(POKE_FLOOR - 1);
        vm.prank(tl);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.PokeMinGasOutOfBounds.selector, POKE_CEILING + 1));
        oracle.setPokeMinGas(POKE_CEILING + 1);
        vm.prank(tl);
        vm.expectEmit(address(oracle));
        emit ILPOracleEvents.PokeMinGasUpdated(POKE_FLOOR, 1_000_000);
        oracle.setPokeMinGas(1_000_000);
        assertEq(oracle.pokeMinGas(), 1_000_000);
        LPOracleHarness next = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, admin));
        oracle.upgradeToAndCall(address(next), "");
        vm.prank(tl);
        oracle.upgradeToAndCall(address(next), "");
        assertEq(oracle.latestAnswer(), int256(SEEDED), "state kept across the upgrade");
        // poke is permissionless.
        vm.prank(alice);
        oracle.poke();
    }

    // TEST-062 verifies: REQ-ORACLE-080, REQ-ORACLE-058, REQ-ACCESS-150
    function test_TEST_062_initializersLocked() public {
        InitParams memory p = _params();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(p);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(p);
        assertTrue(address(implementation) != address(oracle));
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        implementation.upgradeToAndCall(address(implementation), "");
    }

    // TEST-062 verifies: REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-076, REQ-ORACLE-047, MKT-019, Q-128
    function test_TEST_062_initializeChecks() public {
        InitParams memory p = _params();
        p.pokeMinGas = POKE_FLOOR - 1;
        (bool ok, bytes memory ret) = _deploy(p);
        assertEq(ret, abi.encodeWithSelector(ILPOracleErrors.PokeMinGasOutOfBounds.selector, POKE_FLOOR - 1));
        p = _params();
        p.isUsdStable = new bool[](3);
        (ok, ret) = _deploy(p);
        assertEq(ret, abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET));
        p = _params();
        p.market = abi.encode(new uint256[](3));
        (ok, ret) = _deploy(p);
        assertEq(ret, abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET), "module refuses");
        p = _params();
        p.config.maxQuoteChangeBps = 0;
        (ok, ret) = _deploy(p);
        assertEq(ret, abi.encodeWithSelector(ILPOracleErrors.ConfigCheckFailed.selector, LPOracleCodes.CHECK_QUOTE_CAP));
        // A configuration whose evaluation is not Live (token B's routes disagree) cannot seed.
        p = _params();
        aB.push(97_000_000, T0);
        (ok, ret) = _deploy(p);
        assertEq(bytes4(ret), ILPOracleErrors.NotLive.selector);
        aB.push(int256(ONE), T0);
        (ok,) = _deploy(_params());
        assertTrue(ok);
    }

    // TEST-062 verifies: REQ-ORACLE-064, REQ-ORACLE-045
    function test_TEST_062_noEthAndCallerIndependent() public {
        (bool ok,) = address(oracle).call{value: 1}("");
        assertFalse(ok, "no receive");
        vm.prank(alice);
        int256 a = oracle.latestAnswer();
        vm.prank(bob);
        assertEq(oracle.latestAnswer(), a);
        assertEq(uint8(oracle.getPriceState().state), uint8(PriceState.Live));
        // A configuration-read failure never reverts a view.
        store.setMode(store.getOracleInputs.selector, ReadMode.Huge);
        assertEq(oracle.latestAnswer(), int256(SEEDED));
    }

    // TEST-062 verifies: REQ-ORACLE-097, REQ-ORACLE-038, SPEC-ORC-023
    /// @notice Every LPOracle contract's constructor refuses a zero timelock or a zero block time (`MarketMismatch(0)`),
    /// and a poke floor of 0 or a ceiling below the floor (`PokeMinGasOutOfBounds(ceiling)`); the launch constants
    /// (timelock `0x7173`, 12-second blocks, floor 900,000, ceiling 3,000,000) deploy.
    function test_TEST_062_constructorRefusesBadChainConstants() public {
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleHarnessPokeLogic(address(0), BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleHarnessPokeLogic(tl, 0, POKE_FLOOR, POKE_CEILING, false);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.PokeMinGasOutOfBounds.selector, POKE_CEILING));
        new LPOracleHarnessPokeLogic(tl, BLOCK_TIME, 0, POKE_CEILING, false);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.PokeMinGasOutOfBounds.selector, POKE_FLOOR - 1));
        new LPOracleHarnessPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_FLOOR - 1, false);
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        assertEq(impl.TIMELOCK(), tl);
    }

    // TEST-062 verifies: REQ-ORACLE-106, REQ-ORACLE-080, REQ-ORACLE-078, Q-240
    function test_TEST_062_logicContractsRunOnlyInTheProxy() public {
        address pokeLogic = oracle.POKE_LOGIC();
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        LPOracleHarnessPokeLogic(pokeLogic).poke();
        address listingLogic = oracle.LISTING_LOGIC();
        InitParams memory p = _params();
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        LPOracleHarnessListingLogic(listingLogic).initializeMarket(p);
        // The views reach the view logic by the implementation's own delegatecall; there is no external entry point
        // that runs arbitrary calldata in a logic contract.
        vm.prank(alice);
        (bool routed,) = address(oracle).call(abi.encodeWithSignature("delegateView(bytes)", bytes("")));
        assertFalse(routed, "no delegateView");
        // A logic contract built for other chain constants is refused by the implementation constructor.
        address viewLogic = oracle.VIEW_LOGIC();
        LPOracleHarnessPokeLogic other =
            new LPOracleHarnessPokeLogic(tl, BLOCK_TIME, POKE_FLOOR + 1, POKE_CEILING, false);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleHarness(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, address(other), listingLogic, viewLogic);
    }
}
