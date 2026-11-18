// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {FeedDef, MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {Market} from "../../src/types/MarketTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, MockLPOracle} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Listing setters and feed definitions.
contract ParameterStoreListingUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-CONFIG-023, SPEC-ORC-019, Q-322
    function test_TEST_250_setFeedPinsAndDerivesAges() public {
        address f = address(fUsdc);
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
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setFeed(f, bad);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setFeed(f, _feedDef(86_401, 1800));
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setFeed(f, _feedDef(86_400, 3601));
    }

    // TEST-250 verifies: REQ-CONFIG-022, Q-191
    function test_TEST_250_setFeedRejectsMinAnswerNormalisingToZero() public {
        MockAggregator f18 = new MockAggregator(18, 1e9, 1e30);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreBase.InvalidFeed.selector, address(f18), bytes32("minAnswer"))
        );
        store.setFeed(address(f18), _feedDef(3600, 600));
        f18.setBounds(18, 1e10, 1e30);
        _tl();
        store.setFeed(address(f18), _feedDef(3600, 600));
        assertEq(store.getFeed(address(f18)).feedMaxAge, 4200);
        f18.setBounds(19, 1e10, 1e30);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreBase.InvalidFeed.selector, address(f18), bytes32("decimals"))
        );
        store.setFeed(address(f18), _feedDef(3600, 600));
        f18.setBounds(18, 1e10, 1e10);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreBase.InvalidFeed.selector, address(f18), bytes32("maxAnswer"))
        );
        store.setFeed(address(f18), _feedDef(3600, 600));
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-005, REQ-PSTORE-012, REQ-PSTORE-027, REQ-CONFIG-041, SPEC-ORC-022
    function test_TEST_250_initialMarketParams() public {
        _listMarket();
        MarketParams memory p = store.getMarketParams(M);
        assertEq(p.slippageAllowanceBps, 100);
        assertEq(p.slippageAllowanceMinBps, 30);
        assertEq(p.poolRiskFactor, 4000);
        assertEq(p.minPledgeUsd, 10e8);
        _activate();
        _tl();
        vm.expectRevert(IParameterStoreBase.NotInListing.selector);
        store.setInitialMarketParams(M, p);
    }

    // TEST-250 verifies: REQ-PSTORE-004, SPEC-CF-004, REQ-CONFIG-015, REQ-CONFIG-020
    function test_TEST_250_initialMarketParamsBounds() public {
        _listMarket();
        MarketParams memory p = _defaultMarketParams();
        p.slippageAllowanceBps = 29;
        _initialParamsRevert(p, IParameterStoreBase.LivenessBound.selector);
        p = _defaultMarketParams();
        p.poolRiskFactor = 9001;
        _initialParamsRevert(p, IParameterStoreBase.OutOfBounds.selector);
        p = _defaultMarketParams();
        p.minPledgeUsd = 100_000e8 + 1;
        _initialParamsRevert(p, IParameterStoreBase.OutOfBounds.selector);
        // Listing margin: CF_LP = ⌊7,500 × 4,000 / 10⁴⌋ = 3,000; 10⁴ − 3,000 = 7,000 > 50 for every route. A route
        // of deviation + drift ≥ margin is refused, both when the market's parameters are written and, once they are,
        // when a feed change thins the margin (setFeed re-runs SPEC-CF-004 for the market).
        FeedDef memory wide = _feedDef(86_400, 1800);
        wide.feedDeviationThresholdBps = 25;
        wide.heartbeatDriftBps = 6975; // 25 + 6,975 = 7,000 ≥ 7,000
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setFeed(address(fUsdcAlt), wide);
        // A market whose parameters are not written yet has no margin to re-run: the feed change passes, and
        // setInitialMarketParams then refuses the factor that leaves no margin.
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(new MockLPOracle());
        registry.setMarket(2, m);
        vm.prank(address(timelock));
        store.setPoolRiskFactor(M, 1);
        // Market 1 now leaves a margin of 10⁴ − ⌊7,500 / 10⁴⌋ = 10,000, so the feed change passes for it.
        _tl();
        store.setFeed(address(fUsdcAlt), wide);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setInitialMarketParams(2, _defaultMarketParams());
        p = _defaultMarketParams();
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
        address h = address(hub);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotInListing.selector);
        store.setInitialTokenCap(h, usdc, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.TokenNotListed.selector, alice));
        store.setInitialTokenCap(h, alice, 1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownHub.selector, bob));
        store.setInitialTokenCap(bob, usdt, 1);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setInitialMarketCaps(M, 1e8, 2e8, 1e8);
        _activate();
        _tl();
        vm.expectRevert(IParameterStoreBase.NotInListing.selector);
        store.setInitialMarketCaps(M, 1e8, 0, 1e8);
    }

    // TEST-272 verifies: REQ-PSTORE-026, REQ-PSTORE-017, REQ-RISK-042, REQ-PSTORE-012
    /// @notice A cap tightened to 0 cannot be written again by its initial setter: a token cap stays set and an active
    /// market is out of listing, so either reopens only by the $1,000 base and then the 1.5x steps.
    function test_TEST_272_zeroCapsReopenOnlyByTheSteps() public {
        _listMarket();
        address h = address(hub);
        _tl();
        store.tightenTokenUsdCap(h, usdc, 0);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotInListing.selector);
        store.setInitialTokenCap(h, usdc, 20_000_000e8);
        bytes memory tokenStep = abi.encodeWithSelector(
            IParameterStoreBase.LoosenStepTooLarge.selector,
            keccak256(abi.encode(bytes32("tokenUsdCap"), _pairKey(h, usdc)))
        );
        _tl();
        vm.expectRevert(tokenStep);
        store.loosenTokenUsdCap(h, usdc, 1000e8 + 1);
        _tl();
        store.loosenTokenUsdCap(h, usdc, 1000e8);
        assertEq(store.tokenUsdCap(h, usdc), 1000e8, "token cap reopened to the base");

        _activate();
        _tl();
        store.tightenMarketUsdCap(M, 0);
        _tl();
        vm.expectRevert(IParameterStoreBase.NotInListing.selector);
        store.setInitialMarketCaps(M, 5_000_000e8, 0, 1e8);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(
                IParameterStoreBase.LoosenStepTooLarge.selector,
                keccak256(abi.encode(bytes32("marketUsdCap"), bytes32(M)))
            )
        );
        store.loosenMarketUsdCap(M, 1000e8 + 1);
        _tl();
        store.loosenMarketUsdCap(M, 1000e8);
        assertEq(store.marketUsdCap(M), 1000e8, "market cap reopened to the base");
    }

    function _pairKey(
        address h,
        address token
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(h, token));
    }

    // TEST-272 verifies: REQ-RISK-045, SPEC-CAP-006
    function test_TEST_272_stressFloor() public {
        _listMarket();
        _activate();
        // Lowering: (5M + 0.5M) / $0.50 = 11M tokens > addCap 10M.
        _tl();
        vm.expectRevert(IParameterStoreBase.AddCapTooSmall.selector);
        store.setStressFloorUsd(M, 0.5e8);
        _tl();
        store.setStressFloorUsd(M, 0.6e8);
        vaultToken.setSupply(1);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.SupplyNotZero.selector, M));
        store.setStressFloorUsd(M, 1e8);
        vaultToken.setSupply(0);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreBase.StressFloorSet(M, 0.6e8, 1e8);
        store.setStressFloorUsd(M, 1e8);
    }

    // TEST-273 verifies: REQ-PSTORE-032, Q-391
    function test_TEST_273_coverageRatio() public {
        assertEq(store.coverageRatioBps(), 0);
        _tl();
        store.setCoverageRatioBps(2000);
        assertEq(store.coverageRatioBps(), 2000);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
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
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setLiquidationExpectations(s, 1e18, 200);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setLiquidationExpectations(s, 1.1e18, 199);
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownSpoke.selector, alice));
        store.setLiquidationExpectations(alice, 1.1e18, 200);
    }

    // TEST-250 verifies: REQ-PSTORE-011
    function test_TEST_250_unknownMarketIsRefused() public {
        _tl();
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.UnknownMarket.selector, 2));
        store.setPoolRiskFactor(2, 1000);
        assertEq(uint8(registry.getMarket(2).status), uint8(MarketStatus.None));
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-ORACLE-049
    /// @notice An 18-decimal feed whose minimum normalises above 1 (minAnswer 1e11, above 10^10) is pinned.
    function test_TEST_250_eighteenDecimalFeedAboveNormalisedMinimum() public {
        MockAggregator f18 = new MockAggregator(18, 1e11, 1e30);
        vm.prank(address(timelock));
        store.setFeed(address(f18), _feedDef(86_400, 1800));
        FeedDef memory d = store.getFeed(address(f18));
        assertEq(d.decimals, 18);
        assertEq(d.minAnswer, 1e11);
    }
}
