// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {LPOracleTestBase} from "../utils/LPOracleTestBase.sol";
import {BandTestFeed, BandTestToken} from "../utils/mocks/BandOracleMocks.sol";

/// @notice The worked examples of `design/oracle.md`: Base ETH/USDC at $1,803.33 (WETH token0, 18 decimals; USDC
/// token1, 6 decimals; tick spacing 10) with a Full range market and the Volatile Custom range market 0.345x–2.898x,
/// and a USDC/USDT ±1% Stable market. Every vault token has 18 decimals. Prices come from an Aave V4 price Spoke on
/// the real pinned `AaveOracle`. Expected answers come from the closed form at 80-digit precision; the contract's
/// Q64.96 math matches them to better than one part in 10^9.
contract LPOracleUnitTest is LPOracleTestBase {
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

    BandTestToken internal weth;
    BandTestToken internal usdc;
    BandTestToken internal usdt;
    BandTestFeed internal ethUsd;
    BandTestFeed internal usdcUsd;
    BandTestFeed internal usdtUsd;
    uint256 internal wethId;
    uint256 internal usdcId;
    uint256 internal usdtId;
    LPOracle internal full;
    LPOracle internal vol;
    LPOracle internal stable;

    function setUp() public {
        _setUpPriceSpoke();
        (weth, ethUsd, wethId) = _listed("WETH", 18, ETH);
        (usdc, usdcUsd, usdcId) = _listed("USDC", 6, 1e8);
        (usdt, usdtUsd, usdtId) = _listed("USDT", 6, 1e8);
        vault.setMarket(FULL, address(weth), address(usdc), FULL_LOWER, FULL_UPPER);
        vault.setMarket(VOLATILE, address(weth), address(usdc), VOL_LOWER, VOL_UPPER);
        vault.setMarket(STABLE, address(usdc), address(usdt), STABLE_LOWER, STABLE_UPPER);
        full = _oracle(FULL, wethId, usdcId);
        vol = _oracle(VOLATILE, wethId, usdcId);
        stable = _oracle(STABLE, usdcId, usdtId);
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

    /// @notice No $1 cap of Avana's own: Aave's source price is used as served (on Aave, a CAPO adapter caps a
    /// stablecoin at its governance-set cap). In a ±1% band the clamp bounds a one-sided overprice: USDC read at $1.02
    /// or $1.04 is worth what the unit holds at the band's top edge, +0.25% over the peg, never +2% or +4%.
    function test_stable_noOwnCap_clampBoundsOverprice() public {
        uint256 atPeg = _answer(stable);
        usdcUsd.set(1.02e8);
        (uint256 p0,,) = stable.getPrices();
        assertEq(p0, 1.02e8, "Aave's price as served");
        uint256 at102 = _answer(stable);
        assertGt(at102, atPeg, "an overprice is not hidden");
        assertLe(at102, atPeg * 10_025 / 10_000, "at most +0.25% in a 1% band");
        usdcUsd.set(1.04e8);
        assertEq(_answer(stable), at102, "past the top edge the unit is all USDT");
        (uint256 a0,) = stable.getUnitAmounts();
        assertEq(a0, 0, "no USDC above the band");
    }

    // ─── Aave's price checks ───

    function test_revert_priceAboveBound() public {
        ethUsd.set(1e10 * 1e8 + 1);
        vm.expectRevert(abi.encodeWithSelector(ILPOracle.PriceAboveBound.selector, wethId));
        full.latestAnswer();
        ethUsd.set(1e10 * 1e8);
        full.latestAnswer();
    }

    /// @notice No staleness check: a round a year old still prices (Aave V4 reads no round time).
    function test_oldRoundStillPrices() public {
        vm.warp(block.timestamp + 365 days);
        assertApproxEqRel(_answer(full), 8_493_126_632_754_271, REL);
    }

    /// @notice The answer is never 0, which Aave V4 refuses.
    function test_answerAtLeastOne() public {
        (BandTestToken a,, uint256 idA) = _listed("A", 18, 1);
        (BandTestToken b,, uint256 idB) = _listed("B", 18, 1);
        vault.setMarket(9, address(a), address(b), -10, 10);
        ILPOracle.Params memory p = _params(9, idA, idB);
        p.unitDecimals = 6;
        assertEq(new LPOracle(p).latestAnswer(), 1);
    }

    // ─── Construction ───

    function test_views() public view {
        assertEq(full.decimals(), 8);
        assertEq(full.description(), "Avana band unit");
        assertEq(vol.lpVault(), address(vault));
        assertEq(vol.marketId(), VOLATILE);
        (int24 lo, int24 hi) = vol.band();
        assertEq(lo, VOL_LOWER);
        assertEq(hi, VOL_UPPER);
        (address t0, address t1) = vol.tokens();
        assertEq(t0, address(weth));
        assertEq(t1, address(usdc));
        assertEq(vol.unitDecimals(), 18);
        assertEq(vol.priceSpoke(), address(priceSpoke));
        assertEq(vol.aaveOracle(), priceSpoke.ORACLE());
        (uint256 r0, uint256 r1) = vol.reserveIds();
        assertEq(r0, wethId);
        assertEq(r1, usdcId);
    }

    function test_revert_constructor() public {
        ILPOracle.Params memory p = _params(FULL, wethId, usdcId);
        p.lpVault = address(0);
        _expectInvalid(p);
        _expectInvalid(_params(42, wethId, usdcId)); // not listed
        p = _params(FULL, wethId, usdcId);
        p.unitDecimals = 5;
        _expectInvalid(p);
        p.unitDecimals = 19;
        _expectInvalid(p);
        p = _params(FULL, wethId, usdcId);
        p.priceSpoke = address(0);
        _expectInvalid(p);
        BandTestToken big = new BandTestToken("BIG", 19);
        vault.setMarket(7, address(big), address(usdc), -10, 10);
        _expectInvalid(_params(7, wethId, usdcId));
    }

    /// @notice Bug hunted: an LPVault market with a zero token address priced as a token. `decimals()` on address 0
    /// returns nothing and the price Spoke has no reserve for it, so the oracle must refuse the market at
    /// construction, on either side, instead of reverting with an unrelated error or reading 0 decimals.
    function test_revert_constructor_zeroTokenInTheMarket() public {
        vault.setMarket(8, address(0), address(usdc), -10, 10);
        _expectInvalid(_params(8, wethId, usdcId));
        vault.setMarket(9, address(weth), address(0), -10, 10);
        _expectInvalid(_params(9, wethId, usdcId));
    }

    function _expectInvalid(
        ILPOracle.Params memory p
    ) internal {
        vm.expectRevert(ILPOracle.InvalidParams.selector);
        new LPOracle(p);
    }
}
