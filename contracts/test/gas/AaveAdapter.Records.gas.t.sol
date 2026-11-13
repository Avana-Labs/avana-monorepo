// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AaveAdapterRecordsGasTest
/// @notice Gas of the Adapter's flows on an account-market at the 16-record bound (TEST-269, Adapter side), on the real
/// local Aave V4 with the real Collateralization, and the event inventory of every Adapter action (TEST-061).
/// @dev The bounds are generous ceilings over the values measured on this fixture (noted next to each), so a change
/// that makes a flow grow with the record count, or loop over unbounded data, fails here. The oracles are stand-ins, so
/// the fork calibration of TEST-269 (cold LPOracle reads, real unwinds) stays a separate launch measurement.
/// forge-config: default.isolate = false
contract AaveAdapterRecordsGasTest is AaveAdapterFixture {
    uint128 internal constant SMALL = 1_000_000_000; // 1,000 vault tokens, $2,000 each record

    bytes32[] internal keys;
    address internal p;

    function _sixteenRecords() internal {
        for (uint256 i = 0; i < 15; ++i) {
            (bytes32 k, address proxy) = _pledgeAs(alice, MARKET_ID, SMALL);
            keys.push(k);
            p = proxy;
        }
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1000e6);
    }

    function _gasOf(
        address caller,
        bytes memory data
    ) internal returns (uint256 used) {
        vm.prank(caller);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = adapter.call(data);
        used = g - gasleft();
        if (!ok) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // TEST-269 verifies: REQ-ADAPTER-051, INV-096
    // Sources: 5.1 TEST-269 (Adapter side)
    /// @notice The 16th pledge into an indebted account-market stays under 900,000 gas (measured 424,809).
    function test_TEST_269_sixteenthPledgeGas() public {
        _sixteenRecords();
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, SMALL);
        uint256 used = _gasOf(alice, abi.encodeCall(adapterC.pledge, (MARKET_ID, _ref(key), _deadline())));
        assertEq(coll.getOpenRecordCount(p, vt), 16, "16 records");
        emit log_named_uint("16th pledge gas", used);
        assertLt(used, 900_000, "16th pledge");
    }

    // TEST-269 verifies: REQ-ADAPTER-051, INV-096
    /// @notice A with-debt withdrawal of one record out of 16 stays under 600,000 gas (measured 258,550).
    function test_TEST_269_withDebtWithdrawGas() public {
        _sixteenRecords();
        (bytes32 k,) = _pledgeAs(alice, MARKET_ID, SMALL);
        uint256 used = _gasOf(alice, abi.encodeCall(adapterC.withdraw, (MARKET_ID, _ref(k), SMALL, _deadline(), 0)));
        assertEq(coll.getOpenRecordCount(p, vt), 15, "one record left the account");
        emit log_named_uint("withdraw with debt gas", used);
        assertLt(used, 600_000, "withdraw with debt");
    }

    // TEST-269 verifies: REQ-ADAPTER-051, REQ-ADAPTER-071, INV-096
    /// @notice `repayAllAndWithdraw` naming two reserves on a 16-record account stays under 900,000 gas (measured
    /// 435,623).
    function test_TEST_269_repayAllAndWithdrawGas() public {
        _sixteenRecords();
        (bytes32 k,) = _pledgeAs(alice, MARKET_ID, SMALL);
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        ids[0] = debtReserveId;
        ids[1] = usdcReserveId;
        uint256[] memory caps = new uint256[](2);
        caps[0] = g;
        caps[1] = u;
        uint256 used = _gasOf(
            alice, abi.encodeCall(adapterC.repayAllAndWithdraw, (MARKET_ID, _ref(k), SMALL, ids, caps, _deadline()))
        );
        assertEq(_borrowCountOf(p), 0, "debt-free");
        emit log_named_uint("repayAllAndWithdraw gas", used);
        assertLt(used, 900_000, "repayAllAndWithdraw");
    }

    // TEST-269 verifies: REQ-ADAPTER-051, REQ-ADAPTER-078, INV-096
    /// @notice A partial removal with debt on a 16-record account stays under 800,000 gas (measured 394,086).
    function test_TEST_269_removeLiquidityGas() public {
        _sixteenRecords();
        (bytes32 k,) = _pledgeAs(alice, MARKET_ID, SMALL);
        uint256 used = _gasOf(
            alice, abi.encodeCall(adapterC.removeLiquidity, (MARKET_ID, _ref(k), SMALL / 2, _mins(), _deadline(), 0))
        );
        assertEq(_sharesOf(p, vtReserveId), uint256(SMALL) * 16 - SMALL / 2, "removed");
        emit log_named_uint("removeLiquidity gas", used);
        assertLt(used, 800_000, "removeLiquidity");
    }

    // TEST-269 verifies: REQ-ADAPTER-051, REQ-ADAPTER-070, INV-096, INV-014
    /// @notice A liquidation's `burnSeized` and settlement over all 16 records stays under 2,000,000 gas for the whole
    /// LPVaultSwap step (measured 957,888 with the stand-in LPVault).
    function test_TEST_269_liquidationOverSixteenRecordsGas() public {
        _sixteenRecords();
        _pledgeAs(alice, MARKET_ID, SMALL);
        // $32,000 at CF 80% against ~11,000 of debt; at $0.60 per token the account is below 1.
        vtPrice.set(0.6e8);
        uint256 g = gasleft();
        uint256 seized = swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, p, 5000e18, 2);
        uint256 used = g - gasleft();
        assertGt(seized, SMALL, "seized across several records");
        emit log_named_uint("liquidation step gas", used);
        assertLt(used, 2_000_000, "liquidation step");
    }

    // ─── Event inventory (TEST-061) ───

    function _adapterEvents() internal view returns (bytes32[] memory topics) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter) ++n;
        }
        topics = new bytes32[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter) topics[n++] = logs[i].topics[0];
        }
    }

    function _assertEvents(
        bytes32[] memory expected,
        string memory what
    ) internal view {
        bytes32[] memory got = _adapterEvents();
        assertEq(got.length, expected.length, what);
        for (uint256 i = 0; i < expected.length; ++i) {
            assertEq(got[i], expected[i], what);
        }
    }

    function _list(
        bytes32 a
    ) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = a;
    }

    function _list(
        bytes32 a,
        bytes32 b
    ) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](2);
        (l[0], l[1]) = (a, b);
    }

    function _list(
        bytes32 a,
        bytes32 b,
        bytes32 c
    ) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](3);
        (l[0], l[1], l[2]) = (a, b, c);
    }

    // TEST-061 verifies: REQ-ADAPTER-066, REQ-PROXY-024, REQ-PROXY-032, REQ-PROXY-039, REQ-PROXY-047, REQ-ADAPTER-065, REQ-ADAPTER-079, REQ-ADAPTER-078, REQ-ADAPTER-080, REQ-ADAPTER-070, REQ-PROXY-046
    // Sources: 2.6 Events table
    /// @notice Each action is one call that emits exactly the Adapter events of the 2.6 table, in order: a first
    /// pledge `UserProxyCreated`, `CollateralSupplied`, `CollateralAdded`; a top-up `CollateralSupplied`,
    /// `CollateralAdded`; a borrow `Borrowed`; a repay `Repaid`; a re-credit `CollateralSupplied`,
    /// `CollateralRecredited`; a partial removal `CollateralReduced`; a repay with collateral `RepaidWithCollateral`;
    /// a liquidation's burn `SeizedUnitsBurned`; a last debt-free withdrawal `CollateralDisabled`,
    /// `CollateralWithdrawn`; fee collection and a zero-debt repay none.
    function test_TEST_061_eventInventory() public {
        bytes32 created = IAaveAdapterEvents.UserProxyCreated.selector;
        bytes32 supplied = IAaveAdapterEvents.CollateralSupplied.selector;
        bytes32 added = IAaveAdapterEvents.CollateralAdded.selector;
        vm.recordLogs();
        (bytes32 k1, address proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _assertEvents(_list(created, supplied, added), "first pledge");
        vm.recordLogs();
        (bytes32 k2,) = _pledgeAs(alice, MARKET_ID, UNITS);
        _assertEvents(_list(supplied, added), "top-up");
        vm.recordLogs();
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        _assertEvents(_list(IAaveAdapterEvents.Borrowed.selector), "borrow");
        _fund(bob, debtReserveId, 100e18);
        vm.recordLogs();
        vm.prank(bob);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 100e18, false, _deadline());
        _assertEvents(_list(IAaveAdapterEvents.Repaid.selector), "repay");
        vm.recordLogs();
        vm.prank(bob);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 1, false, _deadline());
        _assertEvents(new bytes32[](0), "zero-debt repay");
        lpVault.addUnits(k2, 1_000_000_000);
        vm.recordLogs();
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k2), "", _deadline());
        _assertEvents(_list(supplied, IAaveAdapterEvents.CollateralRecredited.selector), "recredit");
        vm.recordLogs();
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k2), 1_000_000_000, _mins(), _deadline(), 0);
        _assertEvents(_list(IAaveAdapterEvents.CollateralReduced.selector), "removal");
        swap.setDeleverage(1000e18, 2e12, 0);
        vm.recordLogs();
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, k2, 500_000_000, debtReserveId));
        _assertEvents(_list(IAaveAdapterEvents.RepaidWithCollateral.selector), "repay with collateral");
        lpVault.accrueFees(k1, 5);
        vm.recordLogs();
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(k1), _deadline());
        _assertEvents(new bytes32[](0), "fee collection");
        uint256 g = _debtOf(proxy, debtReserveId);
        _fund(alice, debtReserveId, g);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        uint256 left = coll.previewRelease(INTEGRATION, k2);
        vm.recordLogs();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), left, _deadline(), 0);
        _assertEvents(
            _list(IAaveAdapterEvents.CollateralDisabled.selector, IAaveAdapterEvents.CollateralWithdrawn.selector),
            "last withdrawal"
        );
        (, address bp) = _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(bob, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.5e8);
        vm.recordLogs();
        swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, bp, 2000e18, 2);
        _assertEvents(_list(IAaveAdapterEvents.SeizedUnitsBurned.selector), "liquidation burn");
    }
}
