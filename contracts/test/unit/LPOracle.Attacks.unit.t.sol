// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/oracle/LPOracle.sol";
import {ILPOracle} from "../../src/oracle/interfaces/ILPOracle.sol";
import {BandTestFeed, BandTestToken, BandTestVault} from "../utils/mocks/BandOracleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Adversarial cases for the immutable Chainlink route and its safe accounting boundaries.
/// @dev Pool-spot manipulation and the general floor-credit value bound already have integration and fuzz coverage.
/// These cases target route composition, decimal normalization, and the custom-band clamp instead.
contract LPOracleAttacksUnitTest is Test {
    uint256 internal constant MARKET = 1;

    BandTestVault internal vault;
    BandTestToken internal token0;
    BandTestToken internal token1;
    BandTestFeed internal token0Eth;
    BandTestFeed internal ethUsd;
    BandTestFeed internal token1Usd;
    LPOracle internal oracle;

    function setUp() public {
        vault = new BandTestVault();
        token0 = new BandTestToken("USDC", 6);
        token1 = new BandTestToken("USDT", 6);
        // USDC/ETH multiplied by ETH/USD gives one USD initially.
        token0Eth = new BandTestFeed(18, 0.0005e18);
        ethUsd = new BandTestFeed(8, 2000e8);
        token1Usd = new BandTestFeed(8, 1e8);
        vault.setMarket(MARKET, address(token0), address(token1), -100, 100);
        oracle = new LPOracle(_params(_two(address(token0Eth), address(ethUsd), true), _one(address(token1Usd), true)));
    }

    /// @notice Attacker action: pump a stablecoin's non-USD route leg above peg.
    /// Target invariant: a supported USD stablecoin is never priced above one dollar after route multiplication.
    /// Expected result: the pump has no effect on the LP answer; a later below-peg report is reflected in safe accounting.
    /// Model assumption exposed: both Chainlink legs are trusted reports, not AMM spot or a route-deviation check.
    function test_attackerPumpsStableRoute_targetInvariant_ceilingCapsAndDepegReflects() public {
        uint256 atPeg = uint256(oracle.latestAnswer());

        token0Eth.set(0.001e18); // $2 USDC through ETH/USD.
        (uint256 pumpedPrice,,) = oracle.getPrices();
        assertEq(pumpedPrice, 1e8, "stable route capped at one dollar");
        assertEq(uint256(oracle.latestAnswer()), atPeg, "pump cannot inflate collateral");

        token0Eth.set(0.00045e18); // $0.90 USDC through ETH/USD.
        (uint256 depeggedPrice,,) = oracle.getPrices();
        assertEq(depeggedPrice, 0.9e8, "below-peg report is not hidden by the ceiling");
        assertLt(uint256(oracle.latestAnswer()), atPeg, "depeg reduces collateral accounting");
    }

    /// @notice Attacker action: make the second leg of a listed route answer zero or negative.
    /// Target invariant: no signed or zero answer can become a usable unsigned collateral price.
    /// Expected result: both reports are rejected and identify the bad second-leg feed.
    /// Model assumption exposed: availability is delegated to the listed Chainlink route; rejection can stop an oracle read.
    function test_attackerPoisonsSecondLeg_targetInvariant_invalidAnswersRejected() public {
        token0Eth.set(0);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(token0Eth)));
        oracle.latestAnswer();

        token0Eth.set(0.0005e18);
        ethUsd.set(-1);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethUsd)));
        oracle.latestAnswer();
    }

    /// @notice Attacker action: report a positive 18-decimal answer that rounds to zero at the oracle's eight decimals.
    /// Target invariant: decimal conversion never turns dust into a positive collateral price.
    /// Expected result: the read is rejected instead of serving a rounded-up or inconsistent value.
    /// Model assumption exposed: feeds with 18 decimals must report enough precision to survive the documented rounding down.
    function test_attackerPostsDecimalDust_targetInvariant_normalizedZeroRejected() public {
        BandTestFeed dust = new BandTestFeed(18, 9_999_999_999);
        LPOracle dustOracle = new LPOracle(_params(_one(address(dust), false), _one(address(token1Usd), true)));

        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(dust)));
        dustOracle.latestAnswer();
    }

    /// @notice Attacker action: report an extreme but valid token price that places a custom band far above its upper edge.
    /// Target invariant: the oracle values the band at its real one-sided edge composition, never negative or unbounded amounts.
    /// Expected result: all unit inventory is token1 and its accounting is exactly the token1 edge value.
    /// Model assumption exposed: the Chainlink price, rather than a pool price, selects the composition used for valuation.
    function test_attackerReportsExtremePrice_targetInvariant_upperBandClampUsesOneSidedInventory() public {
        token0Eth.set(0.0005e18);
        ethUsd.set(10_000_000_000e8);
        LPOracle volatileOracle =
            new LPOracle(_params(_two(address(token0Eth), address(ethUsd), false), _one(address(token1Usd), true)));

        (uint256 amount0, uint256 amount1) = volatileOracle.getUnitAmounts();
        assertEq(amount0, 0, "above band holds no token0");
        assertGt(amount1, 0, "above band retains token1 inventory");
        assertEq(uint256(volatileOracle.latestAnswer()), amount1 * 1e2, "answer is token1 edge value at six decimals");
    }

    function _one(
        address feed,
        bool stable
    ) internal pure returns (ILPOracle.TokenFeeds memory route) {
        route.feeds = new address[](1);
        route.feeds[0] = feed;
        route.usdStable = stable;
    }

    function _two(
        address first,
        address second,
        bool stable
    ) internal pure returns (ILPOracle.TokenFeeds memory route) {
        route.feeds = new address[](2);
        (route.feeds[0], route.feeds[1]) = (first, second);
        route.usdStable = stable;
    }

    function _params(
        ILPOracle.TokenFeeds memory route0,
        ILPOracle.TokenFeeds memory route1
    ) internal view returns (ILPOracle.Params memory p) {
        return ILPOracle.Params({
            lpVault: address(vault),
            marketId: MARKET,
            unitDecimals: 18,
            token0: route0,
            token1: route1,
            description: "USDC/USDT attack tests"
        });
    }
}
