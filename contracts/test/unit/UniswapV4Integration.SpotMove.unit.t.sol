// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {UniswapV4IntegrationFixture} from "../utils/fixtures/UniswapV4IntegrationFixture.sol";

/// @title UniswapV4IntegrationSpotMoveUnitTest
/// @notice The integration half of TEST-266 on the Uniswap v4 LPVault (USDC/USDT, fee 100, spacing 1): the composition
/// of market 1 (`[-50, 50]`, two 6-decimal tokens) reads only the oracle price vector, so moving the PoolManager's spot
/// to 0.5x, 2x and 4x the oracle price, to each range edge and beyond it, and to the tick bounds changes no amount to
/// the wei; the quote never decreases when units increase; and a pledge made at a moved spot credits the same units.
/// The same suite as the Uniswap v3 and Slipstream LPVaults'.
/// forge-config: default.isolate = false
contract UniswapV4IntegrationSpotMoveUnitTest is UniswapV4IntegrationFixture {
    /// @dev Spot ticks: 0.5x, 2x and 4x of a 1:1 oracle price, the range edges, one tick beyond each edge, and the
    /// tick bounds.
    function _spots() internal pure returns (int24[9] memory s) {
        s = [int24(-6932), 6931, 13_863, -50, 50, -51, 51, ClPriceMath.MIN_TICK + 1, ClPriceMath.MAX_TICK - 1];
    }

    function _moveTo(
        int24 tick
    ) internal {
        _swapV4To(stableKey, ClPriceMath.sqrtRatioAtTick(tick));
    }

    function _comp(
        uint256 units,
        uint256 p0,
        uint256 p1
    ) internal view returns (uint256[] memory a) {
        (a,) = vault.composition(M1, units, _vec(p0, p1));
    }

    function _assertSpotInvariant(
        uint256 units,
        uint256 p0,
        uint256 p1
    ) internal {
        uint256[] memory base = _comp(units, p0, p1);
        int24[9] memory spots = _spots();
        for (uint256 i = 0; i < spots.length; ++i) {
            _moveTo(spots[i]);
            uint256[] memory moved = _comp(units, p0, p1);
            assertEq(moved[0], base[0], string.concat("token0 at spot tick ", vm.toString(spots[i])));
            assertEq(moved[1], base[1], string.concat("token1 at spot tick ", vm.toString(spots[i])));
        }
        _moveTo(0);
    }

    // TEST-266 verifies: SPEC-ORC-006, REQ-AMM-CORE-012, REQ-AMM-V4-005, INV-078, Q-359, Q-366
    /// @notice With the oracle at 1:1, above the range and below it, every move of the PoolManager's spot leaves the
    /// composition unchanged; above the range the units are all token1 and below it all token0.
    /// @dev Kills: any read of the pool's `slot0` price or tick in the composition.
    function test_TEST_266_compositionUnchangedAtSpotMultiplesAndRangeEdges() public {
        _assertSpotInvariant(1e9, 1e8, 1e8);
        _assertSpotInvariant(1e9, 1e8, 64_000_000);
        _assertSpotInvariant(1e9, 64_000_000, 1e8);
        uint256[] memory above = _comp(1e9, 1e8, 64_000_000);
        assertEq(above[0], 0, "oracle above the range: no token0");
        assertGt(above[1], 0, "all token1 at the upper edge");
        uint256[] memory below = _comp(1e9, 64_000_000, 1e8);
        assertGt(below[0], 0, "all token0 at the lower edge");
        assertEq(below[1], 0, "oracle below the range: no token1");
    }

    // TEST-266 verifies: SPEC-ORC-006, INV-078, Q-359
    /// @notice For any units, oracle price and spot tick, the composition ignores the spot, and its value at the
    /// oracle prices never decreases when units increase.
    function testFuzz_TEST_266_compositionIgnoresSpotAndIsMonotoneInUnits(
        uint128 units,
        uint128 more,
        int24 spotSeed,
        uint256 p1Seed
    ) public {
        units = uint128(bound(units, 1, 1e24));
        more = uint128(bound(more, 0, 1e24));
        uint256 p1 = bound(p1Seed, 50_000_000, 200_000_000);
        int24 spot = int24(bound(int256(spotSeed), ClPriceMath.MIN_TICK + 1, ClPriceMath.MAX_TICK - 1));
        uint256[] memory a = _comp(units, 1e8, p1);
        _moveTo(spot);
        uint256[] memory b = _comp(units, 1e8, p1);
        assertEq(b[0], a[0], "token0");
        assertEq(b[1], a[1], "token1");
        uint256[] memory c = _comp(uint256(units) + more, 1e8, p1);
        assertGe(c[0] * 1e8 + c[1] * p1, a[0] * 1e8 + a[1] * p1, "the quote never decreases with units");
    }

    // TEST-266 verifies: REQ-AMM-CORE-005, REQ-AMM-V4-003, INV-078, Q-366
    /// @notice A pledge made while the spot sits at 4x the oracle price credits exactly the position's liquidity in
    /// units, the same as at the oracle price.
    function test_TEST_266_pledgeAtAMovedSpotCreditsTheSameUnits() public {
        _moveTo(13_863);
        bytes32 moved = _mintFor(alice, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 creditedMoved = _receive(M1, alice, moved);
        _moveTo(0);
        bytes32 still = _mintFor(bob, stableKey, M1_LOWER, M1_UPPER, 1e15);
        uint128 creditedStill = _receive(M1, bob, still);
        assertEq(creditedMoved, uint128(1e15 / 10 ** vault.unitExponent(M1)), "liquidity in units, whatever the spot");
        assertEq(creditedMoved, creditedStill);
    }
}
