// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreChain} from "../../src/policy/parameter-store/IParameterStoreChain.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {Market} from "../../src/types/Market.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {
    MockAggregator,
    MockLPOracle,
    OracleConfigReader,
    OracleConfigSummary
} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Listing setters, feed definitions, the time-weighted checks and the oracle configuration view.
contract ParameterStoreListingUnitTest is ParameterStoreFixture {
    OracleConfigReader internal reader = new OracleConfigReader();

    function setUp() public {
        _deployStore(false);
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-CONFIG-023, SPEC-ORC-019, Q-322
    function test_TEST_250_setFeedPinsAndDerivesAges() public {
        address f = address(fUsdc);
        // With no tolerance written, the token's tolerance is below its lower bound and the feed is refused.
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeed(f, _feedDef(86_400, 1800));
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 150);
        _tl();
        store.setFeed(f, _feedDef(86_400, 1800));
        FeedDef memory d = store.getFeed(f);
        assertEq(d.decimals, 8);
        assertEq(d.minAnswer, 1e6);
        assertEq(d.maxAnswer, 1e12);
        assertEq(d.feedMaxAge, 88_200);
        assertEq(store.borrowPriceMaxAge(f), 88_200);
        assertEq(store.liquidationPriceMaxAge(f), 88_200);
        assertEq(store.heartbeatMargin(f), 1800);
        FeedDef memory bad = _feedDef(86_400, 1800);
        bad.borrowPriceMaxAge = 4200;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeed(f, bad);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeed(f, _feedDef(86_401, 1800));
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeed(f, _feedDef(86_400, 3601));
    }

    // TEST-250 verifies: REQ-CONFIG-022, Q-191
    function test_TEST_250_setFeedRejectsMinAnswerNormalisingToZero() public {
        MockAggregator f18 = new MockAggregator(18, 1e9, 1e30);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, address(f18), bytes32("minAnswer"))
        );
        store.setFeed(address(f18), _feedDef(3600, 600));
        f18.setBounds(18, 1e10, 1e30);
        _tl();
        store.setFeed(address(f18), _feedDef(3600, 600));
        assertEq(store.getFeed(address(f18)).feedMaxAge, 4200);
        f18.setBounds(19, 1e10, 1e30);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, address(f18), bytes32("decimals"))
        );
        store.setFeed(address(f18), _feedDef(3600, 600));
        f18.setBounds(18, 1e10, 1e10);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, address(f18), bytes32("maxAnswer"))
        );
        store.setFeed(address(f18), _feedDef(3600, 600));
    }

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-052, REQ-PSTORE-009
    function test_TEST_250_feedAgeSetters() public {
        _listMarket();
        address f = address(fUsdc);
        _tl();
        store.setBorrowPriceMaxAge(f, 1000);
        _tl();
        store.setBorrowPriceMaxAge(f, 88_200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setBorrowPriceMaxAge(f, 88_201);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setLiquidationPriceMaxAge(f, 88_199);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setLiquidationPriceMaxAge(f, 88_201);
        _tl();
        store.setLiquidationPriceMaxAge(f, 88_200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeedMaxAge(f, 88_199);
        _tl();
        store.setFeedMaxAge(f, 88_200);
        lpOracle.setFailed(1);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 1)
        );
        store.setBorrowPriceMaxAge(f, 1000);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-CONFIG-052
    function test_TEST_250_setFeedKeepsToleranceBound() public {
        _listMarket();
        FeedDef memory wide = _feedDef(86_400, 1800);
        wide.feedDeviationThresholdBps = 76; // 76 + 25 + 50 = 151 > 150
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeed(address(fUsdc), wide);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeedAgreementMarginBps(101);
        _tl();
        store.setFeedAgreementMarginBps(100);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-005, REQ-PSTORE-012, REQ-PSTORE-027, REQ-CONFIG-041, SPEC-ORC-022
    function test_TEST_250_initialMarketParams() public {
        _listMarket();
        assertEq(store.twapMinObservations(M), 151);
        MarketParams memory p = store.getMarketParams(M);
        assertEq(p.minPledgeUsd, 10e8);
        assertEq(p.hardHealthFloor, 0);
        // The pool's buffer must hold 151 observations.
        pool.setCardinality(150);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketParams(M, _launchMarketParams());
        pool.setCardinality(151);
        integration.set(true, false, false, ShapeKind.TickRange);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketParams(M, _launchMarketParams());
        integration.set(true, true, true, ShapeKind.TickRange);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketParams(M, _launchMarketParams());
        // An AMM protocol without a time-weighted price takes only twapWindow = 0.
        integration.set(false, true, false, ShapeKind.FullPool);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketParams(M, _launchMarketParams());
        MarketParams memory noTwap = _launchMarketParams();
        noTwap.twapWindow = 0;
        _tl();
        store.setInitialMarketParams(M, noTwap);
        assertEq(store.twapMinObservations(M), 0);
        _activate();
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotInListing.selector);
        store.setInitialMarketParams(M, noTwap);
    }

    // TEST-250 verifies: REQ-PSTORE-004, SPEC-CF-004, REQ-CONFIG-015, REQ-CONFIG-020
    function test_TEST_250_initialMarketParamsBounds() public {
        _listMarket();
        MarketParams memory p = _launchMarketParams();
        p.consistencyToleranceBps = 9;
        _initialParamsRevert(p, IParameterStoreErrors.LivenessBound.selector);
        p = _launchMarketParams();
        p.slippageAllowanceBps = 29;
        _initialParamsRevert(p, IParameterStoreErrors.LivenessBound.selector);
        p = _launchMarketParams();
        p.poolRiskFactor = 4001;
        _initialParamsRevert(p, IParameterStoreErrors.OutOfBounds.selector);
        p = _launchMarketParams();
        p.minPledgeUsd = 100_000e8 + 1;
        _initialParamsRevert(p, IParameterStoreErrors.OutOfBounds.selector);
        p = _launchMarketParams();
        p.hardHealthFloor = 0.99e18;
        _initialParamsRevert(p, IParameterStoreErrors.OutOfBounds.selector);
        // Listing margin: CF_LP = ⌊7,500 × 4,000 / 10⁴⌋ = 3,000; 10⁴ − 3,000 = 7,000 > 50 for every route. A route
        // of deviation + drift ≥ margin is refused, both when the market's parameters are written and, once they are,
        // when a feed change thins the margin (setFeed re-runs SPEC-CF-004 for the market).
        FeedDef memory wide = _feedDef(86_400, 1800);
        wide.feedDeviationThresholdBps = 25;
        wide.heartbeatDriftBps = 6975; // 25 + 6,975 = 7,000 ≥ 7,000
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeed(address(fUsdcAlt), wide);
        // A market whose parameters are not written yet has no margin to re-run: the feed change passes, and
        // setInitialMarketParams then refuses the factor that leaves no margin.
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(new MockLPOracle());
        registry.setMarket(2, m);
        _tl();
        store.setFeedAgreementToleranceBps(usdt, 150);
        vm.prank(address(timelock));
        store.setPoolRiskFactor(M, 1);
        // Market 1 now leaves a margin of 10⁴ − ⌊7,500 / 10⁴⌋ = 10,000, so the feed change passes for it.
        _tl();
        store.setFeed(address(fUsdcAlt), wide);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketParams(2, _launchMarketParams());
        p = _launchMarketParams();
        p.poolRiskFactor = 3999; // CF_LP 2,999: margin 7,001 > 7,000
        _tl();
        store.setInitialMarketParams(2, p);
    }

    function _initialParamsRevert(
        MarketParams memory p,
        bytes4 err
    ) internal {
        _tl();
        vm.expectRevert(err);
        store.setInitialMarketParams(M, p);
    }

    // TEST-272 verifies: REQ-RISK-041, REQ-PSTORE-012, REQ-PSTORE-026, REQ-RISK-044, REQ-ACCESS-135
    function test_TEST_272_initialCaps() public {
        _listMarket();
        assertEq(store.marketUsdCap(M), 5_000_000e8);
        assertEq(store.topUpSliceUsd(M), 500_000e8);
        assertEq(store.stressFloorUsd(M), 1e8);
        assertEq(store.depositorUsdCap(address(hub)), 1_000_000e8);
        address h = address(hub);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotInListing.selector);
        store.setInitialHubCaps(h, 1);
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotInListing.selector);
        store.setInitialTokenCap(h, usdc, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, alice));
        store.setInitialTokenCap(h, alice, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, bob));
        store.setInitialTokenCap(bob, usdt, 1);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setInitialMarketCaps(M, 1e8, 2e8, 1e8);
        _activate();
        _tl();
        vm.expectRevert(IParameterStoreErrors.NotInListing.selector);
        store.setInitialMarketCaps(M, 1e8, 0, 1e8);
    }

    // TEST-272 verifies: REQ-RISK-045, SPEC-CAP-006
    function test_TEST_272_stressFloor() public {
        _listMarket();
        _activate();
        // Lowering: (5M + 0.5M) / $0.50 = 11M tokens > addCap 10M.
        _tl();
        vm.expectRevert(IParameterStoreErrors.AddCapTooSmall.selector);
        store.setStressFloorUsd(M, 0.5e8);
        _tl();
        store.setStressFloorUsd(M, 0.6e8);
        vaultToken.setSupply(1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.SupplyNotZero.selector, M));
        store.setStressFloorUsd(M, 1e8);
        vaultToken.setSupply(0);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.StressFloorSet(M, 0.6e8, 1e8);
        store.setStressFloorUsd(M, 1e8);
    }

    // TEST-250 verifies: REQ-CONFIG-072, REQ-PSTORE-011, REQ-PSTORE-029
    function test_TEST_250_oracleConfigView() public {
        _listMarket();
        OracleConfigSummary memory c = _summary(address(lpOracle));
        assertEq(c.marketId, M);
        assertEq(c.tokenCount, 2);
        assertEq(c.token0, usdc);
        assertEq(c.legCount00, 1);
        assertEq(c.aggregator00, address(fUsdc));
        assertEq(c.heartbeat00, 86_400);
        assertEq(c.margin00, 1800);
        assertEq(c.borrowAge00, 88_200);
        assertEq(c.tolerance0, 150);
        assertEq(c.twapWindow, 1800);
        assertEq(c.twapMinObservations, 151);
        assertEq(c.consistencyToleranceBps, 50);
        assertEq(c.maxQuoteChangeBps, 100);
        assertEq(c.usdBandLow, 0.9e8);
        assertEq(c.cachedWindow, 3600);
        assertEq(c.graceDuration, 1800);
        OracleConfigSummary memory none = _summary(alice);
        assertEq(none.marketId, 0);
        assertEq(none.tokenCount, 0);
    }

    // TEST-250 verifies: REQ-CONFIG-072
    function test_TEST_250_legBoundsSaturate() public {
        MockAggregator big = new MockAggregator(8, 1, type(int192).max);
        registry.setActiveRoutes(usdc, _one(address(big)), _one(address(fUsdcAlt)));
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 150);
        _tl();
        store.setFeed(address(big), _feedDef(3600, 600));
        assertEq(_summary(address(lpOracle)).maxAnswer00, type(int128).max);
        assertEq(store.getFeed(address(big)).maxAnswer, type(int192).max);
        // A three-leg route is returned unusable.
        address[] memory three = new address[](3);
        registry.setActiveRoutes(usdt, three, three);
        assertEq(_summary(address(lpOracle)).legCount10, 0);
    }

    // TEST-250 verifies: REQ-PSTORE-027, SPEC-ORC-022, Q-326
    function test_TEST_250_twapWindowSetter() public {
        _listMarket();
        pool.setCardinality(1000);
        _tl();
        store.setTwapWindow(M, 3600);
        assertEq(store.twapMinObservations(M), 301);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setTwapWindow(M, 0);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setTwapWindow(M, 12_000);
    }

    // TEST-250 verifies: REQ-PSTORE-023, Q-324
    function test_TEST_250_ethereumSequencerIsEmpty() public {
        assertEq(store.CHAIN_BLOCK_TIME(), 12);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreChain.InvalidSequencerFeed.selector, address(fUsdc)));
        store.setSequencer(address(fUsdc), 3600);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSequencer(address(0), 1);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreChain.SequencerSet(address(0), 0);
        store.setSequencer(address(0), 0);
    }

    // TEST-273 verifies: REQ-PSTORE-032, Q-391
    function test_TEST_273_coverageRatio() public {
        assertEq(store.coverageRatioBps(), 0);
        _tl();
        store.setCoverageRatioBps(2000);
        assertEq(store.coverageRatioBps(), 2000);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setCoverageRatioBps(10_001);
    }

    // TEST-249 verifies: REQ-PSTORE-022, Q-270
    function test_TEST_249_liquidationExpectations() public {
        address s = address(spoke);
        _tl();
        store.setLiquidationExpectations(s, 1.1e18, 200);
        assertEq(store.aaveTargetHealthFactor(s), 1.1e18);
        assertEq(store.minLiquidationBonus(s), 200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setLiquidationExpectations(s, 1e18, 200);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setLiquidationExpectations(s, 1.1e18, 199);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownSpoke.selector, alice));
        store.setLiquidationExpectations(alice, 1.1e18, 200);
    }

    function _summary(
        address lp
    ) internal returns (OracleConfigSummary memory) {
        (bool ok, bytes memory raw) = address(store).staticcall(abi.encodeCall(store.getOracleConfig, (lp)));
        require(ok, "getOracleConfig");
        (bool done, bytes memory out) = address(reader).call(bytes.concat(OracleConfigReader.summary.selector, raw));
        require(done, "summary");
        return abi.decode(out, (OracleConfigSummary));
    }

    // TEST-250 verifies: REQ-PSTORE-011
    function test_TEST_250_unknownMarketIsRefused() public {
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.UnknownMarket.selector, 2));
        store.setTwapWindow(2, 1800);
        assertEq(uint8(registry.getMarket(2).status), uint8(MarketStatus.None));
    }
}

/// @notice The sequencer-uptime check on a chain with an L2 sequencer.
contract ParameterStoreSequencerUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(true);
    }

    // TEST-250 verifies: REQ-PSTORE-023, REQ-ORACLE-099, Q-324
    function test_TEST_250_l2SequencerFeed() public {
        MockAggregator seq = new MockAggregator(0, 0, 0);
        seq.setRound(0, 1_000_000);
        _tl();
        store.setSequencer(address(seq), 3600);
        (address feed, uint32 grace) = store.sequencer();
        assertEq(feed, address(seq));
        assertEq(grace, 3600);

        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSequencer(address(seq), 599);
        seq.setRound(2, 1_000_000);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreChain.InvalidSequencerFeed.selector, address(seq)));
        store.setSequencer(address(seq), 3600);
        seq.setRound(1, 0);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreChain.InvalidSequencerFeed.selector, address(seq)));
        store.setSequencer(address(seq), 3600);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreChain.InvalidSequencerFeed.selector, alice));
        store.setSequencer(alice, 3600);
    }
}
