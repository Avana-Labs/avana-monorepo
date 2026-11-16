// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {RiskMetadata} from "../../src/amm/types/RiskMetadata.sol";
import {UniswapV4State} from "../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV4PoolManager} from "../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title UniswapV4IntegrationUnitExponentUnitTest
/// @notice The concentrated-liquidity unit exponent `k` (2.10 `SPEC-ORC-005`, 2.4 `SPEC-UNIT-002`) on the Uniswap v4
/// LPVault: two 18-decimal $1 tokens list on narrow ranges with one vault-token unit = `10^k` liquidity, `k` fixed per
/// pool at its first binding; every unit amount the integration reports or takes is in those units. The same suite as
/// the Uniswap v3 LPVault's.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationUnitExponentUnitTest is UniswapV4IntegrationFixture {
    ClTestToken internal a18;
    ClTestToken internal b18;
    PoolKey internal key18;
    IClPool internal ref18;

    function setUp() public override {
        super.setUp();
        a18 = new ClTestToken("GHO", 18);
        b18 = new ClTestToken("USDS", 18);
        (address x, address y) =
            address(a18) < address(b18) ? (address(a18), address(b18)) : (address(b18), address(a18));
        key18 = _key(x, y, 100, 1);
        _initPool(key18, ONE, ONE, 18, 18);
        ref18 = _referencePool(address(a18), address(b18), ONE, ONE, CARDINALITY, 1e18);
    }

    function _try(
        PoolKey memory key,
        uint256 id,
        int24 lower,
        int24 upper,
        uint256 p0,
        uint256 p1
    ) internal returns (bool ok, uint8 d) {
        vm.prank(registry);
        try vault.bindMarket(
            id,
            address(0),
            _poolId(key),
            PositionShape(ShapeKind.TickRange, lower, upper),
            _bindData(key, address(ref18), p0, p1)
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
    /// `[−10, 10]`, `[−100, 100]`, `[−1,000, 1,000]` and the full range list at `d = 15, 14, 13, 11`.
    function test_TEST_264_narrow18x18StableRangesList() public {
        int24[4] memory w = [int24(10), 100, 1000, 887_272];
        uint8[4] memory want = [uint8(15), 14, 13, 11];
        for (uint256 i = 0; i < w.length; ++i) {
            (bool ok, uint8 d) = _try(key18, 10 + i, -w[i], w[i], ONE, ONE);
            assertTrue(ok, "listable");
            assertEq(d, want[i], "decimals");
            assertEq(vault.unitExponent(10 + i), 7, "one exponent for the pool");
        }
    }

    // TEST-264 verifies: SPEC-ORC-005
    /// @notice The exponent is the pool's: a later market of the same pool keeps the first one's `k` whatever its
    /// range, while the 6-decimal USDC/USDT pool keeps `k = 0`.
    function test_TEST_264_exponentFixedPerPool() public {
        (bool ok,) = _try(key18, 20, -887_272, 887_272, ONE, ONE);
        assertTrue(ok);
        assertEq(vault.unitExponent(20), 7, "full range first: the reference range still fixes k");
        (ok,) = _try(key18, 21, -10, 10, ONE, ONE);
        assertTrue(ok);
        assertEq(vault.unitExponent(21), 7);
        assertEq(vault.unitExponent(M1), 0, "USDC/USDT keeps k = 0");
    }

    // TEST-264 verifies: SPEC-UNIT-002, REQ-VAULT-162, REQ-AMM-V4-003, SPEC-BACK-008
    /// @notice A position of liquidity `L` credits `⌊L / 10^7⌋` units, `unitsOf` and `riskMetadata` report units, and
    /// an unwind of `u` units removes exactly `u × 10^7` liquidity from the PoolManager position; the remainder below
    /// one unit stays with the NFT.
    function test_TEST_264_unitsAreScaledLiquidity() public {
        (bool ok,) = _try(key18, 30, -10, 10, ONE, ONE);
        assertTrue(ok);
        uint128 liquidity = 123_456_789_012_345_678_901_234;
        bytes32 key = _mintFor(alice, key18, -10, 10, liquidity);
        uint128 units = _receive(30, alice, key);
        assertEq(units, liquidity / 1e7, "credited units");
        assertEq(vault.unitsOf(key), units, "unitsOf in units");
        RiskMetadata memory meta = vault.riskMetadata(30, key);
        assertEq(meta.positionUnits, units, "positionUnits in units");
        uint128 u = units / 3;
        _unwind(key, u, _zeros(), lpVaultSwap);
        assertEq(_liquidityOf(key18, key, -10, 10), liquidity - uint128(u) * 1e7, "removed exactly u x 10^k liquidity");
        assertEq(vault.unitsOf(key), units - u, "units left");
    }

    // TEST-264 verifies: SPEC-ORC-005, SPEC-ORC-006, SPEC-AMM-CORE-001
    /// @notice `composition(units)` values `units × 10^k` liquidity: one whole token (`10^15` units on `[−10, 10]`) is
    /// worth at least $1 at par and `10^14` units are worth less.
    function test_TEST_264_compositionOfScaledUnits() public {
        (bool ok, uint8 d) = _try(key18, 40, -10, 10, ONE, ONE);
        assertTrue(ok);
        (uint256[] memory whole,) = vault.composition(40, 10 ** d, _vec(ONE, ONE));
        (uint256[] memory tenth,) = vault.composition(40, 10 ** (d - 1), _vec(ONE, ONE));
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
        (bool ok,) = _try(key18, 50, -10, 10, ONE, ONE);
        assertTrue(ok, "the pool's first market fixes k = 7");
        vm.prank(registry);
        vm.expectRevert(InvalidPool.selector);
        vault.bindMarket(
            51,
            address(0),
            _poolId(key18),
            PositionShape(ShapeKind.TickRange, 200_000, 200_001),
            _bindData(key18, address(ref18), ONE, ONE)
        );
    }

    // TEST-264 verifies: SPEC-ORC-005
    /// @notice The reference range is the spacing holding the price's tick, rounded toward −∞: a $1/$2 pair of two
    /// 18-decimal tokens on spacing 10 sits at tick −6,932, so its reference range is `[−6,940, −6,930]`, and the pool
    /// lists with the exponent that range gives.
    function test_TEST_264_negativeTickReferenceRange() public {
        PoolKey memory k10 = _key(Currency.unwrap(key18.currency0), Currency.unwrap(key18.currency1), 500, 10);
        _initPool(k10, ONE, 2 * ONE, 18, 18);
        (bool ok, uint8 d) = _try(k10, 60, -7000, -6900, ONE, 2 * ONE);
        assertTrue(ok);
        assertEq(vault.unitExponent(60), 6, "one 10-tick spacing of a $1/$2 pair needs 10^24 liquidity for $1");
        assertGe(d, 6);
        assertLe(d, 18);
    }

    /// @dev The PoolManager's liquidity of the PositionManager position `positionKey` on `[lower, upper]`.
    function _liquidityOf(
        PoolKey memory k,
        bytes32 positionKey,
        int24 lower,
        int24 upper
    ) internal view returns (uint128) {
        IUniswapV4PoolManager m = IUniswapV4PoolManager(address(pm));
        return UniswapV4State.position(
            m, _poolId(k), UniswapV4State.positionId(address(posm), lower, upper, positionKey)
        )
        .liquidity;
    }
}
