// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreChain} from "../../src/policy/parameter-store/IParameterStoreChain.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {GlobalParams} from "../../src/policy/parameter-store/types/GlobalParams.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice `initialize` (REQ-PSTORE-001, REQ-CONFIG-050): every global value at its minimum and maximum accepted
/// and one past each refused with its exact error, the check order, the roles and events it writes, and the
/// ERC-7201 namespace the values land in.
contract ParameterStoreInitializeUnitTest is ParameterStoreFixture {
    ParameterStore internal impl;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);
    bytes internal live = abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector);

    function setUp() public {
        _deployStore(false);
        impl = new ParameterStore(address(timelock), address(registry), BLOCK_TIME, false, logics);
    }

    function _init(
        GlobalParams memory g,
        uint256 depositorCap,
        uint16 poolShare
    ) internal returns (bool ok, bytes memory err, IParameterStore s) {
        bytes memory data =
            abi.encodeCall(IParameterStoreAdmin.initialize, (address(timelock), g, depositorCap, poolShare));
        try new ERC1967Proxy(address(impl), data) returns (ERC1967Proxy p) {
            (ok, s) = (true, IParameterStore(address(p)));
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    function _refused(
        GlobalParams memory g,
        bytes memory expected
    ) internal {
        (bool ok, bytes memory err,) = _init(g, 0, 10_000);
        assertFalse(ok, "initialize accepted an out-of-bounds value");
        assertEq(err, expected, "wrong initialize error");
    }

    function _accepted(
        GlobalParams memory g
    ) internal returns (IParameterStore s) {
        bool ok;
        (ok,, s) = _init(g, 0, 10_000);
        assertTrue(ok, "initialize refused an in-bounds value");
    }

    // ─── Each global value at its edges ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-CONFIG-052
    function test_TEST_242_disagreementPauseAtBothEnds() public {
        GlobalParams memory g = _launchGlobals();
        g.disagreementPauseMax = 0;
        assertEq(_accepted(g).disagreementPauseMax(), 0);
        g.disagreementPauseMax = 1800;
        assertEq(_accepted(g).disagreementPauseMax(), 1800);
        g.disagreementPauseMax = 3600;
        assertEq(_accepted(g).disagreementPauseMax(), 3600);
        g.disagreementPauseMax = 3601;
        _refused(g, live);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-052
    function test_TEST_242_graceDurationAtBothEnds() public {
        GlobalParams memory g = _launchGlobals();
        g.graceDuration = 0;
        assertEq(_accepted(g).graceDuration(), 0);
        g.graceDuration = 7200;
        assertEq(_accepted(g).graceDuration(), 7200);
        g.graceDuration = 7201;
        _refused(g, live);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-052
    function test_TEST_242_graceHealthFactorAtBothEnds() public {
        GlobalParams memory g = _launchGlobals();
        g.graceHealthFactor = 0.9e18;
        assertEq(_accepted(g).graceHealthFactor(), 0.9e18);
        g.graceHealthFactor = 1e18 - 1;
        assertEq(_accepted(g).graceHealthFactor(), 1e18 - 1);
        g.graceHealthFactor = 0.9e18 - 1;
        _refused(g, live);
        g.graceHealthFactor = 1e18;
        _refused(g, live);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-CONFIG-055
    function test_TEST_242_cachedWindowAndBandEdges() public {
        GlobalParams memory g = _launchGlobals();
        g.cachedWindow = 0;
        _refused(g, oob);
        g.cachedWindow = 1;
        assertEq(_accepted(g).cachedWindow(), 1);
        g = _launchGlobals();
        g.usdBandLow = 1e8;
        _refused(g, oob);
        g.usdBandLow = 1e8 - 1;
        assertEq(_accepted(g).usdBandLow(), 1e8 - 1);
        g = _launchGlobals();
        g.usdBandHigh = 1e8;
        _refused(g, oob);
        g.usdBandHigh = 1e8 + 1;
        assertEq(_accepted(g).usdBandHigh(), 1e8 + 1);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-024, REQ-PSTORE-010
    function test_TEST_242_flashFeeAndFeeShareEdges() public {
        GlobalParams memory g = _launchGlobals();
        g.maxFlashFeeBps = 0;
        assertEq(_accepted(g).maxFlashFeeBps(), 0);
        g.maxFlashFeeBps = 100;
        assertEq(_accepted(g).maxFlashFeeBps(), 100);
        g.maxFlashFeeBps = 101;
        _refused(g, oob);
        g = _launchGlobals();
        g.avanaFeeShareBps = 0;
        assertEq(_accepted(g).avanaFeeShareBps(), 0);
        g.avanaFeeShareBps = 5000;
        assertEq(_accepted(g).avanaFeeShareBps(), 5000);
        g.avanaFeeShareBps = 5001;
        _refused(g, oob);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-024, REQ-CONFIG-050
    function test_TEST_242_agreementMarginEdges() public {
        GlobalParams memory g = _launchGlobals();
        g.feedAgreementMarginBps = 0;
        assertEq(_accepted(g).feedAgreementMarginBps(), 0);
        g.feedAgreementMarginBps = 10_000;
        assertEq(_accepted(g).feedAgreementMarginBps(), 10_000);
        g.feedAgreementMarginBps = 10_001;
        _refused(g, oob);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-030
    function test_TEST_242_gateRecoveryEdges() public {
        GlobalParams memory g = _launchGlobals();
        g.gateRecoverySeconds = 600;
        assertEq(_accepted(g).gateRecoverySeconds(), 600);
        g.gateRecoverySeconds = 7200;
        assertEq(_accepted(g).gateRecoverySeconds(), 7200);
        g.gateRecoverySeconds = 599;
        _refused(g, oob);
        g.gateRecoverySeconds = 7201;
        _refused(g, oob);
        g.gateRecoverySeconds = type(uint64).max;
        _refused(g, oob);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-018
    function test_TEST_242_maxShortfallEdges() public {
        GlobalParams memory g = _launchGlobals();
        g.maxShortfallBps = 0;
        assertEq(_accepted(g).maxShortfallBps(), 0);
        g.maxShortfallBps = 5000;
        assertEq(_accepted(g).maxShortfallBps(), 5000);
        g.maxShortfallBps = 5001;
        _refused(g, oob);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-026, REQ-RISK-042, Q-403
    function test_TEST_242_depositorCapAndPoolShareEdges() public {
        GlobalParams memory g = _launchGlobals();
        (bool ok, bytes memory err, IParameterStore s) = _init(g, 1, 10_000);
        assertFalse(ok);
        assertEq(err, oob);
        (ok, err,) = _init(g, type(uint256).max, 10_000);
        assertFalse(ok);
        assertEq(err, oob);
        (ok, err,) = _init(g, 0, 0);
        assertFalse(ok);
        assertEq(err, oob);
        (ok, err,) = _init(g, 0, 10_001);
        assertFalse(ok);
        assertEq(err, oob);
        (ok,, s) = _init(g, 0, 1);
        assertTrue(ok);
        assertEq(s.poolShareMaxBps(), 1);
        (ok,, s) = _init(g, 0, 10_000);
        assertTrue(ok);
        assertEq(s.poolShareMaxBps(), 10_000);
        // No Hub has a depositor cap until its first CDP Spoke's batch writes one.
        assertEq(s.depositorUsdCap(address(hub)), 0);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-056
    function test_TEST_242_feeRecipientCheckedAtInitialize() public {
        GlobalParams memory g = _launchGlobals();
        address[4] memory bad = [address(0), address(timelock), address(registry), address(hub)];
        for (uint256 i = 0; i < bad.length; ++i) {
            g.feeRecipient = bad[i];
            _refused(g, abi.encodeWithSelector(IParameterStoreErrors.InvalidFeeRecipient.selector, bad[i]));
        }
        g.feeRecipient = bob;
        assertEq(_accepted(g).feeRecipient(), bob);
    }

    // ─── Check order ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-CONFIG-052
    function test_TEST_242_livenessBeforeRangeBeforeRecipient() public {
        GlobalParams memory g = _launchGlobals();
        g.cachedWindow = 0;
        g.feeRecipient = address(0);
        g.graceDuration = 7201;
        _refused(g, live);
        g.graceDuration = 1800;
        g.graceHealthFactor = 1e18;
        _refused(g, live);
        g.graceHealthFactor = 0.95e18;
        _refused(g, oob);
        g.cachedWindow = 3600;
        _refused(g, abi.encodeWithSelector(IParameterStoreErrors.InvalidFeeRecipient.selector, address(0)));
        // The timelock argument is checked before any value.
        bytes memory data = abi.encodeCall(IParameterStoreAdmin.initialize, (alice, g, 1, 0));
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.AdminRoleOnlyTimelock.selector, bytes32(0), alice));
        new ERC1967Proxy(address(impl), data);
    }

    // ─── What initialize writes ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-023, REQ-ACCESS-153
    function test_TEST_242_initializeGrantsRolesAndEmits() public {
        bytes memory data =
            abi.encodeCall(IParameterStoreAdmin.initialize, (address(timelock), _launchGlobals(), 0, 10_000));
        vm.expectEmit();
        emit IAccessControl.RoleGranted(bytes32(0), address(timelock), address(this));
        vm.expectEmit();
        emit IAccessControl.RoleGranted(AvanaRoles.APPLICATION_ADMIN, address(timelock), address(this));
        vm.expectEmit();
        emit IParameterStoreChain.SequencerSet(address(0), 0);
        vm.expectEmit();
        emit Initializable.Initialized(1);
        IParameterStore s = IParameterStore(address(new ERC1967Proxy(address(impl), data)));
        assertTrue(s.hasRole(bytes32(0), address(timelock)));
        assertTrue(s.hasRole(AvanaRoles.APPLICATION_ADMIN, address(timelock)));
        assertFalse(s.hasRole(bytes32(0), address(this)));
        assertFalse(s.hasRole(AvanaRoles.APPLICATION_ADMIN, address(this)));
        assertEq(s.getRoleAdmin(AvanaRoles.APPLICATION_PAUSE_GUARDIAN), AvanaRoles.APPLICATION_ADMIN);
        assertEq(s.getRoleAdmin(AvanaRoles.APPLICATION_RISK_STEWARD), AvanaRoles.APPLICATION_ADMIN);
        assertEq(s.TIMELOCK(), address(timelock));
        assertEq(s.MARKET_REGISTRY(), address(registry));
        assertEq(s.CHAIN_BLOCK_TIME(), BLOCK_TIME);
        assertEq(s.coverageRatioBps(), 0);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050
    function test_TEST_242_everyLaunchValueReadsBack() public view {
        GlobalParams memory g = _launchGlobals();
        assertEq(store.cachedWindow(), g.cachedWindow);
        assertEq(store.disagreementPauseMax(), g.disagreementPauseMax);
        assertEq(store.usdBandLow(), g.usdBandLow);
        assertEq(store.usdBandHigh(), g.usdBandHigh);
        assertEq(store.graceDuration(), g.graceDuration);
        assertEq(store.graceHealthFactor(), g.graceHealthFactor);
        assertEq(store.maxFlashFeeBps(), g.maxFlashFeeBps);
        assertEq(store.avanaFeeShareBps(), g.avanaFeeShareBps);
        assertEq(store.feeRecipient(), g.feeRecipient);
        assertEq(store.feedAgreementMarginBps(), g.feedAgreementMarginBps);
        assertEq(store.gateRecoverySeconds(), g.gateRecoverySeconds);
        assertEq(store.maxShortfallBps(), g.maxShortfallBps);
        // Fixed constants of the implementation.
        assertEq(store.graceHealthFactorMin(), 0.9e18);
        assertEq(store.graceDurationMax(), 7200);
        assertEq(store.consistencyToleranceMinBps(), 10);
        assertEq(store.MAX_HEARTBEAT_MARGIN(), 3600);
        assertEq(store.LOOSEN_HEALTH_FACTOR_STEP(), 0.03e18);
        assertEq(store.LOOSEN_CAP_STEP_BPS(), 15_000);
        assertEq(store.LOOSEN_SLIPPAGE_STEP_BPS(), 25);
    }

    // ─── ERC-7201 namespace ───

    // TEST-242 verifies: REQ-PSTORE-001
    function test_TEST_242_valuesLiveInTheNamespacedSlot() public view {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("avana.storage.ParameterStore")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(slot, 0x97d60a1f76524429d85918aee5154ffd84c83f78fddb1d1f3d0a0bfeca081800);
        // GlobalParams opens the layout: cachedWindow and disagreementPauseMax share the first word, then the band.
        uint256 w0 = uint256(vm.load(address(store), slot));
        assertEq(uint32(w0), store.cachedWindow());
        assertEq(uint32(w0 >> 32), store.disagreementPauseMax());
        assertEq(uint256(vm.load(address(store), bytes32(uint256(slot) + 1))), store.usdBandLow());
        assertEq(uint256(vm.load(address(store), bytes32(uint256(slot) + 2))), store.usdBandHigh());
        // Neither the implementation nor any logic contract holds a value of its own.
        assertEq(vm.load(address(implementation), slot), bytes32(0));
        assertEq(vm.load(logics.tighten, slot), bytes32(0));
        assertEq(vm.load(logics.adminRisk, slot), bytes32(0));
    }

    // TEST-242 verifies: REQ-PSTORE-001
    function test_TEST_242_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock), _launchGlobals(), 0, 10_000);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(timelock), _launchGlobals(), 0, 10_000);
        // A second initialize of the live proxy fails the same way, as the timelock too.
        _tl();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        store.initialize(address(timelock), _launchGlobals(), 0, 10_000);
    }
}
