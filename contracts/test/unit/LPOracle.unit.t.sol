// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {LPOracle} from "../../src/oracle/LPOracle.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {OracleFeedMock, OracleTokenMock} from "../utils/mocks/LPOracleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice A market's LPVault as the oracle reads it: one whole vault token holds `amount0` and `amount1`, whatever the
/// prices (the real LPVault moves them with the oracle sqrt price; the oracle's own arithmetic is what is tested here).
contract FixedCompositionVault {
    uint256 public amount0;
    uint256 public amount1;

    function set(
        uint256 a0,
        uint256 a1
    ) external {
        (amount0, amount1) = (a0, a1);
    }

    function composition(
        uint256,
        uint256,
        uint256[] calldata
    ) external view returns (uint256[] memory amounts, bool exact) {
        amounts = new uint256[](2);
        (amounts[0], amounts[1], exact) = (amount0, amount1, true);
    }
}

/// @notice The ParameterStore's feed definitions: borrow and liquidation age limits per feed.
contract FeedAgeStore {
    mapping(address => FeedDef) internal _feeds;

    function setAges(
        address feed,
        uint32 borrow,
        uint32 liquidation
    ) external {
        (_feeds[feed].decimals, _feeds[feed].borrowPriceMaxAge, _feeds[feed].liquidationPriceMaxAge) =
        (8, borrow, liquidation);
    }

    function getFeed(
        address feed
    ) external view returns (FeedDef memory) {
        return _feeds[feed];
    }
}

/// @title LPOracleUnitTest
/// @notice The stateless LPOracle: the value of one whole vault token from Chainlink prices and the LPVault's
/// composition, the $1 stable ceiling, two-leg routes, reverts on a failed leg, and the borrow and liquidation
/// freshness the gates read.
contract LPOracleUnitTest is Test {
    OracleTokenMock internal usdc;
    OracleTokenMock internal weth;
    OracleFeedMock internal usdcFeed;
    OracleFeedMock internal ethFeed;
    FixedCompositionVault internal vault;
    FeedAgeStore internal store;
    LPOracle internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new OracleTokenMock(6);
        weth = new OracleTokenMock(18);
        usdcFeed = new OracleFeedMock(8, 1, 1e18);
        ethFeed = new OracleFeedMock(8, 1, 1e18);
        usdcFeed.push(1e8, block.timestamp);
        ethFeed.push(3000e8, block.timestamp);
        vault = new FixedCompositionVault();
        store = new FeedAgeStore();
        store.setAges(address(usdcFeed), 3600, 90_000);
        store.setAges(address(ethFeed), 3600, 90_000);
        // One whole vault token: 1,000 USDC and 1 WETH (plus the one raw unit each the price rounds away).
        vault.set(1000e6 + 1, 1e18 + 1);
        oracle = _deploy(_routes(_one(address(usdcFeed)), _one(address(ethFeed))), 18);
    }

    function _one(
        address feed
    ) internal pure returns (address[] memory f) {
        f = new address[](1);
        f[0] = feed;
    }

    function _routes(
        address[] memory f0,
        address[] memory f1
    ) internal view returns (ILPOracle.TokenRoute[] memory r) {
        r = new ILPOracle.TokenRoute[](2);
        r[0] = ILPOracle.TokenRoute({token: address(usdc), isUsdStable: true, feeds: f0});
        r[1] = ILPOracle.TokenRoute({token: address(weth), isUsdStable: false, feeds: f1});
    }

    function _deploy(
        ILPOracle.TokenRoute[] memory r,
        uint8 vaultDecimals
    ) internal returns (LPOracle) {
        return new LPOracle(
            ILPOracle.Params({
                marketId: 7,
                integration: address(vault),
                parameterStore: address(store),
                description: "USDC/WETH LP / USD",
                vaultDecimals: vaultDecimals,
                routes: r
            })
        );
    }

    function test_valueIsTheCompositionAtChainlinkPrices() public view {
        assertEq(oracle.latestAnswer(), 4000e8, "1,000 USDC at $1 plus 1 WETH at $3,000");
        assertEq(oracle.decimals(), 8);
        assertEq(oracle.vaultDecimals(), 18);
        assertEq(oracle.marketId(), 7);
        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, 4000e8);
        assertEq(updatedAt, block.timestamp);
    }

    function test_stableIsCappedAtOneDollar() public {
        usdcFeed.push(1.02e8, block.timestamp);
        (uint256[] memory prices,) = oracle.getTokenPrices();
        assertEq(prices[0], 1e8, "USDC valued at most $1");
        assertEq(oracle.latestAnswer(), 4000e8);
        usdcFeed.push(0.98e8, block.timestamp);
        assertEq(oracle.latestAnswer(), 3980e8, "below the peg it is valued as quoted");
    }

    function test_twoLegRouteMultiplies() public {
        OracleFeedMock wstEth = new OracleFeedMock(18, 1, 1e30);
        wstEth.push(1.2e18, block.timestamp);
        address[] memory legs = new address[](2);
        (legs[0], legs[1]) = (address(wstEth), address(ethFeed));
        LPOracle o = _deploy(_routes(_one(address(usdcFeed)), legs), 18);
        assertEq(o.latestAnswer(), 1000e8 + 3600e8, "1.2 ETH per token at $3,000");
        assertEq(o.feedsOf(1).length, 2);
    }

    function test_failedLegReverts() public {
        ethFeed.push(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethFeed)));
        oracle.latestAnswer();
        ethFeed.push(3000e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethFeed)));
        oracle.latestAnswer();
    }

    function test_freshnessFollowsEachFeedsAges() public {
        ILPOracle.PriceStatus memory s = oracle.getPriceStatus();
        assertTrue(s.borrowFresh && s.liquidationFresh, "both fresh now");
        assertEq(s.answer, 4000e8);
        vm.warp(block.timestamp + 3601);
        s = oracle.getPriceStatus();
        assertFalse(s.borrowFresh, "past the borrow age");
        assertTrue(s.liquidationFresh, "within the liquidation age");
        vm.warp(block.timestamp + 90_000);
        s = oracle.getPriceStatus();
        assertFalse(s.liquidationFresh, "past the liquidation age");
        assertEq(s.answer, 4000e8, "the price is still served");
    }

    function test_oldestLegIsTheUpdateTime() public {
        usdcFeed.push(1e8, block.timestamp - 100);
        (, uint64 at) = oracle.getTokenPrices();
        assertEq(at, block.timestamp - 100);
        assertEq(oracle.getPriceStatus().updatedAt, block.timestamp - 100);
    }

    function test_neverZero() public {
        vault.set(0, 0);
        assertEq(oracle.latestAnswer(), 1, "an empty composition serves 1");
    }

    function test_constructorRefusesBadMarkets() public {
        ILPOracle.TokenRoute[] memory r = _routes(_one(address(usdcFeed)), _one(address(ethFeed)));
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidMarket.selector, 7));
        _deploy(r, 5);
        r[1].token = address(usdc);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidMarket.selector, 7));
        _deploy(r, 18);
        r = _routes(new address[](0), _one(address(ethFeed)));
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidMarket.selector, 7));
        _deploy(r, 18);
    }
}
