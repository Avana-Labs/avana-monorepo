// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapEventsFuzzTest
/// @notice The monitoring record of every settlement fuzzed (2.11 "Events", REQ-SWAP-029, REQ-SWAP-115): for any
/// repayment, route mode, route rate, fee share and shortfall budget, exactly one `LiquidationSettled` is emitted, its
/// indexed caller, proxy and market are the call's, and every field of its report equals the returned result and the
/// call's parameters; `BorrowerSurplusPaid` appears exactly when `B > 0`; `RouteFailed` never appears for a backup;
/// `PendingSettlementForwarded` reports the units, the amount added and the Coverage Spoke of a pending settlement.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapEventsFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _check(
        SettlementReport memory rep,
        LiquidationResult memory r,
        LiquidationParams memory p
    ) internal pure {
        assertEq(rep.debtReserveId, p.debtReserveId, "reserve");
        assertEq(rep.debtAsset, r.debtAsset, "asset");
        assertEq(rep.debtRepaid, r.debtRepaid, "D");
        assertEq(rep.unitsSeized, r.unitsSeized, "c");
        assertEq(rep.amountsOut.length, r.amountsOut.length, "amounts length");
        for (uint256 i = 0; i < rep.amountsOut.length; ++i) {
            assertEq(rep.amountsOut[i], r.amountsOut[i], "amounts");
        }
        assertEq(rep.recovered, r.recovered, "R");
        assertEq(rep.minOut, r.minOut, "minRec");
        assertEq(rep.callerFunds, r.callerFunds, "Kf");
        assertEq(rep.avanaFee, r.avanaFee, "A");
        assertEq(rep.keeperReward, r.keeperReward, "kr");
        assertEq(rep.borrowerSurplus, r.borrowerSurplus, "B");
        assertEq(rep.keeperOut, r.keeperOut, "keeperOut");
        assertEq(rep.minPayout, p.minPayout, "minPayout");
        assertEq(uint8(rep.routeMode), uint8(p.routeMode), "route mode");
        assertEq(rep.shortfall, r.shortfall, "shortfall");
        assertEq(rep.surplus, r.avanaFee + r.keeperReward + r.borrowerSurplus, "S = A + kr + B");
        assertEq(rep.routeUsed.length, r.amountsOut.length, "one route entry per token");
        assertEq(rep.routeUsed[0], 0, "the debt-asset leg is never routed");
        assertEq(rep.routeUsed[1], p.routeMode == RouteMode.BackupOnly ? 2 : 1, "USDT leg on the mode's route");
        assertLe(rep.effectiveSlippageBps, SLIPPAGE_BPS, "s within the allowance");
        assertGe(rep.bonusBps, BPS, "bonus at least 10,000");
    }

    /// @notice One `LiquidationSettled` whose report equals the result, for any parameters.
    // TEST-170 verifies: REQ-SWAP-029, REQ-SWAP-115, SPEC-LIQ-010, SPEC-LIQ-022
    function testFuzz_settledReportEqualsResult(
        uint256 debtToCover,
        bool backupOnly,
        uint256 rateBps,
        uint16 share,
        uint256 maxShortfall
    ) public {
        debtToCover = bound(debtToCover, 50e6, 6000e6);
        rateBps = bound(rateBps, 9990, 10_300);
        share = uint16(bound(share, 0, 5000));
        maxShortfall = bound(maxShortfall, 0, 100e6);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        store.setAvanaFeeShareBps(share);
        LiquidationParams memory p = _params(proxy, debtToCover);
        p.routeMode = backupOnly ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup;
        p.maxShortfall = maxShortfall;
        _fund(usdc, keeper, debtToCover + maxShortfall);
        vm.recordLogs();
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, LiquidationSettled.selector), 1, "exactly one LiquidationSettled");
        assertEq(_count(logs, RouteFailed.selector), 0, "no route failed");
        assertEq(_count(logs, BorrowerSurplusPaid.selector), r.borrowerSurplus > 0 ? 1 : 0, "B event iff B > 0");
        (SettlementReport memory rep,) = _settledReport(logs);
        _check(rep, r, p);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != LiquidationSettled.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), keeper, "indexed caller");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), proxy, "indexed proxy");
            assertEq(uint256(logs[i].topics[3]), MARKET_ID, "indexed market");
        }
    }

    /// @notice A failing primary emits exactly one `RouteFailed` for the USDT leg, never one for the backup, and the
    /// report records the backup as the route used.
    // TEST-232 verifies: REQ-SWAP-058, REQ-SWAP-115
    function testFuzz_primaryFailureRecorded(
        uint256 debtToCover
    ) public {
        debtToCover = bound(debtToCover, 50e6, 6000e6);
        usdtUsdcPool.setRate(9000, 10_000); // the primary fails its leg minimum
        LiquidationParams memory p = _params(proxy, debtToCover);
        _fund(usdc, keeper, debtToCover);
        vm.recordLogs();
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, RouteFailed.selector), 1, "one RouteFailed, for the primary");
        (SettlementReport memory rep,) = _settledReport(logs);
        assertEq(rep.routeUsed[1], 2, "backup used");
        assertEq(rep.recovered, r.recovered, "R");
    }

    /// @notice `PendingSettlementForwarded` reports the caller, market, vault token, units, amounts, the amount added
    /// and the USDC Coverage Spoke.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-070, SPEC-LIQ-014
    function testFuzz_pendingEventFields(
        uint256 kept,
        address caller
    ) public {
        kept = bound(kept, 100e6, 2000e6);
        vm.assume(caller != address(0) && caller.code.length == 0 && uint160(caller) > 0xffff);
        uint256 units = _seizeAndKeep(proxy, kept);
        _liquidateAs(keeper, _params(proxy, 100e6));
        vm.recordLogs();
        vm.prank(caller);
        (uint256 settled, uint256[] memory amounts, uint256 recovered) = lvs.settlePending(MARKET_ID, usdcReserveId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(settled, units, "units");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != PendingSettlementForwarded.selector) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), caller, "indexed caller");
            assertEq(uint256(logs[i].topics[2]), MARKET_ID, "indexed market");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(usdc), "indexed asset");
            (address vaultToken, uint256 u, uint256[] memory a, uint256 added,, address coverage,,,) = abi.decode(
                logs[i].data, (address, uint256, uint256[], uint256, uint256, address, uint8[], uint256, uint256)
            );
            assertEq(vaultToken, address(vt), "vault token");
            assertEq(u, units, "units");
            assertEq(a[0], amounts[0], "USDC released");
            assertEq(a[1], amounts[1], "USDT released");
            assertEq(added, recovered, "R added");
            assertEq(coverage, address(usdcCoverage), "USDC Coverage Spoke");
        }
        assertTrue(found, "PendingSettlementForwarded emitted");
    }
}
