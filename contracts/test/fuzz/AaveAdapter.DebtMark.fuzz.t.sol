// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterDebtMarkFuzzTest
/// @notice The indebted mark Collateralization keeps for `closeMarket`, driven only through the Adapter on the real
/// Aave V4 Spoke: over random sequences of borrows, partial and full repays of both reserves and time, the market
/// reads debt-free exactly when Aave reports no borrow on the account (REQ-PROXY-032, REQ-COLL-039/040); and the
/// order of the RiskModule's checks in a removal that leaves debt (REQ-ADAPTER-078).
/// forge-config: default.isolate = false
contract AaveAdapterDebtMarkFuzzTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
    }

    function _step(
        uint8 action,
        uint256 amount
    ) internal {
        uint8 a = action % 6;
        uint256 d = _deadline();
        if (a == 0) {
            uint256 n = adapterC.borrowNonce(p);
            vm.prank(alice);
            // A borrow the health check refuses changes nothing; the mark is checked either way.
            (bool ok,) = adapter.call(
                abi.encodeCall(adapterC.borrow, (MARKET_ID, debtReserveId, bound(amount, 1, 2000e18), alice, d, 0, n))
            );
            if (!ok) return;
        } else if (a == 1) {
            uint256 n = adapterC.borrowNonce(p);
            vm.prank(alice);
            (bool ok,) = adapter.call(
                abi.encodeCall(adapterC.borrow, (MARKET_ID, usdcReserveId, bound(amount, 1, 2000e6), alice, d, 0, n))
            );
            if (!ok) return;
        } else if (a == 2 || a == 3) {
            uint256 r = a == 2 ? debtReserveId : usdcReserveId;
            uint256 owed = _debtOf(p, r);
            if (owed == 0) return;
            uint256 x = bound(amount, 1, owed);
            _fund(bob, r, x);
            vm.prank(bob);
            adapterC.repay(alice, MARKET_ID, r, x, false, d);
        } else if (a == 4) {
            uint256 r = amount % 2 == 0 ? debtReserveId : usdcReserveId;
            uint256 owed = _debtOf(p, r);
            if (owed == 0) return;
            _fund(alice, r, owed);
            vm.prank(alice);
            adapterC.repay(alice, MARKET_ID, r, owed, true, d);
        } else {
            vm.warp(block.timestamp + bound(amount, 1, 30 days));
            // Prices stay fresh: the feeds and the USDC DebtOracle report again.
            _report(lpOracleA, uint64(block.timestamp));
            usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        }
    }

    // TEST-029 verifies: REQ-PROXY-032, REQ-PROXY-019, REQ-ADAPTER-104, REQ-COLL-040
    /// @notice After every step of a random sequence the market reads debt-free exactly when Aave reports no borrow on
    /// the market's only account: a borrow marks the account, and the repay that clears its last reserve clears the
    /// mark, whichever payer and in whichever order.
    function testFuzz_TEST_029_markFollowsBorrowCount(
        uint8[8] calldata actions,
        uint256[8] calldata amounts
    ) public {
        for (uint256 i = 0; i < 8; ++i) {
            _step(actions[i], amounts[i]);
            assertEq(coll.getMarketDebtFree(vt), _borrowCountOf(p) == 0, "mark equals Aave's borrow count");
        }
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-089, REQ-RISK-070, SPEC-PROXY-001
    /// @notice In a removal that leaves debt the reviewed RiskModule's checks run in order: the pre-check's gates
    /// (a latched breaker) before anything else, then the remaining-record minimum, then the health check; each is
    /// reached by clearing the one before.
    function test_TEST_237_removalCheckOrder() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
        rstore.setMinPledge(MARKET_ID, 18_000e8);
        registry.setLatched(bytes32(MARKET_ID), 512, 0);
        uint256 d = _deadline();
        uint256[] memory mins = _mins();
        // Removing 2,000 tokens leaves $16,000 worth (below the $18,000 minimum) and hf 12,800 / 10,000 = 1.28.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, uint32(512)));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 2_000_000_000, mins, d, 2e18);
        registry.setLatched(bytes32(MARKET_ID), 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.RecordBelowMinPledge.selector, 16_000e8, 18_000e8));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 2_000_000_000, mins, d, 2e18);
        rstore.setMinPledge(MARKET_ID, 0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.28e18, 2e18));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 2_000_000_000, mins, d, 2e18);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 2_000_000_000, mins, d, 1.28e18);
        assertEq(_sharesOf(p, vtReserveId), UNITS - 2_000_000_000, "removed");
    }

    // TEST-029 verifies: REQ-PROXY-032, REQ-COLL-039, REQ-COLL-040
    /// @notice With several accounts in the market, the market reads debt-free only once every account's Spoke
    /// account has no borrow, whichever account repays last.
    function testFuzz_TEST_029_marketMarkCountsEveryAccount(
        uint256 seed
    ) public {
        (, address pb) = _pledgeAs(bob, MARKET_ID, UNITS);
        (, address pc) = _pledgeAs(carol, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        _borrowAs(bob, MARKET_ID, usdcReserveId, 100e6);
        _borrowAs(carol, MARKET_ID, debtReserveId, 50e18);
        address[3] memory owners = [alice, bob, carol];
        address[3] memory proxies = [p, pb, pc];
        uint256[3] memory reserves = [debtReserveId, usdcReserveId, debtReserveId];
        uint256 first = seed % 3;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 j = (first + i) % 3;
            assertFalse(coll.getMarketDebtFree(vt), "an account still owes");
            uint256 owed = _debtOf(proxies[j], reserves[j]);
            _fund(owners[j], reserves[j], owed);
            vm.prank(owners[j]);
            adapterC.repay(owners[j], MARKET_ID, reserves[j], owed, true, _deadline());
        }
        assertTrue(coll.getMarketDebtFree(vt), "every account debt-free");
    }

    // TEST-099 verifies: REQ-ADAPTER-104, REQ-COLL-040, Q-355
    /// @notice A mark left set by a failing Spoke read during the last repay stays until anyone calls
    /// `refreshDebtMark`; the refresh clears it exactly when Aave reports no borrow, and never sets one.
    function testFuzz_TEST_099_refreshClearsOnlyDebtFree(
        bool leaveDebt,
        address caller
    ) public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 10e6);
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
        if (!leaveDebt) {
            uint256 u = _debtOf(p, usdcReserveId);
            _fund(alice, usdcReserveId, u);
            vm.mockCallRevert(aave.cdpSpoke, abi.encodeWithSignature("getUserAccountData(address)", p), "down");
            vm.prank(alice);
            adapterC.repay(alice, MARKET_ID, usdcReserveId, u, true, _deadline());
            vm.clearMockedCalls();
        }
        assertFalse(coll.getMarketDebtFree(vt), "marked before the refresh");
        vm.prank(caller);
        adapterC.refreshDebtMark(p);
        assertEq(coll.getMarketDebtFree(vt), !leaveDebt, "cleared exactly when debt-free");
        vm.prank(caller);
        adapterC.refreshDebtMark(p);
        assertEq(coll.getMarketDebtFree(vt), !leaveDebt, "idempotent");
    }
}
