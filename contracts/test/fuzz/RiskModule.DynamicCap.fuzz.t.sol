// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DynamicCapMath} from "../../src/legacy/risk-module/DynamicCapMath.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {DynamicCap} from "../../src/legacy/risk-module/types/RiskModuleTypes.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleDynamicCapFuzzTest
/// @notice On the real LegacyRiskModule, borrows split across four accounts with random gaps, amounts and repays follow a
/// reference model of the rule exactly: the first borrow of each interval fixes `C = D_start + L(D_start)`, a borrow
/// passes iff the debt after it is at most `C`, and a refused borrow stores nothing. A direct call by any address
/// other than the AaveAdapter never stores an interval.
/// @dev World: the LegacyRiskModule fixture, GHO at $1.00 (18 decimals, so the USD value is the amount over 1e10), tau =
/// 3,600 s, alpha 25 % within $250,000 .. $2,500,000, the Spoke owing 1,000,000 GHO at the start.
contract RiskModuleDynamicCapFuzzTest is RiskModuleFixture {
    uint256 internal constant TAU = 3600;
    uint256 internal constant N = 14;
    uint256 internal constant START_OWED = 1_000_000e18;

    address[4] internal accounts;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        hub.setOwed(GHO_ASSET, address(spoke), START_OWED, 0);
        store.setMarketDynamicCap(mid, MarketDynamicCap(uint32(TAU), 2500, 250_000e8, 2_500_000e8));
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

    /// @dev The reference model: the Spoke's GHO owed, the model's running interval and the clock.
    struct Model {
        uint256 owed;
        uint256 start;
        uint256 cap;
        uint256 t;
    }

    // REQ-RISK-092, REQ-RISK-098, SPEC-CAP-011, ATTACK-205, INV-110
    function testFuzz_borrowsFollowTheReferenceModel(
        uint8[N] memory actor,
        uint16[N] memory gap,
        uint64[N] memory amount,
        uint64[N] memory repay
    ) public {
        Model memory m = Model({owed: START_OWED, start: 0, cap: 0, t: block.timestamp});
        for (uint256 i = 0; i < N; ++i) {
            _step(m, accounts[actor[i] % 4], gap[i], amount[i], repay[i]);
        }
    }

    function _step(
        Model memory m,
        address account,
        uint16 gap,
        uint64 amount,
        uint64 repay
    ) internal {
        m.t += uint256(gap) % (TAU + TAU / 2);
        vm.warp(m.t);
        _report(uint64(m.t), 1e8, 1e8);
        uint256 a = (uint256(amount) % 1_500_000 + 1) * 1e18;
        uint256 debt = m.owed / 1e10;
        if (m.start == 0 || m.t >= m.start + TAU) {
            (m.start, m.cap) = (m.t, DynamicCapMath.target(store.marketDynamicCap(mid), debt));
        }
        bool fits = debt + (a + 1e10 - 1) / 1e10 <= m.cap;
        DynamicCap memory before = riskModule.getDynamicCap(mid);
        vm.prank(address(adapter));
        try riskModule.preBorrowCheck(account, GHO_RESERVE, a) {
            assertTrue(fits, "passes only within the interval's cap");
            m.owed += a;
            hub.setOwed(GHO_ASSET, address(spoke), m.owed, 0);
            DynamicCap memory d = riskModule.getDynamicCap(mid);
            assertEq(d.intervalStart, m.start, "the interval's start");
            assertEq(d.cap, m.cap, "the interval's cap");
        } catch (bytes memory err) {
            assertFalse(fits, "refuses only above the interval's cap");
            assertEq(bytes4(err), IRiskModuleErrors.DynamicBorrowCapExceeded.selector, "only a cap error refuses");
            DynamicCap memory afterwards = riskModule.getDynamicCap(mid);
            assertEq(afterwards.intervalStart, before.intervalStart, "a refused borrow stores nothing");
            assertEq(afterwards.cap, before.cap);
            // The refused borrow opened no interval of the model's.
            (m.start, m.cap) = (before.intervalStart, before.cap);
        }
        // A repay is never limited and never lowers the cap.
        m.owed -= uint256(repay) % (m.owed / 4 + 1);
        hub.setOwed(GHO_ASSET, address(spoke), m.owed, 0);
        vm.prank(address(adapter));
        riskModule.preWithdrawCheck(account);
    }

    // REQ-RISK-095, ATTACK-205
    function testFuzz_onlyTheAdapterStoresTheInterval(
        address caller,
        uint64 amount
    ) public {
        vm.assume(caller != address(adapter));
        uint256 a = (uint256(amount) % 200_000 + 1) * 1e18;
        vm.prank(caller);
        try riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, a) {} catch {}
        DynamicCap memory d = riskModule.getDynamicCap(mid);
        assertEq(uint256(d.intervalStart) + d.cap, 0, "a direct call stores nothing");
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, a);
        d = riskModule.getDynamicCap(mid);
        assertEq(d.intervalStart, block.timestamp);
        assertEq(d.cap, 1_250_000e8, "D + 25 % of D");
    }
}
