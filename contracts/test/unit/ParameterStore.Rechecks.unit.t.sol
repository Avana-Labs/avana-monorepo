// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {Market} from "../../src/types/MarketTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The re-checks a change runs at execution: the SPEC-CF-004 margin re-run, the feed bound cap and a kept
/// borrow age.
contract ParameterStoreRechecksUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
        _listMarket();
    }

    function _withDeviation(
        uint16 deviation,
        uint16 drift
    ) internal pure returns (FeedDef memory d) {
        d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = deviation;
        d.heartbeatDriftBps = drift;
    }

    // TEST-064 verifies: SPEC-CF-004, REQ-CONFIG-019, REQ-CONFIG-020, REQ-PSTORE-004
    function test_TEST_064_collateralFactorRaiseRerunsListingMargin() public {
        // fUsdcAlt at 25 + 6,875 = 6,900 bps of route error; CF_LP = ⌊7,500 × 4,000 / 10⁴⌋ = 3,000 leaves 7,000.
        _tl();
        store.setFeed(address(fUsdcAlt), _withDeviation(25, 6875));
        // USDT at 7,800: CF_LP = ⌊7,800 × 4,000 / 10⁴⌋ = 3,120, margin 6,880 ≤ 6,900: refused.
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
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
        // Margin 7,000 (CF_LP 3,000). An alternate feed at 25 + 6,975 = 7,000 is refused, though the alternate is not
        // the route the LPOracle values with.
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setFeed(address(fUsdcAlt), _withDeviation(25, 6975));
        _tl();
        store.setFeed(address(fUsdcAlt), _withDeviation(25, 6974));
        assertEq(store.getFeed(address(fUsdcAlt)).heartbeatDriftBps, 6974);
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
        emit IParameterStoreBase.FeedConfigured(
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
            abi.encodeWithSelector(IParameterStoreBase.InvalidFeed.selector, address(sentinel), bytes32("maxAnswer"))
        );
        store.setFeed(address(sentinel), d);
    }

    // TEST-064 verifies: REQ-PSTORE-016, REQ-RISK-044
    function test_TEST_064_breakerTighteningNeedsARecordedHub() public {
        address stranger = makeAddr("strangerHub");
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownHub.selector, stranger));
        store.tightenDeficitMax(stranger, gho, 1);
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
            assertTrue(logs[i].topics[0] != IParameterStoreBase.CapLoosened.selector, "a lowering emitted CapLoosened");
            if (logs[i].topics[0] == IParameterStoreBase.CapTightened.selector) ++tightened;
        }
        // Only the cap moved (the slice is unchanged).
        assertEq(tightened, 1);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreBase.CapLoosened("marketUsdCap", bytes32(M), 4_000_000e8, 6_000_000e8, governor);
        store.setInitialMarketCaps(M, 6_000_000e8, 500_000e8, 1e8);
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
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
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
        registry.setToken(dai, _one(address(fUsdt)), _one(address(fUsdtAlt)));
        Market memory m = registry.getMarket(M);
        m.tokens[1] = dai;
        m.lpOracle = makeAddr("lpOracle2");
        registry.setMarket(2, m);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setInitialMarketParams(2, _defaultMarketParams());
    }

    // TEST-225 verifies: SPEC-CAP-006, REQ-RISK-044
    function test_TEST_225_addCapUsesTheBookedSlice() public {
        _activate();
        // S above the slice: the bound is (max(cap, R) + max(slice, S)) / floor = (5,000,000 + 900,000) / 1.
        collateralization.setUsed(0, 900_000e8);
        hub.setAddCap(5_899_999);
        _tl();
        vm.expectRevert(IParameterStoreBase.AddCapTooSmall.selector);
        store.loosenTopUpSliceUsd(M, 600_000e8);
        hub.setAddCap(5_900_000);
        _tl();
        store.loosenTopUpSliceUsd(M, 600_000e8);
        assertEq(store.topUpSliceUsd(M), 600_000e8);
    }
}
