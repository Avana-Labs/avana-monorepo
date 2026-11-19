// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/amm/concentrated-liquidity/ClTickMath.sol";
import {ILPOracle} from "../../src/oracle/ILPOracle.sol";
import {LPPriceMath} from "../../src/oracle/LPPriceMath.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {RiskModule} from "../../src/policy/risk-module/RiskModule.sol";
import {BandMath} from "../../src/policy/risk-module/libraries/BandMath.sol";
import {BandTestFeed, BandTestToken} from "../utils/mocks/BandOracleMocks.sol";
import {
    RiskTestFirstLossReserve,
    RiskTestHub,
    RiskTestSpoke,
    RiskTestVault
} from "../utils/mocks/RiskModuleTestMocks.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Exposes BandMath for revert checks.
contract BandMathHarness {
    function customRange(
        int24 listingTick,
        IRiskModule.Width memory width,
        int24 spacing
    ) external pure returns (int24, int24) {
        return BandMath.customRange(listingTick, width, spacing);
    }
}

/// @notice Fuzzes the listing bands, the vault-token decimals, eligibility and credit, and the coverage arithmetic.
contract RiskModuleBandsFuzzTest is Test {
    BandMathHarness internal h = new BandMathHarness();

    // ─── Bands ───

    function testFuzz_fullRange_isTheUsableRange(
        int24 spacing
    ) public pure {
        spacing = int24(bound(spacing, 1, 16_384));
        (int24 lower, int24 upper) = BandMath.fullRange(spacing);
        assertEq(lower % spacing, 0);
        assertEq(upper % spacing, 0);
        assertEq(lower, -upper);
        assertGe(lower, ClTickMath.MIN_TICK);
        assertLe(upper, ClTickMath.MAX_TICK);
        assertLt(lower - spacing, ClTickMath.MIN_TICK);
        assertGt(upper + spacing, ClTickMath.MAX_TICK);
    }

    /// @dev A band that lists is aligned, holds the requested width around the listing tick, spans at least
    /// `MIN_BAND_SPACINGS` spacings, and lies inside the usable range without equalling it.
    function testFuzz_customRange(
        int24 listingTick,
        uint24 below,
        uint24 above,
        int24 spacing
    ) public view {
        spacing = int24(bound(spacing, 1, 1000));
        listingTick = int24(bound(listingTick, ClTickMath.MIN_TICK, ClTickMath.MAX_TICK));
        below = uint24(bound(below, 1, 2 * 887_272));
        above = uint24(bound(above, 1, 2 * 887_272));
        IRiskModule.Width memory w = IRiskModule.Width(below, above);
        try h.customRange(listingTick, w, spacing) returns (int24 lower, int24 upper) {
            (int24 minU, int24 maxU) = BandMath.fullRange(spacing);
            assertEq(lower % spacing, 0);
            assertEq(upper % spacing, 0);
            assertLe(int256(lower), int256(listingTick) - int256(uint256(below)));
            assertGt(int256(lower), int256(listingTick) - int256(uint256(below)) - spacing);
            assertGe(int256(upper), int256(listingTick) + int256(uint256(above)));
            assertLt(int256(upper), int256(listingTick) + int256(uint256(above)) + spacing);
            assertGe(int256(upper) - lower, int256(spacing) * 4);
            assertGe(lower, minU);
            assertLe(upper, maxU);
            assertTrue(lower != minU || upper != maxU);
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == IRiskModule.BandTooNarrow.selector || sel == IRiskModule.BandNotNarrowerThanFullRange.selector
            );
        }
    }

    /// @dev Volatile default width at any listing tick a real pool has: the band never reverts for spacing <= 200.
    function testFuzz_customRange_volatileDefaultLists(
        int24 listingTick,
        int24 spacing
    ) public view {
        spacing = int24(bound(spacing, 1, 200));
        listingTick = int24(bound(listingTick, -800_000, 800_000));
        (int24 lower, int24 upper) = h.customRange(listingTick, IRiskModule.Width(10_643, 10_641), spacing);
        assertLe(lower, listingTick);
        assertGt(upper, listingTick);
    }

    // ─── Vault-token decimals ───

    struct Case {
        uint160 s;
        int24 lower;
        int24 upper;
        uint256 p0;
        uint256 p1;
        uint8 d0;
        uint8 d1;
    }

    /// @dev The chosen decimals make a whole token worth at least $1, and one decimal fewer worth less (unless 6).
    function testFuzz_unitDecimals(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1,
        uint24 lowerOff,
        uint24 upperOff
    ) public pure {
        Case memory c;
        c.p0 = bound(p0, 1e4, 1e14);
        c.p1 = bound(p1, 1e4, 1e14);
        c.d0 = uint8(bound(d0, 6, 18));
        c.d1 = uint8(bound(d1, 6, 18));
        c.s = LPPriceMath.sqrtPriceX96(c.p0, c.p1, c.d0, c.d1);
        int24 t = ClTickMath.getTickAtSqrtPrice(c.s);
        int256 lo = int256(t) - int256(bound(lowerOff, 1, 50_000));
        int256 hi = int256(t) + int256(bound(upperOff, 1, 50_000));
        c.lower = int24(lo < ClTickMath.MIN_TICK ? ClTickMath.MIN_TICK : lo);
        c.upper = int24(hi > ClTickMath.MAX_TICK ? ClTickMath.MAX_TICK : hi);
        if (c.lower >= c.upper) return;
        uint8 d = BandMath.unitDecimals(c.s, c.lower, c.upper, c.p0, c.p1, c.d0, c.d1);
        if (d == 0) {
            assertLt(_value(c, 18), 1e8);
            return;
        }
        assertGe(d, 6);
        assertLe(d, 18);
        assertGe(_value(c, d), 1e8);
        if (d > 6) assertLt(_value(c, d - 1), 1e8);
    }

    function _value(
        Case memory c,
        uint8 d
    ) internal pure returns (uint256) {
        (uint256 a0, uint256 a1) = LPPriceMath.amounts(
            c.s, ClTickMath.getSqrtPriceAtTick(c.lower), ClTickMath.getSqrtPriceAtTick(c.upper), uint128(10 ** d)
        );
        return LPPriceMath.value(a0, a1, c.p0, c.p1, c.d0, c.d1);
    }

    // ─── Through the RiskModule ───

    function _module() internal returns (RiskModule rm, RiskTestSpoke spoke, RiskTestHub hub, address usdc) {
        AccessManager am = new AccessManager(address(this));
        BandTestToken weth = new BandTestToken("WETH", 18);
        usdc = address(new BandTestToken("USDC", 6));
        RiskTestVault vault = new RiskTestVault(address(weth), usdc, 10);
        hub = new RiskTestHub();
        spoke = new RiskTestSpoke();
        rm = new RiskModule(address(am), address(vault), makeAddr("lm"));
        rm.registerSpoke(address(spoke), address(hub), IRiskModule.SpokeKind.Volatile);
    }

    /// @dev At any ETH price, the listing's two markets route and credit positions consistently: the full-range
    /// position goes to Full range at credit L (less rounding), a position inside the Custom band to Custom range at a credit of at
    /// most L, and anything else nowhere.
    function testFuzz_routeAndCredit(
        uint256 ethPrice,
        int24 a,
        int24 b,
        uint128 liquidity
    ) public {
        ethPrice = bound(ethPrice, 1e8, 1e13);
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        (RiskModule rm, RiskTestSpoke spoke,,) = _module();
        IRiskModule.ListPoolParams memory p;
        p.pool = bytes32(uint256(1));
        p.spoke = address(spoke);
        p.tickSpacing = 10;
        p.ltvBps = 7000;
        p.token0 = _route(address(new BandTestFeed(8, int256(ethPrice))));
        p.token1 = _route(address(new BandTestFeed(8, 1e8)));
        p.listingTick = ClTickMath.getTickAtSqrtPrice(LPPriceMath.sqrtPriceX96(ethPrice, 1e8, 18, 6));
        (uint256 full, uint256 custom) = rm.listPool(p);
        IRiskModule.Market memory c = rm.getMarket(custom);

        assertEq(rm.routeOf(p.pool, -887_270, 887_270), full);
        uint128 fullCredit = rm.creditOf(full, -887_270, 887_270, liquidity);
        assertLe(fullCredit, liquidity);
        assertGe(uint256(fullCredit) + 2 + liquidity / 1e12, liquidity);

        a = int24(bound(a, -887_270, 887_269));
        b = int24(bound(b, int256(a) + 1, 887_270));
        uint256 route = rm.routeOf(p.pool, a, b);
        bool inside = c.bandLower <= a && b <= c.bandUpper;
        if (a == -887_270 && b == 887_270) assertEq(route, full);
        else if (inside) assertEq(route, custom);
        else assertEq(route, 0);
        assertEq(rm.isEligible(custom, a, b), inside);
        if (inside) assertLe(rm.creditOf(custom, a, b, liquidity), liquidity);
    }

    function _route(
        address feed
    ) internal pure returns (ILPOracle.TokenFeeds memory t) {
        t.feeds = new address[](1);
        t.feeds[0] = feed;
    }

    // ─── Coverage ───

    /// @dev `required` is the summed draw caps at the ratio, in base units, rounded up.
    function testFuzz_coverage(
        uint40 cap1,
        uint40 cap2,
        uint256 ratio,
        uint256 funded
    ) public {
        cap1 = uint40(bound(cap1, 0, type(uint40).max - 1));
        cap2 = uint40(bound(cap2, 0, type(uint40).max - 1));
        ratio = bound(ratio, 0, 10_000);
        funded = bound(funded, 0, type(uint128).max);
        (RiskModule rm, address spoke, address hub, address usdc) = _coverageSetup(cap1, cap2, ratio, funded);

        (uint256 sum, uint256 required, uint256 got) = rm.coverage(hub, usdc);
        uint256 exact = (uint256(cap1) + cap2) * 1e6 * ratio;
        assertEq(sum, uint256(cap1) + cap2);
        assertEq(got, funded);
        assertGe(required * 10_000, exact);
        assertLt(required * 10_000, exact + 10_000);

        if (required > funded) vm.expectPartialRevert(IRiskModule.CoverageBelowRatio.selector);
        rm.checkBorrow(spoke, 1);
    }

    /// @dev Two Spokes borrowing USDC from one Hub with draw caps `cap1` and `cap2`, one First-Loss Reserve, a keeper.
    function _coverageSetup(
        uint40 cap1,
        uint40 cap2,
        uint256 ratio,
        uint256 funded
    ) internal returns (RiskModule rm, address spokeAddr, address hubAddr, address usdc) {
        RiskTestSpoke spoke;
        RiskTestHub hub;
        (rm, spoke, hub, usdc) = _module();
        RiskTestSpoke spoke2 = new RiskTestSpoke();
        rm.registerSpoke(address(spoke2), address(hub), IRiskModule.SpokeKind.Stable);
        hub.setAsset(usdc, 5);
        spoke.setReserve(1, usdc, address(hub), 5);
        spoke2.setReserve(2, usdc, address(hub), 5);
        RiskTestFirstLossReserve flr = new RiskTestFirstLossReserve(usdc, address(hub));
        rm.setDebtReserve(address(spoke), 1, address(flr));
        rm.setDebtReserve(address(spoke2), 2, address(flr));
        hub.setDrawCap(5, address(spoke), cap1);
        hub.setDrawCap(5, address(spoke2), cap2);
        rm.setCoverageRatio(ratio);
        rm.addKeeper(address(7));
        flr.setFunded(funded);
        (spokeAddr, hubAddr) = (address(spoke), address(hub));
    }
}
