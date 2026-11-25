// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV2Integration} from "../../src/integrations/UniswapV2Integration.sol";
import {UniswapV2Positions} from "../../src/integrations/UniswapV2Positions.sol";
import {BandMath} from "../../src/libraries/BandMath.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {LPPriceMath} from "../../src/libraries/LPPriceMath.sol";
import {FakeUniswapV2Pair, MockUniswapV2Factory} from "../utils/mocks/UniswapV2Mocks.sol";
import {DifferentialTest} from "./utils/DifferentialTest.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title UniswapV2AavePriceDifferentialTest
/// @notice Avana's value of Uniswap v2 LP tokens against the exact `v2AaveLpValue` reference of Aave's
/// `UniswapV2PriceProvider` geometric price, `2 · √(v0 · v1) / supply` with the protocol-fee supply adjustment
/// `supply · (√k − √kLast) / (5√k + √kLast)` that Aave counts with the fee on. The non-FFI fuzz in
/// `UniswapV2Integration.fuzz.t.sol` proves the upper side in big integers; this one also bounds the lower side, so a
/// valuation far below Aave's (a lost factor, a unit or decimals slip) shows too.
contract UniswapV2AavePriceDifferentialTest is DifferentialTest {
    MockUniswapV2Factory internal factory;
    UniswapV2Integration internal vault;

    struct Case {
        uint256 r0;
        uint256 r1;
        uint256 supply;
        uint256 lp;
        uint256 kLast;
        bool feeOn;
        uint256 p0;
        uint256 p1;
        uint8 d0;
        uint8 d1;
    }

    function setUp() public {
        factory = new MockUniswapV2Factory();
        vault = new UniswapV2Integration(
            address(new AccessManager(address(this))),
            address(new UniswapV2Positions(address(factory))),
            address(factory)
        );
    }

    /// @notice Bug hunted: Avana's v2 LP value above Aave's exact geometric price in any fee state (fee on or off,
    /// `kLast` 0, below `k` or at or above it), or below it by more than its own rounding: `A ≤ V` and
    /// `V − A ≤ V / 10^6 + 2u + n · (p0' + p1' + 2) / 10^d + 2`, with `u` one liquidity unit's value rounded up,
    /// `n` the √k share, `p_i'` one raw token unit's value and `d` the unit decimals. The `V / 10^6` covers the
    /// full-range band ends, at most 6 · 10^-8 of the value while the fair price is within 2^±80 (as here). With the fee
    /// off and `kLast` below `k`, Avana counts the pending fee and Aave does not, so the lower side allows that fee.
    /// forge-config: differential.fuzz.runs = 1000
    function testFuzz_v2ValueWithinAaveGeometricPrice(
        uint256[5] memory st,
        uint256[2] memory prices,
        uint8[2] memory decs,
        uint8 feeMode
    ) public {
        Case memory c = _case(st, prices, decs, feeMode);
        uint256 num = c.p0 * 10 ** c.d1;
        uint256 den = c.p1 * 10 ** c.d0;
        vm.assume(num <= den << 80 && den <= num << 80);
        address pair = _pair(c);
        uint256 n = vault.liquidityOf(pair, c.lp);
        (uint256 answer, uint8 ud) = _answer(c);
        vm.assume(answer > 1);
        uint256 a = Math.mulDiv(n, answer, 10 ** ud);

        uint256[] memory args = new uint256[](10);
        (args[0], args[1], args[2], args[3], args[4]) = (c.r0, c.r1, c.p0, c.p1, c.d0);
        (args[5], args[6], args[7], args[8], args[9]) = (c.d1, c.lp, c.supply, c.kLast, c.feeOn ? 1 : 0);
        (uint256 v, uint256 u, uint256 aaveSupply) =
            abi.decode(_reference("v2AaveLpValue", args), (uint256, uint256, uint256));
        assertLe(a, v, "Avana's v2 LP value above Aave's geometric price");

        uint256 slack = _slack(c, n, ud, v, u);
        assertGe(aaveSupply, c.supply, "Aave never lowers the supply");
        assertGe(a + slack, v, "Avana's v2 LP value further below Aave's than its rounding");
    }

    /// @dev The lower-side allowance of the test notice.
    function _slack(
        Case memory c,
        uint256 n,
        uint8 ud,
        uint256 v,
        uint256 u
    ) internal pure returns (uint256 slack) {
        uint256 rawUnits = _rawUnitValueUp(c.p0, c.d0) + _rawUnitValueUp(c.p1, c.d1) + 2;
        slack = v / 1e6 + 2 * u + 3 + Math.mulDiv(n + 1, rawUnits, 10 ** ud);
        if (!c.feeOn && c.kLast != 0) {
            // Avana's supply is Aave's plus the fee v2-core would mint if switched on.
            uint256 rootK = Math.sqrt(c.r0 * c.r1);
            uint256 rootKLast = Math.sqrt(c.kLast);
            if (rootK > rootKLast) slack += Math.mulDiv(v, rootK - rootKLast, rootK * 5 + rootKLast) + 1;
        }
    }

    /// @dev One raw unit's 8-decimal USD value, rounded up.
    function _rawUnitValueUp(
        uint256 p,
        uint8 d
    ) internal pure returns (uint256) {
        return Math.ceilDiv(p, 10 ** d);
    }

    function _case(
        uint256[5] memory st,
        uint256[2] memory prices,
        uint8[2] memory decs,
        uint8 feeMode
    ) internal pure returns (Case memory c) {
        c.r0 = bound(st[0], 1e3, type(uint112).max);
        c.r1 = bound(st[1], 1e3, type(uint112).max);
        c.supply = bound(st[2], 1e3, type(uint128).max);
        c.lp = bound(st[3], 1, c.supply);
        uint256 k = c.r0 * c.r1;
        uint256 mode = feeMode % 3;
        c.kLast = mode == 0 ? 0 : mode == 1 ? bound(st[4], 1, k) : bound(st[4], k, type(uint256).max);
        c.feeOn = (feeMode >> 2) & 1 == 1;
        c.p0 = bound(prices[0], 1, LPPriceMath.MAX_PRICE);
        c.p1 = bound(prices[1], 1, LPPriceMath.MAX_PRICE);
        c.d0 = uint8(bound(decs[0], 0, LPPriceMath.MAX_DECIMALS));
        c.d1 = uint8(bound(decs[1], 0, LPPriceMath.MAX_DECIMALS));
    }

    function _pair(
        Case memory c
    ) internal returns (address) {
        FakeUniswapV2Pair fake = new FakeUniswapV2Pair(makeAddr("token0"), makeAddr("token1"));
        // Bound to 112 bits above.
        // forge-lint: disable-next-line(unsafe-typecast)
        fake.setReserves(uint112(c.r0), uint112(c.r1));
        fake.mintLp(address(this), c.supply);
        fake.setKLast(c.kLast);
        factory.setFeeTo(c.feeOn ? makeAddr("feeTo") : address(0));
        return address(fake);
    }

    /// @dev `LPOracle.latestAnswer` of the full-range market, step for step: the fair square-root price, the band
    /// amounts of one whole vault token and their value, at least 1; with the unit decimals `RiskModule` would list
    /// (18 when none qualifies). Built from `LPPriceMath` directly because the FFI job builds no Aave artifacts, which
    /// the AaveOracle stand-in needs; the non-FFI fuzz of `UniswapV2Integration.fuzz.t.sol` reads the real LPOracle.
    function _answer(
        Case memory c
    ) internal pure returns (uint256 answer, uint8 ud) {
        uint160 s = LPPriceMath.sqrtPriceX96(c.p0, c.p1, c.d0, c.d1);
        ud = BandMath.unitDecimals(s, ClTickMath.MIN_TICK, ClTickMath.MAX_TICK, c.p0, c.p1, c.d0, c.d1);
        if (ud == 0) ud = 18;
        (uint256 a0, uint256 a1) = LPPriceMath.amounts(
            s,
            ClTickMath.getSqrtPriceAtTick(ClTickMath.MIN_TICK),
            ClTickMath.getSqrtPriceAtTick(ClTickMath.MAX_TICK),
            uint128(10 ** ud)
        );
        answer = Math.max(LPPriceMath.value(a0, a1, c.p0, c.p1, c.d0, c.d1), 1);
    }
}
