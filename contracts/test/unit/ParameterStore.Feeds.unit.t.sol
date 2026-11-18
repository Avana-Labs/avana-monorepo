// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Feed definitions (REQ-CONFIG-022, REQ-CONFIG-023, REQ-ORACLE-049): every range of `setFeed` at its
/// edges, the pinned decimals and answer bounds, the capped `maxAnswer`, the borrow age a redefinition keeps, the
/// listing margin re-run at its exact edge, and the full `FeedConfigured` event.
contract ParameterStoreFeedsUnitTest is ParameterStoreFixture {
    MockAggregator internal f;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreBase.OutOfBounds.selector);

    function setUp() public {
        _deployStore();
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
        return abi.encodeWithSelector(IParameterStoreBase.InvalidFeed.selector, feed, check);
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

    /// @notice The smallest accepted `minAnswer` is `10^(decimals − 8)` above 8 decimals and 1 at 8 or fewer (the
    /// normalised minimum ⌊minAnswer × 10⁸ / 10^decimals⌋ is then 1): one unit below is refused by name, the
    /// threshold itself is pinned. Kills `<` → `<=` and a dropped or shifted decimals branch.
    // TEST-250 verifies: REQ-CONFIG-022
    function test_TEST_250_minAnswerThresholdAtEachDecimals() public {
        uint8[4] memory decs = [uint8(6), 8, 9, 18];
        // 10^(decimals − 8) above 8 decimals; 1 at 8 decimals or fewer.
        int192[4] memory threshold = [int192(1), 1, 10, 1e10];
        for (uint256 i = 0; i < decs.length; ++i) {
            f.setBounds(decs[i], threshold[i] - 1, 1e30);
            (bool ok, bytes memory ret) = _set(address(f), _feedDef(3600, 600));
            assertFalse(ok, "one below the threshold refused");
            assertEq(ret, _invalid(address(f), "minAnswer"));
            f.setBounds(decs[i], threshold[i], 1e30);
            (ok,) = _set(address(f), _feedDef(3600, 600));
            assertTrue(ok, "threshold accepted");
            assertEq(store.getFeed(address(f)).decimals, decs[i]);
            assertEq(store.getFeed(address(f)).minAnswer, threshold[i]);
        }
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
        emit IParameterStoreBase.FeedConfigured(address(f), 8, 1e6, 5e11, 3600, 600, 4200, 40, 15, 4200, 4200);
        store.setFeed(address(f), d);
        // An age setter emits the whole definition again with its new value.
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreBase.FeedConfigured(address(f), 8, 1e6, 5e11, 3600, 600, 4200, 40, 15, 100, 4200);
        store.setBorrowPriceMaxAge(address(f), 100);
    }

    // ─── Listing margin re-run at its exact edge ───

    // TEST-064 verifies: SPEC-CF-004, REQ-PSTORE-004, REQ-PSTORE-009
    function test_TEST_064_feedRaiseRefusedAtTheMarginEdge() public {
        // CF 9,999 for both tokens and a pool factor of 4,000 give a margin of 10,000 − ⌊9,999 × 4,000 / 10,000⌋ =
        // 6,001 bps. Each route must stay strictly below it.
        vm.startPrank(address(timelock));
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
