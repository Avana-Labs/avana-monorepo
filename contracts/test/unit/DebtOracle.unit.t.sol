// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {IDebtOracleErrors} from "../../src/oracle/debt-oracle/IDebtOracleErrors.sol";
import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtOracleInitParams} from "../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {TimelockFixture} from "../utils/fixtures/TimelockFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title DebtOracleUnitTest
/// @notice DebtOracle initialization, identity views, the served price by state (`SPEC-ORC-018`), the poke gas guard,
/// and access control (`REQ-ORACLE-097`, `REQ-ORACLE-098`).
contract DebtOracleUnitTest is DebtOracleFixture {
    bytes32 internal constant APP_ADMIN = AvanaRoles.APPLICATION_ADMIN;

    function setUp() public {
        _deployDebtOracle();
    }

    // ─── Initialization ───

    // TEST-062 verifies: REQ-ORACLE-091, REQ-ORACLE-097, REQ-ORACLE-058, REQ-ORACLE-040, Q-238, Q-259
    // Sources: 5.1 TEST-062 (the DebtOracle's role map after initialize: the deployer holds no role)
    function test_TEST_062_initializeSeedsAndGrantsOnlyTimelock() public view {
        assertEq(oracle.ASSET(), usdc);
        assertEq(oracle.MARKET_REGISTRY(), address(reg));
        assertEq(oracle.PARAMETER_STORE(), address(store));
        assertEq(oracle.TIMELOCK(), address(timelock));
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.description(), "USDC / USD");
        assertEq(oracle.pokeMinGas(), MIN_GAS);
        (uint256 price8, uint64 at) = oracle.lastAcceptedPrice();
        assertEq(price8, 99_990_000);
        assertEq(at, T0 - 100);
        assertTrue(oracle.hasRole(bytes32(0), address(timelock)));
        assertTrue(oracle.hasRole(APP_ADMIN, address(timelock)));
        assertFalse(oracle.hasRole(bytes32(0), address(this)));
        assertFalse(oracle.hasRole(APP_ADMIN, address(this)));
        assertEq(_served(), 99_990_000);
        assertEq(uint8(_state()), uint8(PriceState.Live));
    }

    // TEST-062 verifies: REQ-ORACLE-091, REQ-ORACLE-097, REQ-ORACLE-080
    function test_TEST_062_initializeEmitsSeedAndRunsOnce() public {
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtPriceSeeded(99_990_000, uint64(T0 - 100));
        IDebtOracle fresh =
            IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (_params())))));
        DebtOracleInitParams memory p = _params();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.initialize(p);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(p);
    }

    // TEST-242 verifies: REQ-ORACLE-097, REQ-ORACLE-091, Q-259
    function test_TEST_242_initializeRejectsAnotherTimelock() public {
        DebtOracleInitParams memory p = _params();
        p.timelock = alice;
        bytes32 admin = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.AdminRoleOnlyTimelock.selector, admin, alice));
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));
    }

    // TEST-231 verifies: REQ-ORACLE-091, REQ-ORACLE-098, REQ-ORACLE-038
    // Sources: 5.1 TEST-231 (the DebtOracle needs a primary and a backup feed)
    function test_TEST_231_initializeNeedsBothRoutesAndGasBounds() public {
        DebtOracleInitParams memory p = _params();
        p.asset = bob;
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.NotDebtAsset.selector, bob));
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));

        reg.setRoutes(usdc, _route1(address(pUsd)), new address[](0));
        p = _params();
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.NotDebtAsset.selector, usdc));
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));
        reg.setRoutes(usdc, _route1(address(pUsd)), _route2(address(aEth), address(ethUsd)));

        p.pokeMinGas = MIN_GAS - 1;
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.PokeMinGasOutOfBounds.selector, MIN_GAS - 1));
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));
        p.pokeMinGas = 2_000_001;
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.PokeMinGasOutOfBounds.selector, uint32(2_000_001)));
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));
    }

    // TEST-231 verifies: REQ-ORACLE-091, REQ-ORACLE-059, REQ-ORACLE-076
    function test_TEST_231_initializeRequiresAgreeingLiveRoutes() public {
        store.setTolerance(usdc, 10);
        pUsd.push(97_500_000, block.timestamp);
        DebtOracleInitParams memory p = _params();
        vm.expectRevert(
            abi.encodeWithSelector(IDebtOracleErrors.NotLive.selector, uint8(1), uint256(1 << 3 | 1 << 12 | 1 << 19))
        );
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));

        vm.warp(block.timestamp + 100_000);
        vm.expectPartialRevert(IDebtOracleErrors.NotLive.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (p)));
    }

    // TEST-242 verifies: REQ-ORACLE-097, REQ-ORACLE-080
    function test_TEST_242_constructorRejectsZeroTimelock() public {
        bytes memory code = abi.encodePacked(vm.getCode("DebtOracle.sol:DebtOracle"), abi.encode(address(0)));
        vm.expectRevert(
            abi.encodeWithSelector(IDebtOracleErrors.AdminRoleOnlyTimelock.selector, bytes32(0), address(0))
        );
        this.create(code);
    }

    /// @dev External so `vm.expectRevert` sees the constructor's revert data as the revert of one call.
    function create(
        bytes memory code
    ) external returns (address deployed) {
        assembly {
            deployed := create(0, add(code, 32), mload(code))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    // ─── Served price by state (SPEC-ORC-018) ───

    // TEST-230 verifies: REQ-ORACLE-093, SPEC-ORC-018, INV-087, Q-247, Q-248
    // Sources: 5.1 TEST-230 (DebtOracle half), SPEC-ORC-018 examples
    function test_TEST_230_expiredServesStressPriceRoundedUp() public {
        vm.warp(T0 + 88_200);
        assertEq(uint8(_state()), uint8(PriceState.Cached));
        assertEq(_served(), 99_990_000);
        _poke();
        vm.warp(T0 + 88_101 + 3600);
        assertEq(uint8(_state()), uint8(PriceState.Expired));
        assertEq(_served(), 104_989_500);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(v.stressAnswer, 104_989_500);
        assertEq(uint256(v.answer), 104_989_500);
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
        assertEq(v.servedUpdatedAt, T0 - 100);
        assertEq(v.borrowPriceMaxAge, 0);
        assertEq(v.liquidationPriceMaxAge, 0);
        store.setStressRise(usdc, 200);
        assertEq(_served(), 101_989_800);
    }

    /// @notice Review DO-03: a store answering a stress rise above 5,000 bps (65,535 here) is read as 5,000, so the
    /// Expired price stays at `ceil(1.5 x A)` = 149,985,000 for `A` = 99,990,000, not 7.55 x A.
    // TEST-230 verifies: REQ-ORACLE-093, SPEC-ORC-018, INV-087, ATTACK-145
    function test_TEST_230_stressRiseClampedAt5000Bps() public {
        store.setStressRise(usdc, type(uint16).max);
        vm.warp(T0 + 200_000);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(uint256(v.answer), 149_985_000, "ceil(99,990,000 x 15,000 / 10,000)");
        assertEq(v.debtStressRiseBps, 5000);
        assertEq(v.stressAnswer, 149_985_000);
        store.setStressRise(usdc, 5001);
        assertEq(_served(), 149_985_000);
        store.setStressRise(usdc, 5000);
        assertEq(_served(), 149_985_000);
        store.setStressRise(usdc, 4999);
        assertEq(_served(), 149_975_001, "ceil(99,990,000 x 14,999 / 10,000)");
    }

    // TEST-230 verifies: REQ-ORACLE-093, SPEC-ORC-018, INV-087
    function test_TEST_230_stressRoundsUpFromAnOddAcceptedPrice() public {
        vm.warp(T0 + 10);
        pUsd.push(99_987_001, block.timestamp);
        _poke();
        assertEq(_accepted(), 99_987_001);
        vm.warp(block.timestamp + 200_000);
        assertEq(uint8(_state()), uint8(PriceState.Expired));
        assertEq(_served(), 104_986_352);
    }

    // TEST-230 verifies: REQ-ORACLE-093, SPEC-ORC-018, REQ-ORACLE-086, INV-087, Q-247
    function test_TEST_230_disagreementServesMaxOfRoutesAndAccepted() public {
        vm.warp(T0 + 10);
        pUsd.push(99_995_000, block.timestamp);
        _poke();
        assertEq(_accepted(), 99_995_000);
        store.setTolerance(usdc, 25);
        vm.warp(T0 + 20);
        pUsd.push(99_990_000, block.timestamp);
        aEth.push(334_333_333_333_334, block.timestamp);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertEq(v.primaryValue, 99_990_000);
        assertEq(v.alternateValue, 100_300_000);
        assertEq(_served(), 100_300_000);
        assertTrue(v.liquidationPaused);
        assertFalse(v.borrowAllowed);
        assertTrue(v.reasons & (1 << 3) != 0);
        // Both routes below the accepted price: the accepted price is served.
        aEth.push(333_200_000_000_000, block.timestamp);
        pUsd.push(99_950_000, block.timestamp);
        store.setTolerance(usdc, 1);
        assertEq(_served(), 99_995_000);
    }

    // TEST-230 verifies: REQ-ORACLE-093, SPEC-ORC-018, INV-087
    function test_TEST_230_cachedKeepsAcceptedPrice() public {
        vm.warp(T0 + 10);
        pUsd.setMode(pUsd.latestRoundData.selector, MockAggregator.Mode.Revert);
        aEth.setMode(aEth.latestRoundData.selector, MockAggregator.Mode.Revert);
        assertEq(uint8(_state()), uint8(PriceState.Cached));
        assertEq(_served(), 99_990_000);
        (,,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, T0 - 100);
    }

    // TEST-230 verifies: REQ-ORACLE-093, REQ-ORACLE-041, REQ-ORACLE-021
    function test_TEST_230_latestRoundDataCarriesTheSourceTimestamp() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.latestRoundData();
        assertEq(answer, 99_990_000);
        assertEq(updatedAt, T0 - 100);
        assertEq(startedAt, T0 - 100);
        assertEq(roundId, uint80(T0 - 100));
        assertEq(answeredInRound, roundId);
    }

    // ─── poke gas guard ───

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-074, REQ-ORACLE-092, REQ-ORACLE-102
    // Sources: 5.1 TEST-042 (the DebtOracle's poke gas guard)
    function test_TEST_042_pokeBelowMinimumGasReverts() public {
        vm.warp(T0 + 100_000);
        vm.expectPartialRevert(IDebtOracleErrors.InsufficientGas.selector);
        oracle.poke{gas: MIN_GAS - 50_000}();
        // Nothing was stored: the next full poke records the failure for the first time.
        vm.expectEmit(false, false, false, false);
        emit IDebtOracleEvents.DebtFailureRecorded(0, 0);
        _poke();
    }

    // ─── Access control ───

    // TEST-242 verifies: REQ-ORACLE-097, REQ-ORACLE-091, Q-259
    // Sources: 5.1 TEST-242
    function test_TEST_242_adminRolesOnlyForTheTimelock() public {
        bytes32 admin = bytes32(0);
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.AdminRoleOnlyTimelock.selector, APP_ADMIN, alice));
        oracle.grantRole(APP_ADMIN, alice);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.AdminRoleOnlyTimelock.selector, admin, alice));
        oracle.grantRole(admin, alice);
        oracle.grantRole(APP_ADMIN, address(timelock));
        vm.stopPrank();
        assertFalse(oracle.hasRole(APP_ADMIN, alice));
    }

    // TEST-242 verifies: REQ-ORACLE-097, Q-259
    function test_TEST_242_adminGrantThroughTimelockReverts() public {
        TimelockFixture.Call[] memory calls =
            _one(address(oracle), abi.encodeCall(IAccessControl.grantRole, (APP_ADMIN, alice)));
        uint256 delay = _required(calls);
        _schedule(governanceMultisig, calls, delay, bytes32("grant"));
        vm.warp(block.timestamp + delay);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.AdminRoleOnlyTimelock.selector, APP_ADMIN, alice));
        _execute(attacker, calls, bytes32("grant"));
    }

    // TEST-062 verifies: REQ-ORACLE-098, REQ-ORACLE-038, REQ-ORACLE-091, Q-226, Q-228
    // Sources: 5.1 TEST-062 (the DebtOracle's restricted selectors)
    function test_TEST_062_setPokeMinGasOnlyApplicationAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        vm.prank(alice);
        oracle.setPokeMinGas(700_000);

        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.PokeMinGasOutOfBounds.selector, MIN_GAS - 1));
        oracle.setPokeMinGas(MIN_GAS - 1);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.PokeMinGasOutOfBounds.selector, uint32(2_000_001)));
        oracle.setPokeMinGas(2_000_001);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.PokeMinGasUpdated(MIN_GAS, 2_000_000);
        oracle.setPokeMinGas(2_000_000);
        vm.stopPrank();
        assertEq(oracle.pokeMinGas(), 2_000_000);
    }

    // TEST-062 verifies: REQ-ORACLE-098, REQ-ORACLE-038
    function test_TEST_062_setPokeMinGasThroughTimelock() public {
        _run(_one(address(oracle), abi.encodeCall(IDebtOracle.setPokeMinGas, (800_000))), bytes32("gas"));
        assertEq(oracle.pokeMinGas(), 800_000);
    }

    // TEST-062 verifies: REQ-ORACLE-091, REQ-ORACLE-078, REQ-ORACLE-080, REQ-ORACLE-081, Q-226
    function test_TEST_062_upgradeOnlyApplicationAdmin() public {
        IDebtOracle next = _newImplementation(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        vm.prank(alice);
        UUPSUpgradeable(address(oracle)).upgradeToAndCall(address(next), "");
        vm.prank(address(timelock));
        UUPSUpgradeable(address(oracle)).upgradeToAndCall(address(next), "");
        // State is kept across the upgrade and the price is still served.
        assertEq(_accepted(), 99_990_000);
        assertEq(oracle.decimals(), 8);
        assertGe(oracle.latestAnswer(), 1);
    }

    // TEST-062 verifies: REQ-ORACLE-098, REQ-ORACLE-064, REQ-ORACLE-062
    function test_TEST_062_noEtherAndNoPriceSetter() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(oracle).call{value: 1}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(oracle).call(abi.encodeWithSignature("setAcceptedPrice(uint256)", 1));
        assertFalse(ok);
    }

    // TEST-062 verifies: REQ-ORACLE-098, REQ-ORACLE-045
    function test_TEST_062_viewsIdenticalForEveryCaller() public {
        vm.prank(alice);
        DebtPriceView memory a = oracle.getPriceState();
        vm.prank(attacker, attacker);
        DebtPriceView memory b = oracle.getPriceState();
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
        assertEq(a.answer, oracle.latestAnswer());
        assertEq(uint8(a.routeUsed), uint8(RouteSlot.Primary));
    }
}
