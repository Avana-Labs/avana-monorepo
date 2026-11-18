// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, MockPriceSource} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice The worked examples of 2.9, run as written on the real store: each number in an example is an
/// assertion here.
contract ParameterStoreExamplesUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
        _listMarket();
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
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setFeed(address(fUsdc), bad);
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
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenFloorRoundingAllowance(usdc, 1e6 + 1);
        _tl();
        store.loosenFloorRoundingAllowance(usdc, 1e6);
        assertEq(store.floorRoundingAllowance(usdc), 1e6);
        // GHO (18 decimals at $1): 10^18 passes and 10^18 + 1 does not.
        _tl();
        store.loosenFloorRoundingAllowance(gho, 1e18);
        _tl();
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.loosenFloorRoundingAllowance(gho, 1e18 + 1);
    }
}
