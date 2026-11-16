// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPreviewUnitTest
/// @notice Borrow and repay-all previews against the real Aave V4 Spoke and the real Collateralization: every gate and
/// the inclusion margins. The re-credit and repay-with-collateral previews are in `Lens.PreviewCollateral.unit.t.sol`
/// (one contract held both until the IR pipeline failed to assemble it).
/// forge-config: default.isolate = false
contract LensPreviewUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // ─── previewBorrowMax / previewBorrowRecommended ───

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, REQ-LENS-041, Q-398
    function test_TEST_247_borrowMaxAndRecommendedWithoutDebt() public view {
        uint256 w = _weighted(aliceProxy);
        assertEq(w, 16_000e26, "$20,000 at CF 80 %");
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(max, Math.mulDiv(w, 1e18, 1.005e18) / 1e8, "16,000 / 1.005 GHO at a zero rate");
        assertEq(rec, Math.mulDiv(w, 1e18, 1.1e18) / 1e8, "16,000 / 1.10 GHO");
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), max, "same maximum");
        assertLt(rec, max, "recommended below the maximum");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-041
    function test_TEST_247_borrowMaxExecutesAtDeadline() public {
        _borrow(aliceProxy, 3000e18);
        uint256 deadline = block.timestamp + 1200;
        uint256 amount = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        vm.warp(deadline);
        _borrow(aliceProxy, amount);
        assertGe(_hf(aliceProxy), 1e18, "the max borrow lands at or above HF 1.00");
        assertLt(_hf(aliceProxy), 1.006e18, "and close to the 1.005 margin");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-041
    function test_TEST_247_borrowMaxUsdcUnits() public view {
        uint256 amount = lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp);
        uint256 w = _weighted(aliceProxy);
        assertEq(amount, Math.mulDiv(w, 1e18, 1.005e18) / (0.9999e8 * 1e12), "USDC base units at $0.9999");
        assertGt(amount, 0, "no minimum zeroes a capacity");
    }

    // TEST-247 verifies: REQ-LENS-035
    function test_TEST_247_borrowMaxRateGrowsTarget() public {
        _borrow(aliceProxy, 8000e18);
        uint256 now_ = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        uint256 later = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp + 365 days);
        assertLt(later, now_, "a later deadline needs a higher health factor");
        uint256 past = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp - 100);
        assertEq(past, now_, "a deadline in the past counts no time");
    }

    // TEST-247 verifies: REQ-LENS-035
    function test_TEST_247_borrowMaxUsesTheHighestRateOfTheAccount() public {
        _borrowUsdc(aliceProxy, 1000e6);
        uint256 deadline = block.timestamp + 365 days;
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", ghoAssetId), abi.encode(0));
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", usdcAssetId), abi.encode(0));
        uint256 flat = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", usdcAssetId), abi.encode(0.5e27));
        uint256 steep = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, deadline);
        assertLt(steep, flat, "the USDC debt's 50 % rate sets the target, though GHO is borrowed at 0 %");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-035
    /// @dev No debt yet: the borrowed reserve's own rate, the only one in the account, sets the target health factor.
    function test_TEST_247_borrowMaxUsesTheBorrowedReserveRateWithoutDebt() public {
        uint256 deadline = block.timestamp + 365 days;
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", usdcAssetId), abi.encode(0));
        uint256 flat = lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, deadline);
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", usdcAssetId), abi.encode(0.5e27));
        uint256 steep = lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, deadline);
        assertEq(flat, Math.mulDiv(_weighted(aliceProxy), 1e18, 1.005e18) / (0.9999e8 * 1e12), "zero rate: H0 x 1.005");
        assertLt(steep, flat, "the borrowed reserve's 50 % rate raises the target");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-035, Q-398
    function test_TEST_247_borrowMaxHardFloor() public {
        store.setHardHealthFloor(MARKET_ID, 1.2e18);
        uint256 w = _weighted(aliceProxy);
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(max, Math.mulDiv(w, 1e18, 1.206e18) / 1e8, "H0 = 1.20 x 1.005");
        assertEq(rec, max, "recommended never above the maximum");
        store.setHardHealthFloor(MARKET_ID, 0.5e18);
        assertEq(
            lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp),
            Math.mulDiv(w, 1e18, 1.005e18) / 1e8,
            "a floor below 1.00 never lowers Aave's threshold"
        );
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-019
    function test_TEST_247_borrowMaxCappedByDrawHeadroom() public {
        _borrow(aliceProxy, 500e18);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 1000);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 500e18, "1,000 cap - 500");
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 400);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "cap reached");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-044, SPEC-CF-005, Q-253
    function test_TEST_247_borrowMaxExcludesRescueUnits() public {
        uint256 before = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        riskModule.setRescue(true);
        _open(alice, aliceProxy, 2, 5000e6);
        uint256 after_ = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertApproxEqAbs(after_, before, 1e9, "rescue units add no borrowing capacity");
        assertGt(_weighted(aliceProxy), 16_000e26, "Aave counts them");
    }

    /// @notice The Lens applies the AaveAdapter's own pause and freeze gates and the RiskModule's `checkBorrowGate` (the
    /// mock refuses with a refused status or a debt breaker on the reserve).
    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-060
    function test_TEST_247_borrowGateClosedReturnsZero() public {
        rm.setGate(aliceProxy, false, false, PauseState.None);
        _assertBorrowZero("the RiskModule's gate refuses");
        rm.setGate(aliceProxy, true, false, PauseState.None);
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        _assertBorrowZero("Frozen");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        _assertBorrowZero("Paused");
        reg.setPause(aave.hub, PauseState.None, PauseReason.None);
        reg.setFrozen(alice, true);
        _assertBorrowZero("frozen wallet");
        reg.setFrozen(alice, false);
        rm.setDebtBreaker(aave.cdpSpoke, debtReserveId, 32, type(uint64).max);
        _assertBorrowZero("debt breaker on the reserve");
        assertGt(lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp), 0, "the other reserve");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-008
    function test_TEST_247_borrowUndeployedProxyIsZero() public view {
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(bob, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec + max, 0, "no account yet");
    }

    // TEST-247 verifies: REQ-LENS-035, REQ-LENS-032
    function test_TEST_247_borrowUnknownReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 99));
        lens.previewBorrowMax(alice, MARKET_ID, 99, block.timestamp);
    }

    /// @notice A reserve funded by another Hub: the AaveAdapter refuses the borrow unless that Hub is in None too, and
    /// so does the preview (the cross-Hub line itself is the RiskModule's gate, `checkBorrowGate`).
    // TEST-247 verifies: REQ-LENS-035, REQ-RISK-082
    function test_TEST_247_borrowFundingHubPauseGate() public {
        address hub2 = makeAddr("fundingHub2");
        vm.etch(hub2, hex"00");
        DebtReserveDef memory d = reg.getDebtReserve(aave.cdpSpoke, debtReserveId);
        d.fundingHub = hub2;
        reg.setDebtReserve(aave.cdpSpoke, d);
        vm.mockCall(hub2, abi.encodeWithSignature("getAssetDrawnRate(uint256)"), abi.encode(0));
        vm.mockCall(
            hub2,
            abi.encodeWithSignature("getSpokeConfig(uint256,address)"),
            abi.encode(0, type(uint40).max, 0, true, false)
        );
        reg.setPause(hub2, PauseState.Paused, PauseReason.General);
        _assertBorrowZero("funding Hub paused");
        reg.setPause(hub2, PauseState.None, PauseReason.None);
        assertGt(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "every gate passes");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-044
    function test_TEST_247_recommendedZeroWhenAboveTarget() public {
        _borrow(aliceProxy, 15_000e18);
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec, 0, "HF 1.067 is below 1.10: no recommended borrow");
        assertEq(max, Math.mulDiv(_weighted(aliceProxy), 1e18, 1.005e18) / 1e8 - 15_000e18, "maximum still");
    }

    // ─── quoteRepayAll ───

    // TEST-248 verifies: REQ-LENS-036, Q-269
    function test_TEST_248_repayAllAtTheBlock() public {
        _borrow(aliceProxy, 10_000e18);
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        assertEq(
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp),
            Math.mulDiv(total, 10_010, 10_000, Math.Rounding.Ceil),
            "debt x 1.001, rounded up"
        );
    }

    // TEST-248 verifies: REQ-LENS-036, Q-269
    function test_TEST_248_repayAllCoversDebtAtDeadline() public {
        _borrow(aliceProxy, 10_000e18);
        _borrowUsdc(aliceProxy, 2000e6);
        uint256 deadline = block.timestamp + 30 days;
        uint256 ghoQuote = lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, deadline);
        uint256 usdcQuote = lens.quoteRepayAll(alice, MARKET_ID, usdcReserveId, deadline);
        uint256 rate = _drawnRate(ghoAssetId);
        uint256 rp = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).riskPremium;
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        uint256 growth = RAY
            + Math.mulDiv(Math.mulDiv(rate, 1e4 + rp, 1e4, Math.Rounding.Ceil), 30 days, 365 days, Math.Rounding.Ceil);
        assertEq(ghoQuote, Math.mulDiv(total, growth * 10_010, RAY * 1e4, Math.Rounding.Ceil), "formula");
        vm.warp(deadline);
        assertGe(ghoQuote, _debtOf(aliceProxy, debtReserveId), "covers the GHO debt at the deadline");
        assertGe(usdcQuote, _debtOf(aliceProxy, usdcReserveId), "covers the USDC debt at the deadline");
    }

    // TEST-248 verifies: REQ-LENS-036
    function test_TEST_248_repayAllZeroCases() public {
        assertEq(lens.quoteRepayAll(bob, MARKET_ID, debtReserveId, block.timestamp), 0, "no proxy");
        assertEq(lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "no debt");
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 42));
        lens.quoteRepayAll(alice, MARKET_ID, 42, block.timestamp);
    }

    // TEST-248 verifies: REQ-LENS-036
    function test_TEST_248_repayAllDeadlineInPast() public {
        _borrow(aliceProxy, 10_000e18);
        assertEq(
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, 1),
            lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp),
            "no negative time"
        );
    }

    // ─── helpers ───

    function _weighted(
        address proxy
    ) internal view returns (uint256) {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy);
        return Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, 1e18);
    }

    function _drawnRate(
        uint256 assetId
    ) internal view returns (uint256 rate) {
        (bool ok, bytes memory data) =
            aave.hub.staticcall(abi.encodeWithSignature("getAssetDrawnRate(uint256)", assetId));
        require(ok, "rate");
        rate = abi.decode(data, (uint256));
    }

    function _assertBorrowZero(
        string memory why
    ) internal view {
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec, 0, why);
        assertEq(max, 0, why);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, why);
    }
}
