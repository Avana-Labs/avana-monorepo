// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreChain} from "../../src/policy/parameter-store/IParameterStoreChain.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {ParameterStoreLogics} from "../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {Market} from "../../src/types/Market.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A sequencer-uptime feed whose round read reverts.
contract RevertingRoundFeed {
    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("down");
    }
}

/// @notice Feed definitions (REQ-CONFIG-022, REQ-CONFIG-023, REQ-ORACLE-049): every range of `setFeed` at its
/// edges, the pinned decimals and answer bounds, the capped `maxAnswer`, the borrow age a redefinition keeps, the
/// listing margin re-run at its exact edge, and the full `FeedConfigured` event.
contract ParameterStoreFeedsUnitTest is ParameterStoreFixture {
    MockAggregator internal f;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _deployStore(false);
        _listMarket();
        f = new MockAggregator(8, 1e6, 1e12);
    }

    function _set(
        address feed,
        FeedDef memory d
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setFeed, (feed, d)));
    }

    function _invalid(
        address feed,
        bytes32 check
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, feed, check);
    }

    // ─── Heartbeat, margin, ages, threshold ───

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-050
    function test_TEST_250_heartbeatAtBothEnds() public {
        (bool ok, bytes memory ret) = _set(address(f), _feedDef(0, 1800));
        assertFalse(ok);
        assertEq(ret, oob);
        (ok, ret) = _set(address(f), _feedDef(86_401, 1800));
        assertFalse(ok);
        assertEq(ret, oob);
        (ok,) = _set(address(f), _feedDef(1, 1800));
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).feedMaxAge, 1801);
        (ok,) = _set(address(f), _feedDef(86_400, 1800));
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).feedHeartbeat, 86_400);
    }

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-050, SPEC-ORC-019
    function test_TEST_250_marginAtBothEnds() public {
        (bool ok, bytes memory ret) = _set(address(f), _feedDef(3600, 0));
        assertFalse(ok);
        assertEq(ret, oob);
        (ok, ret) = _set(address(f), _feedDef(3600, 3601));
        assertFalse(ok);
        assertEq(ret, oob);
        (ok,) = _set(address(f), _feedDef(3600, 1));
        assertTrue(ok);
        assertEq(store.heartbeatMargin(address(f)), 1);
        (ok,) = _set(address(f), _feedDef(3600, 3600));
        assertTrue(ok);
        assertEq(store.heartbeatMargin(address(f)), 3600);
        assertEq(store.MAX_HEARTBEAT_MARGIN(), 3600);
        // The longest age a feed can have: 86,400 + 3,600.
        (ok,) = _set(address(f), _feedDef(86_400, 3600));
        assertTrue(ok);
        assertEq(store.liquidationPriceMaxAge(address(f)), 90_000);
    }

    // TEST-250 verifies: REQ-CONFIG-023
    function test_TEST_250_everyAgeMustEqualHeartbeatPlusMargin() public {
        FeedDef memory d = _feedDef(3600, 600);
        d.feedMaxAge = 4199;
        (bool ok, bytes memory ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        d = _feedDef(3600, 600);
        d.feedMaxAge = 4201;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        d = _feedDef(3600, 600);
        d.liquidationPriceMaxAge = 4199;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        d = _feedDef(3600, 600);
        d.liquidationPriceMaxAge = 4201;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        d = _feedDef(3600, 600);
        d.borrowPriceMaxAge = 4199;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        d = _feedDef(3600, 600);
        d.borrowPriceMaxAge = 4201;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        assertEq(store.getFeed(address(f)).feedHeartbeat, 0);
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-CONFIG-050
    function test_TEST_250_deviationThresholdAboveZero() public {
        FeedDef memory d = _feedDef(3600, 600);
        d.feedDeviationThresholdBps = 0;
        (bool ok, bytes memory ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, oob);
        d.feedDeviationThresholdBps = 1;
        d.heartbeatDriftBps = 0;
        (ok,) = _set(address(f), d);
        assertTrue(ok);
        FeedDef memory got = store.getFeed(address(f));
        assertEq(got.feedDeviationThresholdBps, 1);
        assertEq(got.heartbeatDriftBps, 0);
    }

    // ─── Pinned decimals and answer bounds ───

    // TEST-250 verifies: REQ-CONFIG-022
    function test_TEST_250_decimalsAtBothEnds() public {
        f.setBounds(0, 1, 1e12);
        (bool ok, bytes memory ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "decimals"));
        f.setBounds(19, 1e12, 1e30);
        (ok, ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "decimals"));
        f.setBounds(1, 1, 1e12);
        (ok,) = _set(address(f), _feedDef(3600, 600));
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).decimals, 1);
        f.setBounds(18, 1e10, 1e30);
        (ok,) = _set(address(f), _feedDef(3600, 600));
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).decimals, 18);
    }

    // TEST-250 verifies: REQ-CONFIG-022, Q-191
    function test_TEST_250_minAnswerNormalisesToAtLeastOne() public {
        // Non-positive minima.
        f.setBounds(8, 0, 1e12);
        (bool ok, bytes memory ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "minAnswer"));
        f.setBounds(8, -1, 1e12);
        (ok, ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "minAnswer"));
        // 8 decimals: 1 unit is 1e-8 USD, normalised 1.
        f.setBounds(8, 1, 1e12);
        (ok,) = _set(address(f), _feedDef(3600, 600));
        assertTrue(ok);
        // 6 decimals scale up: 1 unit normalises to 100.
        f.setBounds(6, 1, 1e12);
        (ok,) = _set(address(f), _feedDef(3600, 600));
        assertTrue(ok);
        // 9 decimals: 9 units floor to 0, 10 units to 1.
        f.setBounds(9, 9, 1e12);
        (ok, ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "minAnswer"));
        f.setBounds(9, 10, 1e12);
        (ok,) = _set(address(f), _feedDef(3600, 600));
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).minAnswer, 10);
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-ORACLE-049
    function test_TEST_250_maxAnswerPinnedBelowTheCap() public {
        // Aggregator bound below the cap: the aggregator bound is pinned.
        FeedDef memory d = _feedDef(3600, 600);
        d.maxAnswerCap = 1e13;
        (bool ok,) = _set(address(f), d);
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).maxAnswer, 1e12);
        assertEq(store.getFeed(address(f)).maxAnswerCap, 1e13);
        // Equal: either.
        d.maxAnswerCap = 1e12;
        (ok,) = _set(address(f), d);
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).maxAnswer, 1e12);
        // Cap below the aggregator bound: the cap is pinned.
        d.maxAnswerCap = 1e6 + 1;
        (ok,) = _set(address(f), d);
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).maxAnswer, 1e6 + 1);
        // A cap at or below the minimum leaves no valid answer.
        d.maxAnswerCap = 1e6;
        bytes memory ret;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "maxAnswer"));
        d.maxAnswerCap = -1;
        (ok, ret) = _set(address(f), d);
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "maxAnswer"));
        // An aggregator whose own maximum is not above its minimum.
        f.setBounds(8, 1e6, 1e6);
        (ok, ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "maxAnswer"));
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-CONFIG-023
    function test_TEST_250_rangeChecksBeforeAggregatorReads() public {
        // A definition out of range is refused before any aggregator read, even for a broken aggregator.
        f.setBounds(0, 0, 0);
        (bool ok, bytes memory ret) = _set(address(f), _feedDef(0, 600));
        assertFalse(ok);
        assertEq(ret, oob);
        // Decimals before the minimum, the minimum before the maximum.
        (ok, ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "decimals"));
        f.setBounds(8, 0, 0);
        (ok, ret) = _set(address(f), _feedDef(3600, 600));
        assertFalse(ok);
        assertEq(ret, _invalid(address(f), "minAnswer"));
    }

    // TEST-250 verifies: REQ-CONFIG-022
    function test_TEST_250_feedWithoutCodeIsRefused() public {
        address eoa = makeAddr("eoaFeed");
        vm.prank(address(timelock));
        (bool ok,) = address(store).call(abi.encodeCall(store.setFeed, (eoa, _feedDef(3600, 600))));
        assertFalse(ok);
        assertEq(store.getFeed(eoa).feedHeartbeat, 0);
    }

    // ─── Redefinition keeps a tightened borrow age ───

    // TEST-250 verifies: REQ-CONFIG-023, SPEC-ORC-019, Q-182
    function test_TEST_250_redefinitionTakesTheLowerBorrowAge() public {
        address u = address(fUsdc);
        // An untightened feed whose heartbeat shrinks follows the new formula.
        (bool ok,) = _set(u, _feedDef(3600, 600));
        assertTrue(ok);
        assertEq(store.borrowPriceMaxAge(u), 4200);
        assertEq(store.liquidationPriceMaxAge(u), 4200);
        // A longer heartbeat later: the stored 4,200 is below 88,200 and is kept.
        (ok,) = _set(u, _feedDef(86_400, 1800));
        assertTrue(ok);
        assertEq(store.borrowPriceMaxAge(u), 4200);
        assertEq(store.liquidationPriceMaxAge(u), 88_200);
        // Only the structural borrow setter raises it again.
        _tl();
        store.setBorrowPriceMaxAge(u, 88_200);
        assertEq(store.borrowPriceMaxAge(u), 88_200);
    }

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-072
    function test_TEST_250_feedConfiguredCarriesThePinnedValues() public {
        FeedDef memory d = _feedDef(3600, 600);
        d.feedDeviationThresholdBps = 40;
        d.heartbeatDriftBps = 15;
        d.maxAnswerCap = 5e11;
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.FeedConfigured(address(f), 8, 1e6, 5e11, 3600, 600, 4200, 40, 15, 4200, 4200);
        store.setFeed(address(f), d);
        // An age setter emits the whole definition again with its new value.
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.FeedConfigured(address(f), 8, 1e6, 5e11, 3600, 600, 4200, 40, 15, 100, 4200);
        store.setBorrowPriceMaxAge(address(f), 100);
    }

    // ─── Listing margin re-run at its exact edge ───

    // TEST-064 verifies: SPEC-CF-004, REQ-PSTORE-004, REQ-PSTORE-009
    function test_TEST_064_feedRaiseRefusedAtTheMarginEdge() public {
        // Tolerances wide enough for large thresholds; CF 9,999 for both tokens and a pool factor of 4,000 give a
        // margin of 10,000 − ⌊9,999 × 4,000 / 10,000⌋ = 6,001 bps. Each route must stay strictly below it.
        vm.startPrank(address(timelock));
        store.setFeedAgreementToleranceBps(usdc, 10_000);
        store.setFeedAgreementToleranceBps(usdt, 10_000);
        store.setTokenCollateralFactorBps(usdc, 9999);
        store.setTokenCollateralFactorBps(usdt, 9999);
        vm.stopPrank();
        FeedDef memory d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = 3000;
        d.heartbeatDriftBps = 3000;
        (bool ok,) = _set(address(fUsdc), d);
        assertTrue(ok, "6,000 < 6,001 refused");
        d.heartbeatDriftBps = 3001;
        bytes memory ret;
        (ok, ret) = _set(address(fUsdc), d);
        assertFalse(ok, "6,001 >= 6,001 accepted");
        assertEq(ret, oob);
        // A lowering never re-runs the margin.
        d.heartbeatDriftBps = 0;
        (ok,) = _set(address(fUsdc), d);
        assertTrue(ok);
        assertEq(store.getFeed(address(fUsdc)).heartbeatDriftBps, 0);
    }
}

