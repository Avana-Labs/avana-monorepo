// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreLogic} from "../../src/policy/parameter-store/IParameterStoreLogic.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {ParameterStoreLogics} from "../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice A contract that runs a logic contract's code against its own storage by delegatecall.
contract ForeignDelegator {
    function run(
        address logic,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        // solhint-disable-next-line avoid-low-level-calls
        (ok, ret) = logic.delegatecall(data);
    }
}

/// @notice The five logic contracts behind the implementation (REQ-PSTORE-001): each reports its kind and the four
/// immutables it was built with, the implementation constructor refuses any slot whose logic differs in one of the
/// five, every logic and implementation refuses a zero timelock, registry or block time, and a logic contract run
/// anywhere but through the store's delegatecall either refuses (`NotDelegated`) or acts only on the caller's own
/// storage.
contract ParameterStoreLogicsUnitTest is ParameterStoreFixture {
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _kinds() internal pure returns (bytes32[5] memory k) {
        k = [
            keccak256("ParameterStoreTightenLogic"),
            keccak256("ParameterStoreLoosenLogic"),
            keccak256("ParameterStoreListingLogic"),
            keccak256("ParameterStoreAdminOracleLogic"),
            keccak256("ParameterStoreAdminRiskLogic")
        ];
    }

    function _asArray(
        ParameterStoreLogics memory l
    ) internal pure returns (address[5] memory a) {
        a = [l.tighten, l.loosen, l.listing, l.adminOracle, l.adminRisk];
    }

    function _fromArray(
        address[5] memory a
    ) internal pure returns (ParameterStoreLogics memory l) {
        l = ParameterStoreLogics(a[0], a[1], a[2], a[3], a[4]);
    }

    /// @dev A logic of kind `i` built with the given immutables.
    function _logic(
        uint256 i,
        address tl,
        address reg,
        uint32 bt,
        bool seq
    ) internal returns (address) {
        if (i == 0) return address(new ParameterStoreTightenLogic(tl, reg, bt, seq));
        if (i == 1) return address(new ParameterStoreLoosenLogic(tl, reg, bt, seq));
        if (i == 2) return address(new ParameterStoreListingLogic(tl, reg, bt, seq));
        if (i == 3) return address(new ParameterStoreAdminOracleLogic(tl, reg, bt, seq));
        return address(new ParameterStoreAdminRiskLogic(tl, reg, bt, seq));
    }

    function _deployImpl(
        ParameterStoreLogics memory l
    ) internal returns (bool ok, bytes memory err) {
        try new ParameterStore(address(timelock), address(registry), BLOCK_TIME, false, l) returns (ParameterStore) {
            ok = true;
        } catch (bytes memory reason) {
            err = reason;
        }
    }

    // TEST-062 verifies: REQ-PSTORE-001
    function test_TEST_062_eachLogicReportsItsKindAndImmutables() public view {
        address[5] memory a = _asArray(logics);
        bytes32[5] memory kinds = _kinds();
        for (uint256 i = 0; i < a.length; ++i) {
            (bytes32 kind, address tl, address reg, uint32 bt, bool seq) = IParameterStoreLogic(a[i]).logicConfig();
            assertEq(kind, kinds[i]);
            assertEq(tl, address(timelock));
            assertEq(reg, address(registry));
            assertEq(bt, BLOCK_TIME);
            assertFalse(seq);
        }
    }

    // TEST-062 verifies: REQ-PSTORE-001
    function test_TEST_062_everySlotNeedsItsOwnKind() public {
        address[5] memory a = _asArray(logics);
        for (uint256 slot = 0; slot < 5; ++slot) {
            for (uint256 other = 0; other < 5; ++other) {
                if (other == slot) continue;
                address[5] memory b = a;
                b[slot] = a[other];
                (bool ok, bytes memory err) = _deployImpl(_fromArray(b));
                assertFalse(ok, "slot accepted another kind");
                assertEq(err, oob);
            }
        }
        (bool fine,) = _deployImpl(logics);
        assertTrue(fine);
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-027, REQ-PSTORE-023
    function test_TEST_062_everySlotNeedsTheSameImmutables() public {
        address otherTl = makeAddr("otherTimelock");
        address otherReg = makeAddr("otherRegistry");
        for (uint256 slot = 0; slot < 5; ++slot) {
            address[4] memory wrong = [
                _logic(slot, otherTl, address(registry), BLOCK_TIME, false),
                _logic(slot, address(timelock), otherReg, BLOCK_TIME, false),
                _logic(slot, address(timelock), address(registry), 2, false),
                _logic(slot, address(timelock), address(registry), BLOCK_TIME, true)
            ];
            for (uint256 j = 0; j < wrong.length; ++j) {
                address[5] memory b = _asArray(logics);
                b[slot] = wrong[j];
                (bool ok, bytes memory err) = _deployImpl(_fromArray(b));
                assertFalse(ok, "slot accepted a logic with other immutables");
                assertEq(err, oob);
            }
        }
    }

    // TEST-062 verifies: REQ-PSTORE-001
    function test_TEST_062_aSlotWithoutALogicIsRefused() public {
        address[5] memory b = _asArray(logics);
        b[2] = makeAddr("noCode");
        (bool ok,) = _deployImpl(_fromArray(b));
        assertFalse(ok);
        b = _asArray(logics);
        b[4] = address(registry);
        (ok,) = _deployImpl(_fromArray(b));
        assertFalse(ok);
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-027
    function test_TEST_062_zeroImmutablesRefused() public {
        address tl = address(timelock);
        address reg = address(registry);
        for (uint256 i = 0; i < 5; ++i) {
            vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
            this.deployLogic(i, address(0), reg, BLOCK_TIME);
            vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
            this.deployLogic(i, tl, address(0), BLOCK_TIME);
            vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
            this.deployLogic(i, tl, reg, 0);
        }
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        new ParameterStore(address(0), reg, BLOCK_TIME, false, logics);
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        new ParameterStore(tl, address(0), BLOCK_TIME, false, logics);
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        new ParameterStore(tl, reg, 0, false, logics);
    }

    /// @dev External so a test can expect the constructor's revert.
    function deployLogic(
        uint256 i,
        address tl,
        address reg,
        uint32 bt
    ) external returns (address) {
        return _logic(i, tl, reg, bt, false);
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-002
    function test_TEST_062_evenTheTimelockCannotCallALogicDirectly() public {
        bytes[6] memory calls = [
            abi.encodeCall(store.tightenMarketUsdCap, (M, 1e8)),
            abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8)),
            abi.encodeCall(store.setInitialMarketCaps, (M, 1e8, 0, 1e8)),
            abi.encodeCall(store.setCachedWindow, (100)),
            abi.encodeCall(store.setAvanaFeeShareBps, (100)),
            abi.encodeCall(store.getOracleConfig, (address(lpOracle)))
        ];
        address[6] memory targets =
            [logics.tighten, logics.loosen, logics.listing, logics.adminOracle, logics.adminRisk, logics.adminOracle];
        bytes memory notDelegated = abi.encodeWithSelector(IParameterStoreErrors.NotDelegated.selector);
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(address(timelock));
            (bool ok, bytes memory ret) = targets[i].call(calls[i]);
            assertFalse(ok);
            assertEq(ret, notDelegated);
        }
        assertEq(store.marketUsdCap(M), 5_000_000e8);
        assertEq(store.avanaFeeShareBps(), 2000);
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-003
    function test_TEST_062_foreignDelegatecallTouchesOnlyTheCaller() public {
        ForeignDelegator d = new ForeignDelegator();
        // The logic runs on the delegator's empty storage: its own maxShortfall is 0, so nothing is stricter.
        (bool ok, bytes memory ret) = d.run(logics.tighten, abi.encodeCall(store.tightenMaxShortfallBps, (0)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IParameterStoreErrors.NotStricter.selector));
        // A write that succeeds there lands in the delegator, never in the store.
        (ok,) = d.run(logics.adminRisk, abi.encodeCall(store.setAvanaFeeShareBps, (4000)));
        assertTrue(ok);
        assertEq(store.avanaFeeShareBps(), 2000);
        // GlobalParams word 5 packs maxFlashFeeBps (bits 0-15) and avanaFeeShareBps (bits 16-31).
        uint256 slot = 0x97d60a1f76524429d85918aee5154ffd84c83f78fddb1d1f3d0a0bfeca081800;
        assertEq(uint16(uint256(vm.load(address(d), bytes32(slot + 5))) >> 16), 4000);
        assertEq(uint16(uint256(vm.load(address(store), bytes32(slot + 5))) >> 16), 2000);
    }
}
