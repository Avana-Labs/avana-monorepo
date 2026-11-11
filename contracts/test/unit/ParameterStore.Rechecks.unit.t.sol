// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {Market} from "../../src/types/Market.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The re-checks a change runs at execution: the tolerance bound over every route the standby can replace,
/// tighten setters that revert only on checks their own write breaks, the SPEC-CF-004 margin re-run, the feed bound
/// cap and a kept borrow age.
contract ParameterStoreRechecksUnitTest is ParameterStoreFixture {
    MockAggregator internal fStandby;

    function setUp() public {
        _deployStore(false);
        fStandby = new MockAggregator(8, 1e6, 1e12);
        // USDC's routes: primary fUsdc, alternate fUsdcAlt, standby fStandby (each 25 bps deviation once defined).
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), _one(address(fStandby)));
        _listMarket();
        _tl();
        store.setFeed(address(fStandby), _feedDef(86_400, 1800));
    }

    function _withDeviation(
        uint16 deviation,
        uint16 drift
    ) internal pure returns (FeedDef memory d) {
        d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = deviation;
        d.heartbeatDriftBps = drift;
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-CONFIG-052, REQ-PSTORE-009, REQ-MREG-027
    function test_TEST_250_standbyFeedChangeKeepsToleranceBound() public {
        // max(25 + 25, 25 + 25, 25 + 25) + 50 = 100 with every route at 25 bps.
        assertEq(store.feedAgreementToleranceMinBps(usdc), 100);
        // A standby feed of 120 bps would need max(50, 145, 145) + 50 = 195 once a guardian puts it in either slot:
        // the change is refused although the standby is not in force, so no switch can leave USDC below its bound.
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeed(address(fStandby), _withDeviation(120, 25));
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 195);
        _tl();
        store.setFeed(address(fStandby), _withDeviation(120, 25));
        assertEq(store.feedAgreementToleranceMinBps(usdc), 195);
        // With the standby in place of the primary, the short-delay setters still run.
        registry.setActiveRoutes(usdc, _one(address(fStandby)), _one(address(fUsdcAlt)));
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenFeedAgreementToleranceBps(usdc, 194);
        _tl();
        store.tightenBorrowPriceMaxAge(address(fStandby), 80_000);
        _tl();
        store.tightenConsistencyToleranceBps(M, 40);
        assertEq(store.getFeed(address(fStandby)).borrowPriceMaxAge, 80_000);
    }

    // TEST-064 verifies: REQ-CONFIG-051, REQ-CONFIG-024, REQ-PSTORE-009, SPEC-GOV-011
    function test_TEST_064_tighteningIgnoresABoundItDidNotBreak() public {
        // A wide feed is defined while no token uses it, then recorded as USDC's standby: USDC's tolerance (150) is now
        // below its bound, max(50, 425, 425) + 50 = 475, through no ParameterStore change.
        MockAggregator wide = new MockAggregator(8, 1e6, 1e12);
        _tl();
        store.setFeed(address(wide), _withDeviation(400, 25));
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), _one(address(wide)));
        assertEq(store.feedAgreementToleranceMinBps(usdc), 475);
        // Tightenings that cannot move the bound still run.
        _tl();
        store.tightenBorrowPriceMaxAge(address(fUsdc), 80_000);
        _tl();
        store.tightenConsistencyToleranceBps(M, 40);
        // A tolerance tightening below the bound is refused: the lower value is its own doing.
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenFeedAgreementToleranceBps(usdc, 140);
        // A structural feed change keeps the full check.
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeed(address(fUsdc), _feedDef(86_400, 1800));
    }

    // TEST-064 verifies: REQ-CONFIG-051, REQ-PSTORE-009, REQ-PSTORE-013, SPEC-GOV-011
    function test_TEST_064_tighteningRevertsOnlyForChecksItBreaks() public {
        // checkConfig fails check 8 below a tolerance of 145: lowering 150 to 140 breaks it.
        lpOracle.setFloors(0, 145, 0);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 8)
        );
        store.tightenFeedAgreementToleranceBps(usdc, 140);
        // checkConfig fails check 16 below a borrow age of 80,000 s: lowering 88,200 to 70,000 breaks it.
        lpOracle.setFloors(0, 0, 80_000);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 16)
        );
        store.tightenBorrowPriceMaxAge(address(fUsdc), 70_000);
        // Check 4 failing before and after is not the tightenings' doing.
        lpOracle.setFloors(0, 0, 0);
        lpOracle.setFailed(4);
        _tl();
        store.tightenFeedAgreementToleranceBps(usdc, 140);
        _tl();
        store.tightenBorrowPriceMaxAge(address(fUsdc), 70_000);
        assertEq(store.feedAgreementToleranceBps(usdc), 140);
        assertEq(store.borrowPriceMaxAge(address(fUsdc)), 70_000);
        // The structural setters keep the full check.
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 4)
        );
        store.setFeedAgreementToleranceBps(usdc, 150);
    }

    // TEST-064 verifies: SPEC-CF-004, REQ-CONFIG-019, REQ-CONFIG-020, REQ-PSTORE-004
    function test_TEST_064_collateralFactorRaiseRerunsListingMargin() public {
        // fUsdcAlt at 25 + 6,875 = 6,900 bps of route error; CF_LP = ⌊7,500 × 4,000 / 10⁴⌋ = 3,000 leaves 7,000.
        _tl();
        store.setFeed(address(fUsdcAlt), _withDeviation(25, 6875));
        // USDT at 7,800: CF_LP = ⌊7,800 × 4,000 / 10⁴⌋ = 3,120, margin 6,880 ≤ 6,900: refused.
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setTokenCollateralFactorBps(usdt, 7800);
        // 7,600: CF_LP 3,040, margin 6,960 > 6,900: accepted.
        _tl();
        store.setTokenCollateralFactorBps(usdt, 7600);
        assertEq(store.tokenCollateralFactorBps(usdt), 7600);
        // A lower factor only widens the margin and is not re-checked.
        _tl();
        store.setTokenCollateralFactorBps(usdc, 7000);
        assertEq(store.tokenCollateralFactorBps(usdc), 7000);
    }

    // TEST-064 verifies: SPEC-CF-004, REQ-PSTORE-009, REQ-PSTORE-004
    function test_TEST_064_feedChangeRerunsListingMarginOnEveryRoute() public {
        // Margin 7,000 (CF_LP 3,000). A standby feed at 25 + 6,975 = 7,000 is refused, though the standby is not in
        // force: a guardian can put it in either slot at once.
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 150);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeed(address(fStandby), _withDeviation(25, 6975));
        _tl();
        store.setFeed(address(fStandby), _withDeviation(25, 6974));
        assertEq(store.getFeed(address(fStandby)).heartbeatDriftBps, 6974);
    }

    // TEST-250 verifies: REQ-CONFIG-023, SPEC-ORC-019, Q-182
    function test_TEST_250_setFeedKeepsATightenedBorrowAge() public {
        _tl();
        store.tightenBorrowPriceMaxAge(address(fUsdc), 50_000);
        // Re-entering the same definition does not undo the incident tightening.
        _tl();
        store.setFeed(address(fUsdc), _feedDef(86_400, 1800));
        FeedDef memory d = store.getFeed(address(fUsdc));
        assertEq(d.borrowPriceMaxAge, 50_000);
        assertEq(d.feedMaxAge, 88_200);
        assertEq(d.liquidationPriceMaxAge, 88_200);
        // A definition whose own age is shorter takes that age.
        _tl();
        store.setFeed(address(fUsdc), _feedDef(3600, 1800));
        assertEq(store.getFeed(address(fUsdc)).borrowPriceMaxAge, 5400);
        // Only the structural setter raises it again.
        _tl();
        store.setBorrowPriceMaxAge(address(fUsdc), 5400);
        _tl();
        store.setFeed(address(fUsdc), _feedDef(86_400, 1800));
        assertEq(store.getFeed(address(fUsdc)).borrowPriceMaxAge, 5400);
        _tl();
        store.setBorrowPriceMaxAge(address(fUsdc), 88_200);
        assertEq(store.getFeed(address(fUsdc)).borrowPriceMaxAge, 88_200);
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-ORACLE-049, REQ-CONFIG-072
    function test_TEST_250_setFeedPinsTheCappedMaxAnswer() public {
        // An aggregator with a sentinel bound: 2^176 - 1 does not fit int192's positive range, so use int192 max.
        MockAggregator sentinel = new MockAggregator(8, 1e6, type(int192).max);
        FeedDef memory d = _feedDef(86_400, 1800);
        d.maxAnswerCap = 1e12;
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.FeedConfigured(
            address(sentinel), 8, 1e6, 1e12, 86_400, 1800, 88_200, 25, 25, 88_200, 88_200
        );
        store.setFeed(address(sentinel), d);
        assertEq(store.getFeed(address(sentinel)).maxAnswer, 1e12);
        assertEq(store.getFeed(address(sentinel)).maxAnswerCap, 1e12);
        // The aggregator's own bound wins when it is lower.
        d.maxAnswerCap = 1e15;
        _tl();
        store.setFeed(address(fUsdcAlt), d);
        assertEq(store.getFeed(address(fUsdcAlt)).maxAnswer, 1e12);
        // A cap at or below minAnswer leaves no valid answer.
        d.maxAnswerCap = 1e6;
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, address(sentinel), bytes32("maxAnswer"))
        );
        store.setFeed(address(sentinel), d);
    }

    // TEST-064 verifies: REQ-PSTORE-016, REQ-RISK-044
    function test_TEST_064_breakerTighteningNeedsARecordedHub() public {
        address stranger = makeAddr("strangerHub");
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, stranger));
        store.tightenBreakerDeficitMax(stranger, gho, 1);
    }

    // TEST-272 verifies: REQ-RISK-041, REQ-RISK-042, REQ-RISK-043
    function test_TEST_272_initialCapsEmitTheirDirection() public {
        // The market is still Registered: a second initial write lowers the cap and the slice and raises nothing.
        vm.recordLogs();
        _tl();
        store.setInitialMarketCaps(M, 4_000_000e8, 500_000e8, 1e8);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 tightened = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != IParameterStoreEvents.CapLoosened.selector, "a lowering emitted CapLoosened"
            );
            if (logs[i].topics[0] == IParameterStoreEvents.CapTightened.selector) ++tightened;
        }
        // Only the cap moved (the slice is unchanged).
        assertEq(tightened, 1);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapLoosened("marketUsdCap", bytes32(M), 4_000_000e8, 6_000_000e8, address(timelock));
        store.setInitialMarketCaps(M, 6_000_000e8, 500_000e8, 1e8);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-CONFIG-052, REQ-MREG-027
    function testFuzz_TEST_250_toleranceBoundCoversEveryStandbySwitch(
        uint16 p,
        uint16 a,
        uint16 sb
    ) public {
        p = uint16(bound(p, 1, 3000));
        a = uint16(bound(a, 1, 3000));
        sb = uint16(bound(sb, 1, 3000));
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 10_000);
        _tl();
        store.setFeed(address(fUsdc), _withDeviation(p, 25));
        _tl();
        store.setFeed(address(fUsdcAlt), _withDeviation(a, 25));
        _tl();
        store.setFeed(address(fStandby), _withDeviation(sb, 25));
        uint256 pair = uint256(p) + a;
        if (uint256(sb) + a > pair) pair = uint256(sb) + a;
        if (uint256(p) + sb > pair) pair = uint256(p) + sb;
        assertEq(store.feedAgreementToleranceMinBps(usdc), pair + 50);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-MREG-027
    function test_TEST_250_toleranceBoundWithStandbyInPlaceOfAlternate() public {
        // Primary 40, alternate 25, standby 120: the standby replacing the alternate is the widest pair, 40 + 120.
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 300);
        _tl();
        store.setFeed(address(fUsdc), _withDeviation(40, 25));
        _tl();
        store.setFeed(address(fStandby), _withDeviation(120, 25));
        assertEq(store.feedAgreementToleranceMinBps(usdc), 40 + 120 + 50);
    }

    // TEST-064 verifies: SPEC-CF-004, REQ-CONFIG-015, REQ-PSTORE-004
    function test_TEST_064_poolRiskFactorRaiseRerunsListingMargin() public {
        _tl();
        store.setFeed(address(fUsdcAlt), _withDeviation(25, 6875)); // route error 6,900
        _tl();
        store.setPoolRiskFactor(M, 1000);
        // At factor 1,000 the margin is wide: CF_LP = ⌊7,800 × 1,000 / 10⁴⌋ = 780.
        _tl();
        store.setTokenCollateralFactorBps(usdt, 7800);
        // Back to 4,000: CF_LP 3,120, margin 6,880 ≤ 6,900.
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setPoolRiskFactor(M, 4000);
        _tl();
        store.setPoolRiskFactor(M, 3900); // CF_LP 3,042, margin 6,958 > 6,900
        assertEq(store.getMarketParams(M).poolRiskFactor, 3900);
    }

    // TEST-064 verifies: SPEC-CF-004, REQ-CONFIG-019
    function test_TEST_064_marginRerunSkipsMarketsNoLongerConfigured() public {
        _tl();
        store.setFeed(address(fUsdcAlt), _withDeviation(25, 6875));
        // A cancelled market's LPOracle reads no configuration: its margin is not re-run.
        registry.setStatus(M, MarketStatus.Cancelled);
        _tl();
        store.setTokenCollateralFactorBps(usdt, 7800);
        assertEq(store.tokenCollateralFactorBps(usdt), 7800);
    }

    // TEST-250 verifies: REQ-PSTORE-004, SPEC-CF-004, REQ-CONFIG-019
    function test_TEST_250_initialParamsNeedEveryCollateralFactor() public {
        address dai = makeAddr("DAI");
        registry.setToken(dai, _one(address(fUsdt)), _one(address(fUsdtAlt)), new address[](0));
        Market memory m = registry.getMarket(M);
        m.tokens[1] = dai;
        m.lpOracle = makeAddr("lpOracle2");
        registry.setMarket(2, m);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketParams(2, _launchMarketParams());
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-013, REQ-CONFIG-054
    function test_TEST_250_structuralSetterKeepsTheFullCheck() public {
        lpOracle.setFailed(4);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 4)
        );
        store.setConsistencyToleranceBps(M, 60);
    }

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044
    function test_TEST_225_addCapUsesTheBookedSlice() public {
        _activate();
        // S above the slice: the bound is (max(cap, R) + max(slice, S)) / floor = (5,000,000 + 900,000) / 1.
        collateralization.setUsed(0, 900_000e8);
        hub.setAddCap(5_899_999);
        _tl();
        vm.expectRevert(IParameterStoreErrors.AddCapTooSmall.selector);
        store.loosenTopUpSliceUsd(M, 600_000e8);
        hub.setAddCap(5_900_000);
        _tl();
        store.loosenTopUpSliceUsd(M, 600_000e8);
        assertEq(store.topUpSliceUsd(M), 600_000e8);
    }
}
