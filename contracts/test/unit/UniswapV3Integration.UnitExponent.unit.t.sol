// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {RiskMetadata} from "../../src/amm/types/RiskMetadata.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {MintableToken, MockV3Pool} from "../utils/mocks/UniswapV3Mocks.sol";

/// @title UniswapV3IntegrationUnitExponentUnitTest
/// @notice The concentrated-liquidity unit exponent `k` (2.10 `SPEC-ORC-005`, 2.4 `SPEC-UNIT-002`): two 18-decimal $1
/// tokens list on narrow ranges with one vault-token unit = `10^k` liquidity, `k` fixed per pool at its first binding;
/// every unit amount the integration reports or takes is in those units.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationUnitExponentUnitTest is UniswapV3IntegrationFixture {
    MintableToken internal a18;
    MintableToken internal b18;
    MockV3Pool internal pool18;

    function setUp() public override {
        super.setUp();
        a18 = new MintableToken("GHO", 18);
        b18 = new MintableToken("USDS", 18);
        pool18 = MockV3Pool(v3Factory.createPool(address(a18), address(b18), 100, 1));
    }

    function _try(
        uint256 id,
        int24 lower,
        int24 upper
    ) internal returns (bool ok, uint8 d) {
        vm.prank(registry);
        try vault.bindMarket(
            id,
            address(pool18),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, lower, upper),
            abi.encode(uint256(1e8), uint256(1e8))
        ) returns (
            address[] memory, uint8 dd
        ) {
            return (true, dd);
        } catch {
            return (false, 0);
        }
    }

    // TEST-264 verifies: SPEC-ORC-005, SPEC-UNIT-001, SPEC-UNIT-002, REQ-AMM-CORE-003
    /// @notice The `SPEC-ORC-005` example: GHO/USDS at $1 on the 0.01 % tier takes `k = 7` at its first binding, and
    /// `[−10, 10]`, `[−100, 100]`, `[−1,000, 1,000]` and the full range list at `d = 15, 14, 13, 11` (with `k = 0` none
    /// of the ranges narrower than about ±20,000 ticks could list).
    function test_TEST_264_narrow18x18StableRangesList() public {
        int24[4] memory w = [int24(10), 100, 1000, 887_272];
        uint8[4] memory want = [uint8(15), 14, 13, 11];
        for (uint256 i = 0; i < w.length; ++i) {
            (bool ok, uint8 d) = _try(10 + i, -w[i], w[i]);
            assertTrue(ok, "listable");
            assertEq(d, want[i], "decimals");
            assertEq(vault.unitExponent(10 + i), 7, "one exponent for the pool");
        }
    }

    // TEST-264 verifies: SPEC-ORC-005
    /// @notice The exponent is the pool's: a later market of the same pool keeps the first one's `k` whatever its
    /// range, while a 6-decimal pool keeps `k = 0` (units equal liquidity, as before).
    function test_TEST_264_exponentFixedPerPool() public {
        (bool ok,) = _try(20, -887_272, 887_272);
        assertTrue(ok);
        assertEq(vault.unitExponent(20), 7, "full range first: the reference range still fixes k");
        (ok,) = _try(21, -10, 10);
        assertTrue(ok);
        assertEq(vault.unitExponent(21), 7);
        assertEq(vault.unitExponent(M1), 0, "USDC/USDT keeps k = 0");
        assertEq(vault.unitExponent(M2), 0);
    }

    // TEST-264 verifies: SPEC-UNIT-002, REQ-VAULT-162, REQ-AMM-V3-006, SPEC-BACK-008
    /// @notice A position of liquidity `L` credits `⌊L / 10^7⌋` units, `unitsOf` and `riskMetadata` report units, and
    /// an unwind of `u` units removes exactly `u × 10^7` liquidity; the remainder below one unit stays with the NFT.
    function test_TEST_264_unitsAreScaledLiquidity() public {
        (bool ok,) = _try(30, -10, 10);
        assertTrue(ok);
        uint128 liquidity = 123_456_789_012_345_678_901_234;
        bytes32 key = _mint(alice, pool18, -10, 10, liquidity);
        a18.mint(address(nfpm), 1e30);
        b18.mint(address(nfpm), 1e30);
        uint128 units = _receive(30, alice, key);
        assertEq(units, liquidity / 1e7, "credited units");
        _lock();
        vm.prank(coll);
        assertEq(vault.unitsOf(key), units, "unitsOf in units");
        _unlock();
        RiskMetadata memory meta = vault.riskMetadata(30, key);
        assertEq(meta.positionUnits, units, "positionUnits in units");
        uint128 u = units / 3;
        uint256[] memory mins = new uint256[](2);
        _asColl(abi.encodeCall(vault.unwind, (key, u, mins, bob)));
        (,,,,,,, uint128 left,,,,) = nfpm.positions(uint256(key));
        assertEq(left, liquidity - uint128(u) * 1e7, "removed exactly u x 10^k liquidity");
        _lock();
        vm.prank(coll);
        assertEq(vault.unitsOf(key), units - u, "units left");
        _unlock();
    }

    // TEST-264 verifies: SPEC-ORC-005, SPEC-ORC-006, SPEC-AMM-V3-001
    /// @notice `composition(units)` values `units × 10^k` liquidity: one whole token (`10^15` units on `[−10, 10]`) is
    /// worth at least $1 at par and `10^14` units are worth less.
    function test_TEST_264_compositionOfScaledUnits() public {
        (bool ok, uint8 d) = _try(40, -10, 10);
        assertTrue(ok);
        uint256[] memory peg = new uint256[](2);
        (peg[0], peg[1]) = (1e8, 1e8);
        (uint256[] memory whole,) = vault.composition(40, 10 ** d, peg);
        (uint256[] memory tenth,) = vault.composition(40, 10 ** (d - 1), peg);
        assertGe(whole[0] + whole[1], 1e18, "a whole token holds at least $1 of the two $1 tokens");
        assertLt(tenth[0] + tenth[1], 1e18, "a tenth of it holds less");
        uint160 sa = ClPriceMath.sqrtRatioAtTick(-10);
        uint160 sb = ClPriceMath.sqrtRatioAtTick(10);
        (uint256 r0, uint256 r1) =
            ClPriceMath.amountsForLiquidity(ClPriceMath.sqrtRatioAtTick(0), sa, sb, 10 ** (d + 7));
        assertEq(whole[0], r0 - 1, "token0 of 10^(d + k) liquidity, one raw unit off");
        assertEq(whole[1], r1 - 1, "token1 of 10^(d + k) liquidity, one raw unit off");
    }

    // TEST-264 verifies: SPEC-ORC-005
    /// @notice A market of the pool whose range is worth far less than the reference range per unit of liquidity
    /// (one tick about 200,000 ticks above the price) needs `d > 18` at the pool's `k` and is refused `InvalidPool`.
    function test_TEST_264_rangeFarFromThePriceRefused() public {
        (bool ok,) = _try(50, -10, 10);
        assertTrue(ok, "the pool's first market fixes k = 7");
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(
            51,
            address(pool18),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, 200_000, 200_001),
            abi.encode(uint256(1e8), uint256(1e8))
        );
    }

    // TEST-264 verifies: SPEC-ORC-005
    /// @notice The reference range is the spacing holding the price's tick, rounded toward −∞: a $1/$2 pair of two
    /// 18-decimal tokens on spacing 10 sits at tick −6,932, so its reference range is `[−6,940, −6,930]`, and the pool
    /// lists with the exponent that range gives.
    function test_TEST_264_negativeTickReferenceRange() public {
        MockV3Pool p10 = MockV3Pool(v3Factory.createPool(address(a18), address(b18), 500, 10));
        vm.prank(registry);
        (, uint8 d) = vault.bindMarket(
            60,
            address(p10),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -7000, -6900),
            abi.encode(uint256(1e8), uint256(2e8))
        );
        assertEq(vault.unitExponent(60), 6, "one 10-tick spacing of a $1/$2 pair needs 10^24 liquidity for $1");
        assertGe(d, 6);
        assertLe(d, 18);
    }
}
