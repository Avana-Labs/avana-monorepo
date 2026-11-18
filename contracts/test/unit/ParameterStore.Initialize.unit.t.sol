// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {GlobalParams, ParameterStoreLogics} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice `initialize` (REQ-PSTORE-001, REQ-CONFIG-050): every global value at its minimum and maximum accepted
/// and one past each refused with its exact error, the check order, the roles and events it writes, and the
/// ERC-7201 namespace the values land in.
contract ParameterStoreInitializeUnitTest is ParameterStoreFixture {
    ParameterStore internal impl;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreBase.OutOfBounds.selector);

    function setUp() public {
        _deployStore();
        impl = new ParameterStore(address(timelock), address(registry), BLOCK_TIME, logics);
    }

    function _init(
        GlobalParams memory g
    ) internal returns (bool ok, bytes memory err, IParameterStore s) {
        bytes memory data = abi.encodeCall(IParameterStore.initialize, (address(timelock), g));
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
        (bool ok, bytes memory err,) = _init(g);
        assertFalse(ok, "initialize accepted an out-of-bounds value");
        assertEq(err, expected, "wrong initialize error");
    }

    function _accepted(
        GlobalParams memory g
    ) internal returns (IParameterStore s) {
        bool ok;
        (ok,, s) = _init(g);
        assertTrue(ok, "initialize refused an in-bounds value");
    }

    // ─── Each global value at its edges ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-024, REQ-PSTORE-010
    function test_TEST_242_flashFeeAndFeeShareEdges() public {
        GlobalParams memory g = _defaultGlobals();
        g.maxFlashFeeBps = 0;
        assertEq(_accepted(g).maxFlashFeeBps(), 0);
        g.maxFlashFeeBps = 100;
        assertEq(_accepted(g).maxFlashFeeBps(), 100);
        g.maxFlashFeeBps = 101;
        _refused(g, oob);
        g = _defaultGlobals();
        g.avanaFeeShareBps = 0;
        assertEq(_accepted(g).avanaFeeShareBps(), 0);
        g.avanaFeeShareBps = 5000;
        assertEq(_accepted(g).avanaFeeShareBps(), 5000);
        g.avanaFeeShareBps = 5001;
        _refused(g, oob);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-030
    function test_TEST_242_gateRecoveryEdges() public {
        GlobalParams memory g = _defaultGlobals();
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
        GlobalParams memory g = _defaultGlobals();
        g.maxShortfallBps = 0;
        assertEq(_accepted(g).maxShortfallBps(), 0);
        g.maxShortfallBps = 5000;
        assertEq(_accepted(g).maxShortfallBps(), 5000);
        g.maxShortfallBps = 5001;
        _refused(g, oob);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-056
    function test_TEST_242_feeRecipientCheckedAtInitialize() public {
        GlobalParams memory g = _defaultGlobals();
        address[4] memory bad = [address(0), address(timelock), address(registry), address(hub)];
        for (uint256 i = 0; i < bad.length; ++i) {
            g.feeRecipient = bad[i];
            _refused(g, abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, bad[i]));
        }
        g.feeRecipient = bob;
        assertEq(_accepted(g).feeRecipient(), bob);
    }

    // ─── Check order ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-CONFIG-052
    function test_TEST_242_rangeBeforeRecipient() public {
        GlobalParams memory g = _defaultGlobals();
        g.feeRecipient = address(0);
        g.maxShortfallBps = 5001;
        _refused(g, oob);
        g.maxShortfallBps = 1000;
        _refused(g, abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, address(0)));
        // The timelock argument is checked before any value.
        bytes memory data = abi.encodeCall(IParameterStore.initialize, (alice, g));
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.AdminRoleOnlyTimelock.selector, bytes32(0), alice));
        new ERC1967Proxy(address(impl), data);
    }

    // ─── What initialize writes ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-023, REQ-ACCESS-153, REQ-ACCESS-150
    function test_TEST_242_initializeGrantsRolesAndEmits() public {
        bytes memory data = abi.encodeCall(IParameterStore.initialize, (address(timelock), _defaultGlobals()));
        vm.expectEmit();
        emit IAccessControl.RoleGranted(bytes32(0), address(timelock), address(this));
        vm.expectEmit();
        emit IAccessControl.RoleGranted(AvanaRoles.APPLICATION_ADMIN, address(timelock), address(this));
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

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-ACCESS-101
    function test_TEST_242_everyInitialValueReadsBack() public view {
        GlobalParams memory g = _defaultGlobals();
        assertEq(store.maxFlashFeeBps(), g.maxFlashFeeBps);
        assertEq(store.avanaFeeShareBps(), g.avanaFeeShareBps);
        assertEq(store.feeRecipient(), g.feeRecipient);
        assertEq(store.gateRecoverySeconds(), g.gateRecoverySeconds);
        assertEq(store.maxShortfallBps(), g.maxShortfallBps);
        // Fixed constants of the implementation.
        assertEq(store.MAX_HEARTBEAT_MARGIN(), 3600);
        assertEq(store.LOOSEN_CAP_STEP_BPS(), 15_000);
        assertEq(store.LOOSEN_SLIPPAGE_STEP_BPS(), 25);
    }

    // ─── ERC-7201 namespace ───

    // TEST-242 verifies: REQ-PSTORE-001
    function test_TEST_242_valuesLiveInTheNamespacedSlot() public view {
        bytes32 slot =
            keccak256(abi.encode(uint256(keccak256("avana.storage.ParameterStore")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(slot, 0x97d60a1f76524429d85918aee5154ffd84c83f78fddb1d1f3d0a0bfeca081800);
        // GlobalParams opens the layout: the flash fee, the fee share, the recipient and the gate recovery share the
        // first word, then the shortfall bound.
        uint256 w0 = uint256(vm.load(address(store), slot));
        assertEq(uint16(w0), store.maxFlashFeeBps());
        assertEq(uint16(w0 >> 16), store.avanaFeeShareBps());
        assertEq(address(uint160(w0 >> 32)), store.feeRecipient());
        assertEq(uint64(w0 >> 192), store.gateRecoverySeconds());
        assertEq(uint16(uint256(vm.load(address(store), bytes32(uint256(slot) + 1)))), store.maxShortfallBps());
        // Neither the implementation nor any logic contract holds a value of its own.
        assertEq(vm.load(address(implementation), slot), bytes32(0));
        assertEq(vm.load(logics.tighten, slot), bytes32(0));
        assertEq(vm.load(logics.adminRisk, slot), bytes32(0));
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-ACCESS-150, REQ-ACCESS-031
    function test_TEST_242_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock), _defaultGlobals());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(timelock), _defaultGlobals());
        // A second initialize of the live proxy fails the same way, as the timelock too.
        _tl();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        store.initialize(address(timelock), _defaultGlobals());
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-056
    /// @notice `initialize` runs before the MarketRegistry holds code: the registry probes of the fee recipient check
    /// are skipped and the store initializes with the recipient recorded.
    function test_TEST_242_initializeBeforeRegistryHasCode() public {
        address noCode = makeAddr("registryNotYetDeployed");
        address tl = address(timelock);
        ParameterStoreLogics memory l = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(tl, noCode, BLOCK_TIME)),
            loosen: address(new ParameterStoreLoosenLogic(tl, noCode, BLOCK_TIME)),
            listing: address(new ParameterStoreListingLogic(tl, noCode, BLOCK_TIME)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(tl, noCode, BLOCK_TIME)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(tl, noCode, BLOCK_TIME))
        });
        ParameterStore early = new ParameterStore(tl, noCode, BLOCK_TIME, l);
        bytes memory data = abi.encodeCall(IParameterStore.initialize, (tl, _defaultGlobals()));
        IParameterStore s = IParameterStore(address(new ERC1967Proxy(address(early), data)));
        assertEq(s.feeRecipient(), feeRecipient);
    }
}
