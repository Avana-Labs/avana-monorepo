// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ClMarketConfig} from "../../src/amm/types/ClMarketConfig.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {SlipstreamIntegrationFixture} from "../utils/fixtures/SlipstreamIntegrationFixture.sol";
import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {MockCLPool} from "../utils/mocks/SlipstreamMocks.sol";
import {MintableToken, MockV3Pool} from "../utils/mocks/UniswapV3Mocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Shared helpers of the review PoCs: a 6-decimal token0 and an 18-decimal token1, and the value of a
/// composition at 8-decimal prices.
library ReviewMath {
    /// @dev `Σ a_i * p_i / 10^d_i`, floored (SPEC-AMM-CORE-001 without the max(1, ·)).
    function value8(
        uint256 a0,
        uint256 a1,
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint256) {
        return Math.mulDiv(a0, p0, 10 ** d0) + Math.mulDiv(a1, p1, 10 ** d1);
    }

    /// @dev The true oracle square-root price for a raw ratio at or above 2^64, where `oracleSqrtPrice` saturates:
    /// `isqrt(num * 2^128 / den) * 2^32`, floored (below the exact value, so it never overstates the true holding).
    function trueSqrtAboveSaturation(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal pure returns (uint160) {
        uint256 num = p0 * 10 ** d1;
        uint256 den = p1 * 10 ** d0;
        return uint160(Math.sqrt(Math.mulDiv(num, 2 ** 128, den)) << 32);
    }
}

/// @notice Review PoCs on the Slipstream LPVault (production contract, mock generations).
/// forge-config: default.isolate = false
contract SlipstreamReviewPoC is SlipstreamIntegrationFixture {
    uint256 internal constant M3 = 3;

    /// @dev Deploys a 6-decimal and an 18-decimal token with the 6-decimal one as token0 (lower address).
    function _pair6_18() internal returns (MintableToken t0, MintableToken t1) {
        t1 = new MintableToken("T18", 18);
        t0 = new MintableToken("T6", 6);
        while (address(t0) > address(t1)) {
            t0 = new MintableToken("T6", 6);
        }
    }

    // CL-01: the 2^64 saturation of SPEC-ORC-009 makes `composition` overstate a full-range position by ~10^9.
    function test_POC_CL01_saturatedOracleSqrtOvervaluesAFullRangeMarket() public {
        (MintableToken t0, MintableToken t1) = _pair6_18();
        MockCLPool pool = MockCLPool(factories[G2].createPool(address(t0), address(t1), 100));
        // Listed at $1 / $1: the raw ratio is 10^12, and a 100x shock (10^14) stays far below 2^64 (TEST-139 guard).
        _bind(M3, address(pool), G2, -FULL_100, FULL_100);

        // token1 (18 decimals) collapses to 5 * 10^-8 USD; token0 stays at $1. Raw ratio = 2 * 10^19 >= 2^64.
        uint256 p0 = 1e8;
        uint256 p1 = 5;
        (uint160 sO,, bool clamped) = vault.oracleSqrtPrice(M3, _vec(p0, p1));
        assertEq(sO, ClPriceMath.MAX_SQRT_RATIO - 1, "saturated to MAX_SQRT_RATIO - 1");
        assertTrue(clamped);
        uint160 sTrue = ReviewMath.trueSqrtAboveSaturation(p0, p1, 6, 18);
        assertLt(sTrue, sO / 1e9, "the true sqrt price is about 3.5e38, nine orders below the saturated value");

        uint256 units = 5e15; // about $10,000 of liquidity at listing
        (uint256[] memory c,) = vault.composition(M3, units, _vec(p0, p1));
        (uint256 t0Amt, uint256 t1Amt) = ClPriceMath.amountsForLiquidity(
            sTrue, ClPriceMath.sqrtRatioAtTick(-FULL_100), ClPriceMath.sqrtRatioAtTick(FULL_100), units
        );
        uint256 quoted = ReviewMath.value8(c[0], c[1], p0, p1, 6, 18);
        uint256 fair = ReviewMath.value8(t0Amt, t1Amt, p0, p1, 6, 18);
        emit log_named_uint("composition value8 (saturated)", quoted);
        emit log_named_uint("fair value8 at the true oracle ratio", fair);
        emit log_named_uint("token1 quoted", c[1]);
        emit log_named_uint("token1 actually held at the oracle ratio", t1Amt);
        assertEq(c[0], 0, "valued as all token1");
        assertGt(quoted, fair * 1e8, "composition overstates the fair value by more than 10^8");
    }

    // CL-02: a key of another generation is refused only through the pool derivation, never by its generation byte.
    function test_POC_CL02_crossGenerationKeyIsNotCheckedAgainstTheMarketGeneration() public {
        // Precondition the LPVault does not rule out itself: generation 0's factory resolves the pair and spacing of
        // market 1 to market 1's pool (generation 2).
        factories[0].register(pool1.token0(), pool1.token1(), 1, address(pool1));
        uint256 id = npms[0].mint(alice, pool1.token0(), pool1.token1(), 1, M1_LOWER, M1_UPPER, 1e9);
        vm.prank(alice);
        npms[0].approve(address(vault), id);
        bytes32 key0 = _key(0, id);

        uint128 units = _receive(M1, alice, key0);
        assertEq(units, 1e9, "a generation-0 NFT is credited in a generation-2 market");
        assertEq(vault.marketOfPosition(key0), M1);
        assertEq(npms[0].ownerOf(id), address(vault), "custody sits on generation 0's manager");
        ClMarketConfig memory cfg = vault.clMarket(M1);
        assertEq(cfg.positionManager, address(npms[G1]), "the market is pinned to generation 2's manager");
        assertTrue(uint256(key0) >> 248 != G1, "the key's generation byte differs from the market's");
    }

    // CL-03: a factory-enabled spacing of 6,932 or more binds a market whose per-tick liquidity bound exceeds 2^120 - 1.
    function test_POC_CL03_largeSpacingBindsAboveTheCreditedLiquidityBound() public {
        factories[G2].enableTickSpacing(8000, 10_000);
        MockCLPool pool = MockCLPool(factories[G2].createPool(address(usdc), address(usdt), 8000));
        int24 full = 880_000; // floor(887,272 / 8,000) * 8,000
        _bind(M3, address(pool), G2, -full, full);
        ClMarketConfig memory cfg = vault.clMarket(M3);
        emit log_named_uint("maxLiquidityPerTick(8000)", cfg.maxLiquidityPerTick);
        assertGt(cfg.maxLiquidityPerTick, type(uint120).max, "per-tick bound above MAX_CREDITED_LIQUIDITY");

        // Two records, each below Collateralization's per-record bound, fit the pool's per-tick bound together and
        // exceed REQ-AMM-SLIP-014's market bound of 2^120 - 1.
        uint128 l1 = 8e35;
        uint128 l2 = 7e35;
        assertLe(uint256(l1) + l2, cfg.maxLiquidityPerTick, "fits the pool's per-tick bound");
        uint256 i1 = npms[G2].mint(alice, pool.token0(), pool.token1(), 8000, -full, full, l1);
        uint256 i2 = npms[G2].mint(bob, pool.token0(), pool.token1(), 8000, -full, full, l2);
        uint128 u1 = vault.validatePosition(M3, alice, _key(G2, i1));
        uint128 u2 = vault.validatePosition(M3, bob, _key(G2, i2));
        assertLt(u1, type(uint120).max);
        assertLt(u2, type(uint120).max);
        assertGt(uint256(u1) + u2, type(uint120).max, "market total above 2^120 - 1");
    }

    // CL-04: fee collection is accepted while LPVaultSwap, not the AaveAdapter, holds the Lock.
    function test_POC_CL04_collectFeesAcceptsLPVaultSwapAsHolder() public {
        bytes32 key = _pledge1(alice, 1e9);
        vm.prank(lpVaultSwap);
        lock.acquire();
        assertEq(lock.holder(), lpVaultSwap);
        vm.prank(coll);
        vault.collectFees(key, alice);
        vm.prank(lpVaultSwap);
        lock.release();
    }
}

/// @notice Review PoCs on the Uniswap v3 LPVault (mock-factory harness: only the init code hash differs).
/// forge-config: default.isolate = false
contract UniswapV3ReviewPoC is UniswapV3IntegrationFixture {
    uint256 internal constant M3 = 3;

    function _pair6_18() internal returns (MintableToken t0, MintableToken t1) {
        t1 = new MintableToken("T18", 18);
        t0 = new MintableToken("T6", 6);
        while (address(t0) > address(t1)) {
            t0 = new MintableToken("T6", 6);
        }
    }

    // CL-01 on Uniswap v3: the same saturation in the shared ClPriceMath, on a full-range market of the 0.3% tier.
    function test_POC_CL01_saturatedOracleSqrtOvervaluesAFullRangeMarket() public {
        (MintableToken t0, MintableToken t1) = _pair6_18();
        MockV3Pool pool = MockV3Pool(v3Factory.createPool(address(t0), address(t1), 3000, 60));
        vm.prank(registry);
        vault.bindMarket(
            M3,
            address(pool),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -FULL_60, FULL_60),
            abi.encode(uint256(1e8), uint256(1e8))
        );

        uint256 p0 = 1e8;
        uint256 p1 = 5;
        uint256 units = 5e15;
        (uint256[] memory c,) = vault.composition(M3, units, _vec(p0, p1));
        uint160 sTrue = ReviewMath.trueSqrtAboveSaturation(p0, p1, 6, 18);
        (uint256 t0Amt, uint256 t1Amt) = ClPriceMath.amountsForLiquidity(
            sTrue, ClPriceMath.sqrtRatioAtTick(-FULL_60), ClPriceMath.sqrtRatioAtTick(FULL_60), units
        );
        uint256 quoted = ReviewMath.value8(c[0], c[1], p0, p1, 6, 18);
        uint256 fair = ReviewMath.value8(t0Amt, t1Amt, p0, p1, 6, 18);
        emit log_named_uint("composition value8 (saturated)", quoted);
        emit log_named_uint("fair value8 at the true oracle ratio", fair);
        assertGt(quoted, fair * 1e8, "composition overstates the fair value by more than 10^8");
    }

    // CL-04 on Uniswap v3.
    function test_POC_CL04_collectFeesAcceptsLPVaultSwapAsHolder() public {
        bytes32 key = _pledge1(alice, 1e9);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(coll);
        vault.collectFees(key, alice);
        vm.prank(lpVaultSwap);
        lock.release();
    }
}
