// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../src/LPOracle.sol";
import {ILPOracle} from "../../src/interfaces/ILPOracle.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {FloorCreditMath} from "../../src/libraries/FloorCreditMath.sol";
import {BandTestFeed, BandTestPriceSpoke, BandTestToken, BandTestVault} from "../utils/mocks/BandOracleMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Test} from "forge-std/Test.sol";

/// @notice The collateral Aave counts for a pledged position never exceeds what the position holds:
/// `credit × LPOracle answer / 10^unitDecimals ≤ value of the position's own amounts`, both at the oracle's fair price
/// `P`, for random positions inside random bands and for the full range, with random prices and decimals.
/// @dev "Value of the position's amounts" is measured as the AMM pays it, rounded up by at most one smallest unit of
/// each token, so the bound is the exact one with the pool's own rounding as the only slack. The case where the
/// oracle serves its floor of 1 (a whole vault token worth under 10^-8 USD) is left out; `LPOracle.unit.t.sol`
/// covers it.
contract LPOracleFloorCreditFuzzTest is Test {
    uint256 internal constant MARKET = 1;

    BandTestVault internal vault;
    BandTestPriceSpoke internal priceSpoke;
    BandTestFeed internal feed0;
    BandTestFeed internal feed1;

    function setUp() public {
        vault = new BandTestVault();
        priceSpoke = new BandTestPriceSpoke(8);
        priceSpoke.init();
        feed0 = new BandTestFeed(8, 1e8);
        feed1 = new BandTestFeed(8, 1e8);
    }

    struct Case {
        int24 bandLower;
        int24 bandUpper;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 p0;
        uint256 p1;
        uint8 d0;
        uint8 d1;
        uint8 unitDecimals;
    }

    function testFuzz_creditTimesPriceWithinPositionValue(
        uint256 spacingSeed,
        uint256[4] memory tickSeeds,
        uint128 liquidity,
        uint256[2] memory prices,
        uint8[3] memory decs
    ) public {
        int24 spacing = _spacing(spacingSeed);
        int24 maxIdx = ClTickMath.MAX_TICK / spacing;
        Case memory c;
        int24 lo = int24(bound(int256(tickSeeds[0] % 1e9), -int256(maxIdx), int256(maxIdx) - 1));
        int24 hi = int24(bound(int256(tickSeeds[1] % 1e9), int256(lo) + 1, int256(maxIdx)));
        int24 a = int24(bound(int256(tickSeeds[2] % 1e9), int256(lo), int256(hi) - 1));
        int24 b = int24(bound(int256(tickSeeds[3] % 1e9), int256(a) + 1, int256(hi)));
        (c.bandLower, c.bandUpper, c.tickLower, c.tickUpper) = (lo * spacing, hi * spacing, a * spacing, b * spacing);
        _fill(c, liquidity, prices, decs);
        _check(c);
    }

    function testFuzz_fullRange(
        uint256 spacingSeed,
        uint128 liquidity,
        uint256[2] memory prices,
        uint8[3] memory decs
    ) public {
        int24 spacing = _spacing(spacingSeed);
        Case memory c;
        c.bandUpper = (ClTickMath.MAX_TICK / spacing) * spacing;
        c.bandLower = -c.bandUpper;
        (c.tickLower, c.tickUpper) = (c.bandLower, c.bandUpper);
        _fill(c, liquidity, prices, decs);
        _check(c);
    }

    function _spacing(
        uint256 seed
    ) internal pure returns (int24) {
        int24[4] memory s = [int24(1), 10, 60, 200];
        return s[seed % 4];
    }

    function _fill(
        Case memory c,
        uint128 liquidity,
        uint256[2] memory prices,
        uint8[3] memory decs
    ) internal pure {
        c.liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        c.p0 = bound(prices[0], 1, 1e18);
        c.p1 = bound(prices[1], 1, 1e18);
        c.d0 = uint8(bound(decs[0], 6, 18));
        c.d1 = uint8(bound(decs[1], 6, 18));
        c.unitDecimals = uint8(bound(decs[2], 6, 18));
    }

    function _check(
        Case memory c
    ) internal {
        LPOracle oracle = _deploy(c);
        uint256 answer = uint256(oracle.latestAnswer());
        vm.assume(answer > 1);
        (,, uint160 s) = oracle.getPrices();
        uint256 credit = _credit(c);
        uint256 collateral = Math.mulDiv(credit, answer, 10 ** c.unitDecimals);
        assertLe(collateral, _positionValueUp(c, s), "collateral above the position's value");
    }

    /// @dev The LPVault's credit: a position on exactly the band's ticks is credited its liquidity, any other
    /// position inside the band its floor credit.
    function _credit(
        Case memory c
    ) internal pure returns (uint256) {
        if (c.tickLower == c.bandLower && c.tickUpper == c.bandUpper) return c.liquidity;
        return FloorCreditMath.credit(c.tickLower, c.tickUpper, c.bandLower, c.bandUpper, c.liquidity);
    }

    function _deploy(
        Case memory c
    ) internal returns (LPOracle) {
        BandTestToken t0 = new BandTestToken("T0", c.d0);
        BandTestToken t1 = new BandTestToken("T1", c.d1);
        vault.setMarket(MARKET, address(t0), address(t1), c.bandLower, c.bandUpper);
        // Prices are at most 1e18 < 2^255.
        // forge-lint: disable-next-line(unsafe-typecast)
        feed0.set(int256(c.p0));
        // forge-lint: disable-next-line(unsafe-typecast)
        feed1.set(int256(c.p1));
        uint256 id0 = priceSpoke.addReserve(address(t0), c.d0, address(feed0));
        uint256 id1 = priceSpoke.addReserve(address(t1), c.d1, address(feed1));
        return new LPOracle(
            ILPOracle.Params({
                lpVault: address(vault),
                marketId: MARKET,
                unitDecimals: c.unitDecimals,
                priceSpoke: address(priceSpoke),
                reserveId0: id0,
                reserveId1: id1,
                description: "fuzz"
            })
        );
    }

    /// @dev The position's amounts at `s` (clamped to its own range, as the AMM holds them) and their 8-decimal value,
    /// every step rounded up.
    function _positionValueUp(
        Case memory c,
        uint160 s
    ) internal pure returns (uint256) {
        uint160 sa = ClTickMath.getSqrtPriceAtTick(c.tickLower);
        uint160 sb = ClTickMath.getSqrtPriceAtTick(c.tickUpper);
        if (s < sa) s = sa;
        else if (s > sb) s = sb;
        uint256 a0 = SqrtPriceMath.getAmount0Delta(s, sb, c.liquidity, true);
        uint256 a1 = SqrtPriceMath.getAmount1Delta(sa, s, c.liquidity, true);
        return
            Math.mulDiv(a0, c.p0, 10 ** c.d0, Math.Rounding.Ceil)
                + Math.mulDiv(a1, c.p1, 10 ** c.d1, Math.Rounding.Ceil);
    }
}
