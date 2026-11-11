// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, MockPriceSource} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice The worked examples of 2.9, run as written on the real store: each number in an example is an
/// assertion here.
contract ParameterStoreExamplesUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _def(
        uint32 heartbeat,
        uint32 margin,
        uint16 dev
    ) internal pure returns (FeedDef memory d) {
        d = _feedDef(heartbeat, margin);
        d.feedDeviationThresholdBps = dev;
        d.heartbeatDriftBps = 0;
    }

    // TEST-250 verifies: REQ-CONFIG-024
    function test_TEST_250_toleranceExampleWithATwoLegAlternate() public {
        // USDC primary 25 bps, alternate USDC/ETH 100 × ETH/USD 50, standby 25, margin 50:
        // max(25 + 150, 25 + 150, 25 + 25) + 50 = 225.
        address token = makeAddr("USDC-example");
        MockAggregator p = new MockAggregator(8, 1e6, 1e12);
        MockAggregator a0 = new MockAggregator(8, 1e6, 1e12);
        MockAggregator a1 = new MockAggregator(8, 1e6, 1e12);
        MockAggregator s = new MockAggregator(8, 1e6, 1e12);
        address[] memory alt = new address[](2);
        (alt[0], alt[1]) = (address(a0), address(a1));
        registry.setToken(token, _one(address(p)), alt, _one(address(s)));
        vm.startPrank(address(timelock));
        store.setFeed(address(p), _def(86_400, 1800, 25));
        store.setFeed(address(a0), _def(86_400, 1800, 100));
        store.setFeed(address(a1), _def(3600, 600, 50));
        store.setFeed(address(s), _def(86_400, 1800, 25));
        vm.stopPrank();
        assertEq(store.feedAgreementToleranceMinBps(token), 225);
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeedAgreementToleranceBps(token, 224);
        _tl();
        store.setFeedAgreementToleranceBps(token, 225);
        assertEq(store.feedAgreementToleranceBps(token), 225);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-MREG-027
    function test_TEST_250_toleranceExampleWithAWideStandby() public {
        // Primary 25, alternate 25, standby 120: max(50, 145, 145) + 50 = 195 > the stored 150, so the standby's
        // threshold cannot be raised to 120 although the standby is not in force.
        MockAggregator s = new MockAggregator(8, 1e6, 1e12);
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), _one(address(s)));
        _tl();
        store.setFeed(address(s), _def(86_400, 1800, 25));
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.setFeed(address(s), _def(86_400, 1800, 120));
        // Raising the tolerance to 195 first lets it through.
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 195);
        _tl();
        store.setFeed(address(s), _def(86_400, 1800, 120));
        assertEq(store.feedAgreementToleranceMinBps(usdc), 195);
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-ORACLE-049
    function test_TEST_250_sentinelMaxAnswerPinnedAtTheCap() public {
        // An 8-decimal stable feed whose aggregator reports 2^176 − 1, listed with a cap of 10^12, is pinned at 10^12.
        MockAggregator f = new MockAggregator(8, 1e6, int192(int256(2 ** 176 - 1)));
        FeedDef memory d = _feedDef(86_400, 1800);
        d.maxAnswerCap = 1e12;
        _tl();
        store.setFeed(address(f), d);
        assertEq(store.getFeed(address(f)).maxAnswer, 1e12);
        assertEq(store.getFeed(address(f)).maxAnswerCap, 1e12);
    }

    // TEST-250 verifies: REQ-CONFIG-023, SPEC-ORC-019
    function test_TEST_250_ageExamplesOfStableAndEthFeeds() public {
        // USDC/USD (86,400 + 1,800) gets 88,200 everywhere; ETH/USD (3,600 + 600) gets 4,200.
        MockAggregator eth = new MockAggregator(8, 1e6, 1e14);
        _tl();
        store.setFeed(address(eth), _feedDef(3600, 600));
        assertEq(store.borrowPriceMaxAge(address(eth)), 4200);
        assertEq(store.liquidationPriceMaxAge(address(eth)), 4200);
        assertEq(store.getFeed(address(eth)).feedMaxAge, 4200);
        assertEq(store.borrowPriceMaxAge(address(fUsdc)), 88_200);
        assertEq(store.liquidationPriceMaxAge(address(fUsdc)), 88_200);
        // A setFeed for USDC/USD with the ETH age as its borrow age is refused.
        FeedDef memory bad = _feedDef(86_400, 1800);
        bad.borrowPriceMaxAge = 4200;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setFeed(address(fUsdc), bad);
    }

    // TEST-272 verifies: REQ-RISK-042, Q-383, Q-403
    function test_TEST_272_poolShareExample() public {
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        // No override: the default (10,000, no limit).
        assertEq(store.poolShareMaxBpsOf(key), 10_000);
        // Default 10,000, override 1,000 → 1,000.
        _tl();
        store.tightenPoolShareMaxBpsOf(M, 1000);
        assertEq(store.poolShareMaxBpsOf(key), 1000);
        // Default lowered to 500 → 500.
        _tl();
        store.tightenPoolShareMaxBps(500);
        assertEq(store.poolShareMaxBpsOf(key), 500);
        // Default raised again: the override is back in force.
        _tl();
        store.loosenPoolShareMaxBps(10_000);
        assertEq(store.poolShareMaxBpsOf(key), 1000);
    }

    // TEST-246 verifies: REQ-CONFIG-050, Q-397
    function test_TEST_246_usdcAllowanceReachesOneMillionUnits() public {
        // A USDC debt reserve (6 decimals) priced at $1.00 allows at most 10^6 base units ($1).
        MockPriceSource usdcPrice = new MockPriceSource();
        usdcPrice.setAnswer(1e8);
        DebtReserveDef memory d = registry.getDebtReserve(address(spoke), 1);
        (d.reserveId, d.asset, d.decimals, d.priceSource, d.fixedPrice) = (2, usdc, 6, address(usdcPrice), false);
        registry.setDebtReserve(address(spoke), d);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenFloorRoundingAllowance(usdc, 1e6 + 1);
        _tl();
        store.loosenFloorRoundingAllowance(usdc, 1e6);
        assertEq(store.floorRoundingAllowance(usdc), 1e6);
        // GHO (18 decimals at $1): 10^18 passes and 10^18 + 1 does not.
        _tl();
        store.loosenFloorRoundingAllowance(gho, 1e18);
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.loosenFloorRoundingAllowance(gho, 1e18 + 1);
    }

    // TEST-250 verifies: REQ-PSTORE-028
    function test_TEST_250_networkSourceWithAWindowExample() public {
        // setSecondSource(USDC, {OracleNetwork, pyth, poolRef 0, maxAge 88,200, twapWindow 1,800, 100}) reverts.
        MockAggregator pyth = new MockAggregator(8, 1e6, 1e12);
        _tl();
        store.setFeed(address(pyth), _feedDef(86_400, 1800));
        SecondSource memory none;
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setSecondSource(
            usdc, SecondSource(SecondSourceKind.OracleNetwork, address(pyth), bytes32(0), 88_200, 1800, 100), none
        );
        _tl();
        store.setSecondSource(
            usdc, SecondSource(SecondSourceKind.OracleNetwork, address(pyth), bytes32(0), 88_200, 0, 100), none
        );
        assertEq(store.secondSource(usdc).source, address(pyth));
    }
}