/// @notice The sequencer-uptime check on an L2 (REQ-PSTORE-023) at every edge of its feed and grace rules.
contract ParameterStoreFeedsSequencerUnitTest is ParameterStoreFixture {
    MockAggregator internal seq;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _deployStore(true);
        seq = new MockAggregator(0, 0, 0);
        seq.setRound(0, 1_000_000);
    }

    function _set(
        address feed,
        uint32 grace
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setSequencer, (feed, grace)));
    }

    function _invalid(
        address feed
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreChain.InvalidSequencerFeed.selector, feed);
    }

    // TEST-250 verifies: REQ-PSTORE-023, REQ-CONFIG-050
    function test_TEST_250_l2GraceAtBothEnds() public {
        (bool ok, bytes memory ret) = _set(address(seq), 599);
        assertFalse(ok);
        assertEq(ret, oob);
        (ok, ret) = _set(address(seq), 7201);
        assertFalse(ok);
        assertEq(ret, oob);
        (ok, ret) = _set(address(seq), 0);
        assertFalse(ok);
        assertEq(ret, oob);
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreChain.SequencerSet(address(seq), 600);
        store.setSequencer(address(seq), 600);
        (ok,) = _set(address(seq), 7200);
        assertTrue(ok);
        (address feed, uint32 grace) = store.sequencer();
        assertEq(feed, address(seq));
        assertEq(grace, 7200);
    }

    // TEST-250 verifies: REQ-PSTORE-023, REQ-ORACLE-099
    function test_TEST_250_l2FeedAnswerAndStart() public {
        // Up (0) and down (1) are both valid statuses.
        seq.setRound(1, 1);
        (bool ok,) = _set(address(seq), 3600);
        assertTrue(ok);
        seq.setRound(0, 1);
        (ok,) = _set(address(seq), 3600);
        assertTrue(ok);
        int256[3] memory bad = [int256(2), -1, type(int256).max];
        for (uint256 i = 0; i < bad.length; ++i) {
            seq.setRound(bad[i], 1);
            bytes memory ret;
            (ok, ret) = _set(address(seq), 3600);
            assertFalse(ok);
            assertEq(ret, _invalid(address(seq)));
        }
        seq.setRound(0, 0);
        (bool done, bytes memory r) = _set(address(seq), 3600);
        assertFalse(done);
        assertEq(r, _invalid(address(seq)));
    }

    // TEST-250 verifies: REQ-PSTORE-023
    function test_TEST_250_l2FeedMustHoldCodeAndAnswer() public {
        (bool ok, bytes memory ret) = _set(address(0), 3600);
        assertFalse(ok);
        assertEq(ret, _invalid(address(0)));
        RevertingRoundFeed broken = new RevertingRoundFeed();
        (ok, ret) = _set(address(broken), 3600);
        assertFalse(ok);
        assertEq(ret, _invalid(address(broken)));
        // A contract without the round read at all.
        (ok, ret) = _set(address(registry), 3600);
        assertFalse(ok);
        assertEq(ret, _invalid(address(registry)));
        // The feed is checked before the grace period.
        (ok, ret) = _set(address(broken), 0);
        assertFalse(ok);
        assertEq(ret, _invalid(address(broken)));
        (address feed,) = store.sequencer();
        assertEq(feed, address(0));
    }

    // TEST-250 verifies: REQ-PSTORE-023, REQ-PSTORE-009
    function test_TEST_250_l2SequencerReachesEveryLpOracle() public {
        // On an L2 the sequencer check comes before any TWAP window (REQ-PSTORE-034).
        (bool ok,) = _set(address(seq), 3600);
        assertTrue(ok);
        _listMarket();
        uint256[] memory w = store.getOracleInputs(address(lpOracle), new address[](0), false);
        assertEq(w[8], uint160(address(seq)));
        assertEq(w[9], 3600);
        lpOracle.setFailed(1);
        bytes memory ret;
        (ok, ret) = _set(address(seq), 1800);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), 1));
        (, uint32 grace) = store.sequencer();
        assertEq(grace, 3600);
    }

    // TEST-250 verifies: REQ-PSTORE-023
    function test_TEST_250_l2InitializeLeavesTheCheckEmpty() public view {
        (address feed, uint32 grace) = store.sequencer();
        assertEq(feed, address(0));
        assertEq(grace, 0);
    }
}

