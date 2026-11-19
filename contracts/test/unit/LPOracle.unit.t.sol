// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {LPOracle} from "../../src/oracle/LPOracle.sol";
import {BandTestFeed, BandTestToken, BandTestVault} from "../utils/mocks/BandOracleMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The worked examples of `src/oracle/DESIGN.md`: Base ETH/USDC at $1,803.33 (WETH token0, 18 decimals; USDC
/// token1, 6 decimals; tick spacing 10) with a Full range market and the Volatile Custom range market 0.345x–2.898x,
/// and a USDC/USDT ±1% Stable market. Every vault token has 18 decimals. Expected answers come from the closed form
/// at 80-digit precision; the contract's Q64.96 math matches them to better than one part in 10^9.
contract LPOracleUnitTest is Test {
    uint256 internal constant FULL = 1;
    uint256 internal constant VOLATILE = 2;
    uint256 internal constant STABLE = 3;
    int24 internal constant FULL_LOWER = -887_270;
    int24 internal constant FULL_UPPER = 887_270;
    int24 internal constant VOL_LOWER = -211_990;
    int24 internal constant VOL_UPPER = -190_700;
    int24 internal constant STABLE_LOWER = -101;
    int24 internal constant STABLE_UPPER = 100;
    int256 internal constant ETH = 1803.33e8;
    uint256 internal constant REL = 1e9; // one part in 10^9

    BandTestVault internal vault;
    BandTestToken internal weth;
    BandTestToken internal usdc;
    BandTestToken internal usdt;
    BandTestFeed internal ethUsd;
    BandTestFeed internal usdcUsd;
    BandTestFeed internal usdtUsd;
    LPOracle internal full;
    LPOracle internal vol;
    LPOracle internal stable;

    function setUp() public {
        vault = new BandTestVault();
        weth = new BandTestToken("WETH", 18);
        usdc = new BandTestToken("USDC", 6);
        usdt = new BandTestToken("USDT", 6);
        ethUsd = new BandTestFeed(8, ETH);
        usdcUsd = new BandTestFeed(8, 1e8);
        usdtUsd = new BandTestFeed(8, 1e8);
        vault.setMarket(FULL, address(weth), address(usdc), FULL_LOWER, FULL_UPPER);
        vault.setMarket(VOLATILE, address(weth), address(usdc), VOL_LOWER, VOL_UPPER);
        vault.setMarket(STABLE, address(usdc), address(usdt), STABLE_LOWER, STABLE_UPPER);
        full = new LPOracle(_params(FULL, _one(address(ethUsd), false), _one(address(usdcUsd), true)));
        vol = new LPOracle(_params(VOLATILE, _one(address(ethUsd), false), _one(address(usdcUsd), true)));
        stable = new LPOracle(_params(STABLE, _one(address(usdcUsd), true), _one(address(usdtUsd), true)));
    }

    function _one(
        address feed,
        bool usdStable
    ) internal pure returns (ILPOracle.TokenFeeds memory t) {
        t.feeds = new address[](1);
        t.feeds[0] = feed;
        t.usdStable = usdStable;
    }

    function _params(
        uint256 marketId,
        ILPOracle.TokenFeeds memory t0,
        ILPOracle.TokenFeeds memory t1
    ) internal view returns (ILPOracle.Params memory p) {
        p = ILPOracle.Params({
            lpVault: address(vault),
            marketId: marketId,
            unitDecimals: 18,
            token0: t0,
            token1: t1,
            description: "Avana WETH/USDC band unit"
        });
    }

    function _answer(
        LPOracle o
    ) internal view returns (uint256) {
        return uint256(o.latestAnswer());
    }

    // ─── Worked examples ───

    /// @notice Full range at $1,803.33: one unit ≈ 2·√P in token1, $84.93M per 10^18 liquidity units.
    function test_fullRange_atListing() public view {
        assertApproxEqRel(_answer(full), 8_493_126_632_754_271, REL, "full");
        (uint256 a0, uint256 a1) = full.getUnitAmounts();
        assertApproxEqRel(a0, 23_548_453_784_815_526_801_450, REL, "eth");
        assertApproxEqRel(a1, 42_465_633_163_771, REL, "usdc");
    }

    function test_fullRange_down30_up50() public {
        ethUsd.set(1262.331e8);
        assertApproxEqRel(_answer(full), 7_105_859_553_917_451, REL, "-30%");
        ethUsd.set(2704.995e8);
        assertApproxEqRel(_answer(full), 10_401_913_285_545_111, REL, "+50%");
    }

    /// @notice The full-range clamp never binds: far outside any volatile band both amounts stay non-zero.
    function test_fullRange_clampNeverBinds() public {
        ethUsd.set(0.01e8);
        (uint256 a0, uint256 a1) = full.getUnitAmounts();
        assertGt(a0, 0);
        assertGt(a1, 0);
        ethUsd.set(1e10 * 1e8);
        (a0, a1) = full.getUnitAmounts();
        assertGt(a0, 0);
        assertGt(a1, 0);
    }

    function test_volatile_atListing_down30_up50() public {
        assertApproxEqRel(_answer(vol), 3_505_132_667_184_954, REL, "listing");
        ethUsd.set(1262.331e8);
        assertApproxEqRel(_answer(vol), 2_866_013_229_877_265, REL, "-30%");
        ethUsd.set(2704.995e8);
        assertApproxEqRel(_answer(vol), 4_167_006_584_093_909, REL, "+50%");
    }

    /// @notice Below the band the unit is all ETH; above it, all USDC: the clamp is the AMM's own composition.
    function test_volatile_clampOutsideBand() public {
        ethUsd.set(540.999e8);
        (uint256 a0, uint256 a1) = vol.getUnitAmounts();
        assertEq(a1, 0, "below: no usdc");
        assertApproxEqRel(a0, 26_264_519_949_353_511_885_791, REL, "below: eth");
        assertApproxEqRel(_answer(vol), 1_420_907_902_808_030, REL, "below: value");
        ethUsd.set(5770.656e8);
        (a0, a1) = vol.getUnitAmounts();
        assertEq(a0, 0, "above: no eth");
        assertApproxEqRel(a1, 47_370_111_553_644, REL, "above: usdc");
        assertApproxEqRel(_answer(vol), 4_737_011_155_364_469, REL, "above: value");
    }

    function test_stable_atPeg_andDepeg() public {
        assertApproxEqRel(_answer(stable), 1_002_429_104_690_783_935, REL, "peg");
        usdcUsd.set(0.995e8);
        assertApproxEqRel(_answer(stable), 999_308_901_255_442_703, REL, "-0.5%");
        usdcUsd.set(0.97e8);
        assertApproxEqRel(_answer(stable), 974_829_731_954_655_677, REL, "-3%");
        (, uint256 a1) = stable.getUnitAmounts();
        assertEq(a1, 0, "all usdc below band");
    }

    /// @notice A USD stablecoin is valued at most $1: a feed at $1.02 prices like $1.00.
    function test_stableCeiling() public {
        uint256 atPeg = _answer(stable);
        usdcUsd.set(1.02e8);
        usdtUsd.set(1.02e8);
        assertEq(_answer(stable), atPeg);
        (uint256 p0, uint256 p1,) = stable.getPrices();
        assertEq(p0, 1e8);
        assertEq(p1, 1e8);
    }

    // ─── Routes and the one feed check ───

    function test_twoLegRoute_equalsDirect() public {
        BandTestFeed ethBtc = new BandTestFeed(18, 0.02e18);
        BandTestFeed btcUsd = new BandTestFeed(8, 90_166.5e8);
        ILPOracle.TokenFeeds memory t0;
        t0.feeds = new address[](2);
        (t0.feeds[0], t0.feeds[1]) = (address(ethBtc), address(btcUsd));
        LPOracle o = new LPOracle(_params(FULL, t0, _one(address(usdcUsd), true)));
        assertEq(o.latestAnswer(), full.latestAnswer());
        assertEq(o.feedsOf(0), t0.feeds);
    }

    function test_revert_zeroOrNegativeAnswer() public {
        ethUsd.set(0);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethUsd)));
        full.latestAnswer();
        ethUsd.set(-1);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethUsd)));
        full.latestAnswer();
        ethUsd.set(int256(2 ** 128));
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethUsd)));
        full.latestAnswer();
    }

    function test_revert_priceAboveBound() public {
        ethUsd.set(1e10 * 1e8 + 1);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.InvalidPrice.selector, address(ethUsd)));
        full.latestAnswer();
    }

    /// @notice No staleness check: a round a year old still prices (Aave V4 reads no round time).
    function test_oldRoundStillPrices() public {
        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(_answer(full), 8_493_126_632_754_271, REL);
    }

    /// @notice The answer is never 0, which Aave V4 refuses.
    function test_answerAtLeastOne() public {
        BandTestToken a = new BandTestToken("A", 18);
        BandTestToken b = new BandTestToken("B", 18);
        BandTestFeed f = new BandTestFeed(8, 1);
        vault.setMarket(9, address(a), address(b), -10, 10);
        ILPOracle.Params memory p = _params(9, _one(address(f), false), _one(address(f), false));
        p.unitDecimals = 6;
        assertEq(new LPOracle(p).latestAnswer(), 1);
    }

    // ─── Construction ───

    function test_views() public view {
        assertEq(full.decimals(), 8);
        assertEq(full.description(), "Avana WETH/USDC band unit");
        assertEq(vol.lpVault(), address(vault));
        assertEq(vol.marketId(), VOLATILE);
        (int24 lo, int24 hi) = vol.band();
        assertEq(lo, VOL_LOWER);
        assertEq(hi, VOL_UPPER);
        (address t0, address t1) = vol.tokens();
        assertEq(t0, address(weth));
        assertEq(t1, address(usdc));
        assertEq(vol.unitDecimals(), 18);
        assertEq(vol.feedsOf(1)[0], address(usdcUsd));
        assertEq(vol.feedsOf(2).length, 0);
    }

    function test_feedDecimals18() public {
        BandTestFeed eth18 = new BandTestFeed(18, 1803.33e18);
        LPOracle o = new LPOracle(_params(FULL, _one(address(eth18), false), _one(address(usdcUsd), true)));
        assertEq(o.latestAnswer(), full.latestAnswer());
    }

    function test_revert_constructor() public {
        ILPOracle.Params memory p = _params(FULL, _one(address(ethUsd), false), _one(address(usdcUsd), true));
        p.lpVault = address(0);
        _expectInvalid(p);
        p = _params(42, _one(address(ethUsd), false), _one(address(usdcUsd), true));
        _expectInvalid(p); // not listed
        p = _params(FULL, _one(address(ethUsd), false), _one(address(usdcUsd), true));
        p.unitDecimals = 5;
        _expectInvalid(p);
        p.unitDecimals = 19;
        _expectInvalid(p);
        p = _params(FULL, _one(address(0), false), _one(address(usdcUsd), true));
        _expectInvalid(p);
        p.token0.feeds = new address[](0);
        _expectInvalid(p);
        p.token0.feeds = new address[](3);
        _expectInvalid(p);
        p = _params(FULL, _one(address(new BandTestFeed(19, 1)), false), _one(address(usdcUsd), true));
        _expectInvalid(p);
        BandTestToken big = new BandTestToken("BIG", 19);
        vault.setMarket(7, address(big), address(usdc), -10, 10);
        p = _params(7, _one(address(ethUsd), false), _one(address(usdcUsd), true));
        _expectInvalid(p);
    }

    function _expectInvalid(
        ILPOracle.Params memory p
    ) internal {
        vm.expectRevert(ILPOracle.InvalidParams.selector);
        new LPOracle(p);
    }
}
