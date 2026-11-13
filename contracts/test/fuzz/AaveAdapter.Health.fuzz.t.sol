// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterHealthFuzzTest
/// @notice Boundaries of the gates the Adapter runs with the reviewed RiskModule on the real Aave V4 Spoke: the
/// post-action health gate of SPEC-PROXY-001 at a withdrawal, a removal and a borrow that leave debt (passes exactly
/// when the Spoke's health factor reaches `max(1.00, hardHealthFloor, minHealthFactor)`), the feed-age and debt-price
/// boundaries of SPEC-PROXY-002, the remaining-record minimum of a removal with debt, and the health-factor direction
/// of a repay with collateral (SPEC-PROXY-009).
/// @dev Each case first measures the Spoke's own health factor after the action in a snapshot with no Avana floor,
/// then replays the action with the fuzzed floor and minimum and checks the outcome against that measurement, so the
/// expectation is Aave's own floored value, never a recomputation.
/// forge-config: default.isolate = false
contract AaveAdapterHealthFuzzTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
    }

    function _required(
        uint256 floor,
        uint256 minHf
    ) internal pure returns (uint256 r) {
        r = 1e18;
        if (floor > r) r = floor;
        if (minHf > r) r = minHf;
    }

    // ─── SPEC-PROXY-001 at a withdrawal with debt ───

    // TEST-019 verifies: SPEC-PROXY-001, REQ-PROXY-036, REQ-PROXY-067, REQ-PROXY-022
    // Sources: MATH-AR-03, MATH-AR-06, HYP-13, HYP-20
    /// @notice A withdrawal that leaves debt passes exactly when the health factor after the release reaches
    /// `max(1, floor, minHealthFactor)`; otherwise it reverts `HealthFactorTooLow(hf, required)` and changes nothing.
    function testFuzz_TEST_019_withdrawHealthBoundary(
        uint256 borrowed,
        uint256 floor,
        uint256 minHf
    ) public {
        borrowed = bound(borrowed, 1e18, 23_000e18);
        floor = bound(floor, 0, 4e18);
        minHf = bound(minHf, 0, 4e18);
        _borrowAs(alice, MARKET_ID, debtReserveId, borrowed);
        uint256 d = _deadline();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        (bool ok,) = adapter.call(abi.encodeCall(adapterC.withdraw, (MARKET_ID, _ref(k2), UNITS / 2, d, 0)));
        uint256 hfAfter = ok ? _hf(p) : 0;
        vm.revertToState(snap);
        rstore.setHardFloor(MARKET_ID, floor);
        uint256 required = _required(floor, minHf);
        if (!ok) {
            // Aave itself refuses a withdrawal that ends below 1.00.
            vm.expectRevert();
        } else if (hfAfter < required) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hfAfter, required));
        }
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, minHf);
        if (ok && hfAfter >= required) {
            assertEq(lpVault.ownerOf(k2), alice, "withdrawn");
            assertEq(_hf(p), hfAfter, "the measured health factor");
        } else {
            assertEq(lpVault.depositorOf(k2), alice, "still in custody");
        }
    }

    // TEST-237 verifies: SPEC-PROXY-001, REQ-ADAPTER-078, REQ-PROXY-067
    /// @notice The same boundary at a partial removal that leaves debt.
    function testFuzz_TEST_237_removalHealthBoundary(
        uint256 borrowed,
        uint128 units,
        uint256 minHf
    ) public {
        borrowed = bound(borrowed, 1e18, 23_000e18);
        units = uint128(bound(units, 1, UNITS - 1));
        minHf = bound(minHf, 0, 4e18);
        _borrowAs(alice, MARKET_ID, debtReserveId, borrowed);
        uint256 d = _deadline();
        uint256[] memory mins = _mins();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        (bool ok,) = adapter.call(abi.encodeCall(adapterC.removeLiquidity, (MARKET_ID, _ref(k1), units, mins, d, 0)));
        uint256 hfAfter = ok ? _hf(p) : 0;
        vm.revertToState(snap);
        uint256 required = _required(0, minHf);
        if (!ok) {
            vm.expectRevert();
        } else if (hfAfter < required) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hfAfter, required));
        }
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), units, mins, d, minHf);
        if (ok && hfAfter >= required) assertEq(_sharesOf(p, vtReserveId), UNITS + UNITS / 2 - units, "removed");
    }

    // TEST-027 verifies: SPEC-PROXY-001, REQ-PROXY-022, REQ-PROXY-067, INV-025
    /// @notice A borrow passes exactly when the health factor after it reaches `max(1, floor, minHealthFactor)`; a
    /// refused borrow leaves the nonce, the debt and the receiver's balance unchanged.
    function testFuzz_TEST_027_borrowHealthBoundary(
        uint256 amount,
        uint256 floor,
        uint256 minHf
    ) public {
        amount = bound(amount, 1e18, 25_000e18);
        floor = bound(floor, 0, 4e18);
        minHf = bound(minHf, 0, 4e18);
        uint256 d = _deadline();
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        (bool ok,) = adapter.call(abi.encodeCall(adapterC.borrow, (MARKET_ID, debtReserveId, amount, bob, d, 0, 0)));
        uint256 hfAfter = ok ? _hf(p) : 0;
        vm.revertToState(snap);
        rstore.setHardFloor(MARKET_ID, floor);
        uint256 required = _required(floor, minHf);
        if (!ok) {
            vm.expectRevert();
        } else if (hfAfter < required) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hfAfter, required));
        }
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, amount, bob, d, minHf, 0);
        bool passed = ok && hfAfter >= required;
        assertEq(adapterC.borrowNonce(p), passed ? 1 : 0, "nonce");
        assertEq(debt.balanceOf(bob), passed ? amount : 0, "receiver");
        assertEq(_debtOf(p, debtReserveId), passed ? amount : 0, "debt");
    }

    // ─── SPEC-PROXY-002 boundaries ───

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-064
    /// @notice A collateral feed aged at most its `borrowPriceMaxAge` admits a borrow; one second older is refused
    /// with `PriceTooOld(feed, age)`.
    function testFuzz_TEST_019_feedAgeBoundary(
        uint32 age
    ) public {
        age = uint32(bound(age, 0, 2 * uint256(FEED_AGE)));
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        uint64 at = uint64(block.timestamp);
        vm.warp(block.timestamp + age);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        _report(lpOracleA, at);
        if (age > FEED_AGE) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, uint256(age)));
        }
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 1);
        assertEq(adapterC.borrowNonce(p), age > FEED_AGE ? 1 : 2, "nonce");
    }

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-064, REQ-PROXY-018
    /// @notice With USDC debt on the account, a GHO borrow passes exactly when the USDC DebtOracle's served price is
    /// Live and aged at most its `borrowPriceMaxAge()`.
    function testFuzz_TEST_019_debtPriceAgeBoundary(
        uint32 age,
        bool live
    ) public {
        age = uint32(bound(age, 0, 200_000));
        _borrowAs(alice, MARKET_ID, usdcReserveId, 100e6);
        uint256 maxAge = usdcOracle.borrowPriceMaxAge();
        usdcOracle.setReport(live ? PriceState.Live : PriceState.Cached, uint64(block.timestamp - age), true);
        bool passes = live && age <= maxAge;
        if (!passes) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), uint256(age)
                )
            );
        }
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 1);
        assertEq(_debtOf(p, debtReserveId), passes ? 1e18 : 0, "GHO debt");
    }

    // ─── Remaining record ───

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-089, REQ-RISK-070
    // Sources: 2.6 REQ-ADAPTER-078 example (a remainder worth $8 against a $10 minimum)
    /// @notice With debt, a removal leaving a record worth less than `minPledgeUsd` reverts the RiskModule's
    /// `RecordBelowMinPledge(remainingUsd, minPledgeUsd)`; debt-free the same removal needs no minimum.
    function test_TEST_237_remainingRecordMinimum() public {
        rstore.setMinPledge(MARKET_ID, 10e8);
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        uint256 d = _deadline();
        uint256[] memory mins = _mins();
        // 4,000,000 units left at $2.00 per whole token: $8.00.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.RecordBelowMinPledge.selector, 8e8, 10e8));
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), UNITS - 4_000_000, mins, d, 0);
        // $10.00 left passes.
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), UNITS - 5_000_000, mins, d, 0);
        // Debt-free, a $2.00 remainder is fine.
        _fund(alice, debtReserveId, 100e18);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 100e18, true, d);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k2), UNITS / 2 - 1_000_000, mins, d, 0);
        assertEq(_sharesOf(p, vtReserveId), 5_000_000 + 1_000_000, "both remainders");
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-RISK-070
    /// @notice The remaining-record check is exact at its boundary for any minimum.
    function testFuzz_TEST_237_remainingRecordBoundary(
        uint128 keep,
        uint256 minUsd
    ) public {
        keep = uint128(bound(keep, 1, UNITS - 1));
        minUsd = bound(minUsd, 0, 30_000e8);
        rstore.setMinPledge(MARKET_ID, minUsd);
        _borrowAs(alice, MARKET_ID, debtReserveId, 10e18);
        uint256 usd = uint256(keep) * 2e8 / 1e6;
        if (usd < minUsd) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.RecordBelowMinPledge.selector, usd, minUsd));
        }
        uint256 d = _deadline();
        uint256[] memory mins = _mins();
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), UNITS - keep, mins, d, 0);
    }

    // ─── SPEC-PROXY-009: repay with collateral never lowers the health factor ───

    // TEST-239 verifies: SPEC-PROXY-009, REQ-ADAPTER-080, REQ-ADAPTER-091, INV-089
    // Sources: 2.6 SPEC-PROXY-009 lemma (HF' >= HF iff y·A >= a·D)
    /// @notice For any release and repayment, a completed repay with collateral leaves the account debt-free or with a
    /// health factor at least `max(hfBefore, minHealthFactor)`, and the lemma holds: the debt value repaid times the
    /// CF-weighted collateral is at least the CF-weighted value released times the debt (up to Aave's flooring);
    /// a conversion clearly below the lemma's bound is always refused.
    function testFuzz_TEST_239_directionLemma(
        uint256 borrowed,
        uint128 units,
        uint256 flash,
        uint256 minHf
    ) public {
        borrowed = bound(borrowed, 2000e18, 20_000e18);
        units = uint128(bound(units, 1_000_000, UNITS));
        _borrowAs(alice, MARKET_ID, debtReserveId, borrowed);
        flash = bound(flash, 1e18, borrowed);
        minHf = bound(minHf, 0, 3e18);
        // The conversion pays the oracle value of the released units ($2.00 per token), enough for the flash loan.
        uint256 perUnit = 2e12;
        if (uint256(units) * perUnit < flash) perUnit = flash / units + 1;
        swap.setDeleverage(flash, perUnit, 0);
        uint256 hfBefore = _hf(p);
        // A and D in USD, 18 decimals: collateral $30,000 at CF 0.80; GHO at $1.00.
        uint256 a = uint256(units) * 2e12 * 8000 / 10_000; // CF-weighted value released
        uint256 bigA = 24_000e18;
        uint256 bigD = borrowed;
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, units, debtReserveId);
        params.minHealthFactor = minHf;
        uint256 y = flash;
        bool clearlyBelow = y * bigA * 1e9 < a * bigD * (1e9 - 1) && y < bigD;
        vm.prank(alice);
        (bool ok,) = adapter.call(abi.encodeCall(adapterC.repayWithCollateral, (params)));
        if (clearlyBelow) assertFalse(ok, "below the lemma's bound: refused");
        if (ok) {
            if (_borrowCountOf(p) != 0) {
                uint256 hfAfter = _hf(p);
                assertGe(hfAfter, hfBefore > minHf ? hfBefore : minHf, "health factor never falls");
                // y·A ≥ a·D, allowing Aave's floor of both health factors (one part in 1e9).
                assertGe(y * bigA + y * bigA / 1e9, a * bigD, "lemma");
            }
            assertEq(_debtOf(p, debtReserveId), borrowed - y, "repaid exactly the flash amount");
        } else {
            assertEq(_debtOf(p, debtReserveId), borrowed, "a refused call changes nothing");
            assertEq(_sharesOf(p, vtReserveId), UNITS + UNITS / 2, "no units released");
        }
    }

    // TEST-239 verifies: SPEC-PROXY-009, REQ-ADAPTER-091
    /// @notice A conversion strictly below the lemma's bound (much collateral released for little debt repaid) is
    /// refused with `HealthFactorNotImproved` whenever Aave itself allows the release.
    function testFuzz_TEST_239_belowBoundRefused(
        uint128 units,
        uint256 repaid
    ) public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 10_000e18);
        units = uint128(bound(units, 1_000_000_000, 5_000_000_000));
        // a·D = units × $1.60e-6 × 10,000; y·A = repaid × 24,000: keep y below a·D / A / 2.
        uint256 a = uint256(units) * 16e11;
        uint256 limit = a * 10_000 / 24_000 / 2;
        repaid = bound(repaid, 1e18, limit > 1e18 ? limit : 1e18);
        if (repaid * 24_000 >= a * 10_000) return;
        uint256 perUnit = repaid / units + 1;
        swap.setDeleverage(repaid, perUnit, 0);
        uint256 hfBefore = _hf(p);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, units, debtReserveId);
        vm.prank(alice);
        (bool ok, bytes memory err) = adapter.call(abi.encodeCall(adapterC.repayWithCollateral, (params)));
        assertFalse(ok, "refused");
        if (bytes4(err) == IAaveAdapterErrors.HealthFactorNotImproved.selector) {
            (uint256 before,) = abi.decode(_tail(err), (uint256, uint256));
            assertEq(before, hfBefore, "reports the health factor before");
        }
        assertEq(_debtOf(p, debtReserveId), 10_000e18, "nothing changed");
    }

    function _tail(
        bytes memory err
    ) internal pure returns (bytes memory t) {
        t = new bytes(err.length - 4);
        for (uint256 i = 0; i < t.length; ++i) {
            t[i] = err[i + 4];
        }
    }
}
