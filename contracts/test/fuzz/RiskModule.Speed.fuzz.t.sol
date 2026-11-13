// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleSpeedFuzzTest
/// @notice TEST-323 on the real RiskModule: borrows split across four accounts, blocks and amounts never take more than
/// the market window's limit over any interval of τ, the (Hub, asset) window holds the same way, a direct call by any
/// address other than the AaveAdapter never fills a window, and a refused borrow charges nothing.
/// @dev World: the RiskModule fixture, GHO at $1.00, τ = 3,600 s, both borrow limits fixed (rate 0, min = max), so the
/// limit at every check is the same and the ghost bound is exact.
contract RiskModuleSpeedFuzzTest is RiskModuleFixture {
    uint256 internal constant TAU = 3600;
    uint256 internal constant N = 12;
    uint256 internal constant LIM_USD = 1_000_000e8;
    uint256 internal constant LIM_GHO = 800_000e18;

    address[4] internal accounts;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        rHub.setSpokeListed(GHO_ASSET, address(spoke), true);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        store.setMarketSpeed(
            mid, MarketSpeedLimits(uint32(TAU), 0, 0, uint96(LIM_USD), uint96(LIM_USD), 1_000_000e8, 1_000_000e8)
        );
        store.setDebtSpeed(address(hub), address(gho), SpeedLimit(0, uint32(TAU), uint96(LIM_GHO), uint96(LIM_GHO)));
        accounts[0] = address(proxy);
        for (uint256 i = 1; i < 4; ++i) {
            PositionProxy p = new PositionProxy(address(adapter), makeAddr(string(abi.encode(i))), address(spoke), mid);
            rSpoke.setStatus(address(p), VT_RESERVE, true, false);
            rSpoke.setStatus(address(p), GHO_RESERVE, false, true);
            rSpoke.setSupplied(address(p), VT_RESERVE, 1e21);
            rSpoke.setAccount(address(p), 1.5e18, 1000 * 1e26 * RAY, 1);
            accounts[i] = address(p);
        }
    }

    function _sum(
        uint256[N] memory ts,
        uint256[N] memory xs,
        uint256 n,
        uint256 to,
        uint256 span
    ) internal pure returns (uint256 s) {
        for (uint256 j = 0; j < n; ++j) {
            if (ts[j] <= to && ts[j] + span > to) s += xs[j];
        }
    }

    // TEST-323 verifies: REQ-RISK-092, REQ-RISK-098, SPEC-CAP-011, ATTACK-205, INV-110
    // Sources: MATH-AR-85e
    function testFuzz_TEST_323_splitBorrowsNeverBeatTheWindow(
        uint8[N] memory actor,
        uint16[N] memory gap,
        uint64[N] memory amount
    ) public {
        uint256[N] memory ts;
        uint256[N] memory usd;
        uint256[N] memory units;
        uint256 n = 0;
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < N; ++i) {
            t += uint256(gap[i]) % (TAU + TAU / 2);
            vm.warp(t);
            _report(uint64(t), 1e8, 1e8);
            uint256 a = (uint256(amount[i]) % 600_000 + 1) * 1e18;
            SpeedView memory before;
            (before,) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
            vm.prank(address(adapter));
            try riskModule.preBorrowCheck(accounts[actor[i] % 4], GHO_RESERVE, a) {
                (ts[n], usd[n], units[n]) = (t, a / 1e10, a);
                ++n;
            } catch (bytes memory err) {
                bytes4 sel = bytes4(err);
                assertTrue(
                    sel == IRiskModuleErrors.BorrowSpeedExceeded.selector
                        || sel == IRiskModuleErrors.DebtSpeedExceeded.selector,
                    "only a speed error refuses"
                );
                (SpeedView memory afterwards,) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
                assertEq(afterwards.used, before.used, "a refused borrow charges nothing");
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            if (i + 1 < n && ts[i + 1] == ts[i]) continue;
            assertLe(_sum(ts, usd, n, ts[i], TAU), LIM_USD, "market: any tau holds at most L");
            assertLe(_sum(ts, units, n, ts[i], TAU), LIM_GHO, "(Hub, GHO): any tau holds at most L");
            assertLe(_sum(ts, usd, n, ts[i], 2 * TAU), 2 * LIM_USD, "any 2 tau holds at most 2L");
        }
    }

    // TEST-323 verifies: REQ-RISK-095, ATTACK-205
    function testFuzz_TEST_323_onlyTheAdapterFillsTheBorrowWindows(
        address caller,
        uint64 amount
    ) public {
        vm.assume(caller != address(adapter));
        uint256 a = (uint256(amount) % 700_000 + 1) * 1e18;
        vm.prank(caller);
        try riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, a) {} catch {}
        (SpeedView memory m, SpeedView memory d) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        assertEq(m.used + d.used, 0, "a direct call writes nothing");
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, a);
        (m, d) = riskModule.getBorrowSpeed(mid, GHO_RESERVE);
        assertEq(m.used, a / 1e10);
        assertEq(d.used, a);
    }

    // TEST-323 verifies: REQ-RISK-093, REQ-RISK-095, REQ-RISK-099, SPEC-CAP-011, ATTACK-205
    function testFuzz_TEST_323_splitPledgesNeverBeatTheWindow(
        uint16[N] memory gap,
        uint32[N] memory units
    ) public {
        uint256[N] memory ts;
        uint256[N] memory usd;
        uint256 n = 0;
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < N; ++i) {
            t += uint256(gap[i]) % (TAU + TAU / 2);
            vm.warp(t);
            _report(uint64(t), 1e8, 1e8);
            uint128 u = uint128((uint256(units[i]) % 250_000 + 5) * 1e18);
            vm.prank(address(coll));
            try riskModule.checkPledge(
                wallet, address(proxy), mid, V3, bytes32(uint256(1)), u, _counters(), false
            ) returns (
                PledgeCharge memory c
            ) {
                (ts[n], usd[n]) = (t, c.usdCharge);
                ++n;
            } catch (bytes memory err) {
                assertEq(bytes4(err), IRiskModuleErrors.PledgeSpeedExceeded.selector, "only the pledge window refuses");
            }
        }
        for (uint256 i = 0; i < n; ++i) {
            if (i + 1 < n && ts[i + 1] == ts[i]) continue;
            assertLe(_sum(ts, usd, n, ts[i], TAU), 1_000_000e8, "pledges: any tau holds at most P");
        }
    }
}