/// @notice `twapMinObservations` and the observation-buffer checks of REQ-PSTORE-027 on a 2-second chain and a
/// 12-second chain, at the edge of each.
contract ParameterStoreFeedsTwapUnitTest is ParameterStoreFixture {
    IParameterStore internal base;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);

    function setUp() public {
        _deployStore(false);
        _listMarket();
        base = _storeWithBlockTime(2);
        MockAggregator seq = new MockAggregator(0, 0, 0);
        seq.setRound(0, 1);
        vm.startPrank(address(timelock));
        // The 2-second chain has a sequencer: its grace period bounds every window (REQ-PSTORE-034).
        base.setSequencer(address(seq), 3600);
        base.setTokenCollateralFactorBps(usdc, 7800);
        base.setTokenCollateralFactorBps(usdt, 7500);
        vm.stopPrank();
    }

    function _storeWithBlockTime(
        uint32 blockTime
    ) internal returns (IParameterStore s) {
        address tl = address(timelock);
        address reg = address(registry);
        ParameterStoreLogics memory l = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(tl, reg, blockTime, true)),
            loosen: address(new ParameterStoreLoosenLogic(tl, reg, blockTime, true)),
            listing: address(new ParameterStoreListingLogic(tl, reg, blockTime, true)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(tl, reg, blockTime, true)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(tl, reg, blockTime, true))
        });
        ParameterStore impl = new ParameterStore(tl, reg, blockTime, true, l);
        s = IParameterStore(
            address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(IParameterStoreAdmin.initialize, (tl, _launchGlobals(), 0, 10_000))
                )
            )
        );
    }

    function _list(
        IParameterStore s,
        uint32 window
    ) internal returns (bool ok, bytes memory ret) {
        MarketParams memory p = _launchMarketParams();
        p.twapWindow = window;
        vm.prank(address(timelock));
        (ok, ret) = address(s).call(abi.encodeCall(s.setInitialMarketParams, (M, p)));
    }

    // TEST-250 verifies: REQ-PSTORE-027, SPEC-ORC-022, Q-326
    function test_TEST_250_baseNeedsNineHundredOneSlots() public {
        assertEq(base.CHAIN_BLOCK_TIME(), 2);
        pool.setCardinality(900);
        (bool ok, bytes memory ret) = _list(base, 1800);
        assertFalse(ok);
        assertEq(ret, oob);
        pool.setCardinality(901);
        (ok,) = _list(base, 1800);
        assertTrue(ok);
        assertEq(base.twapMinObservations(M), 901);
        // The same pool on the 12-second chain needs 151.
        assertEq(store.twapMinObservations(M), 151);
        pool.setCardinality(150);
        (ok, ret) = _list(store, 1800);
        assertFalse(ok);
        assertEq(ret, oob);
        pool.setCardinality(151);
        (ok,) = _list(store, 1800);
        assertTrue(ok);
    }

    // TEST-250 verifies: REQ-PSTORE-027
    function test_TEST_250_observationCountRoundsUp() public {
        pool.setCardinality(type(uint16).max);
        uint32[6] memory windows = [uint32(1), 12, 13, 24, 25, 3600];
        uint16[6] memory expected = [uint16(2), 2, 3, 3, 4, 301];
        for (uint256 i = 0; i < windows.length; ++i) {
            vm.prank(address(timelock));
            store.setTwapWindow(M, windows[i]);
            assertEq(store.twapMinObservations(M), expected[i], "12 s chain");
            vm.prank(address(timelock));
            base.setTwapWindow(M, windows[i]);
            assertEq(base.twapMinObservations(M), (windows[i] + 1) / 2 + 1, "2 s chain");
        }
    }

    // TEST-250 verifies: REQ-PSTORE-027, REQ-CONFIG-050
    function test_TEST_250_windowNeedingMoreThanSixtyFiveThousandSlotsRefused() public {
        pool.setCardinality(type(uint16).max);
        // ⌈786,408 / 12⌉ + 1 = 65,535 slots: the largest count a pool can hold.
        vm.prank(address(timelock));
        store.setTwapWindow(M, 786_408);
        assertEq(store.twapMinObservations(M), type(uint16).max);
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(abi.encodeCall(store.setTwapWindow, (M, 786_409)));
        assertFalse(ok);
        assertEq(ret, oob);
        assertEq(store.getMarketParams(M).twapWindow, 786_408);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-027
    function test_TEST_250_noTwapProtocolTakesWindowZeroOnly() public {
        integration.set(false, true, false, ShapeKind.TickRange);
        (bool ok, bytes memory ret) = _list(store, 1800);
        assertFalse(ok);
        assertEq(ret, oob);
        (ok,) = _list(store, 0);
        assertTrue(ok);
        assertEq(store.twapMinObservations(M), 0);
        // A protocol with a time-weighted price needs a window.
        integration.set(true, true, false, ShapeKind.TickRange);
        (ok, ret) = _list(store, 0);
        assertFalse(ok);
        assertEq(ret, oob);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-027
    function test_TEST_250_cardinalityReadOnlyForTickRangePools() public {
        pool.setCardinality(1);
        // Another shape reads no slot0: only the integration's depth read gates the window.
        integration.set(true, true, false, ShapeKind.FullPool);
        (bool ok,) = _list(store, 1800);
        assertTrue(ok);
        // A tick-range market without a pool address reads none either.
        integration.set(true, true, false, ShapeKind.TickRange);
        Market memory m = registry.getMarket(M);
        m.pool = address(0);
        registry.setMarket(M, m);
        (ok,) = _list(store, 1800);
        assertTrue(ok);
    }

    // TEST-250 verifies: REQ-PSTORE-004, SPEC-ORC-022
    function test_TEST_250_depthReadMustSucceedAndReportDepth() public {
        integration.set(true, false, false, ShapeKind.TickRange);
        (bool ok, bytes memory ret) = _list(store, 1800);
        assertFalse(ok);
        assertEq(ret, oob);
        integration.set(true, true, true, ShapeKind.TickRange);
        (ok, ret) = _list(store, 1800);
        assertFalse(ok);
        assertEq(ret, oob);
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setTwapWindow, (M, 1800)));
        assertFalse(ok);
        assertEq(ret, oob);
    }
}
