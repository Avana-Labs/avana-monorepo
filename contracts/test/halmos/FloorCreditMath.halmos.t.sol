// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../src/integrations/shared/ClTickMath.sol";
import {FloorCreditMath} from "../../src/vault/libraries/FloorCreditMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

/// @title FloorCreditMathHalmosTest
/// @notice Bounded symbolic check that `FloorCreditMath.credit` computes the floor credit of
/// contracts/src/vault/FLOOR-CREDIT-PROOF.md: with `x, y` the position's and `X, Y` the band's square-root prices
/// and `U = 2^128 − 1`, it returns `min(⌊a0·U/u0⌋, ⌊a1·U/u1⌋)`, where `a0 = ⌊L·2^96·(y − x)/(x·y)⌋` and
/// `a1 = ⌊L·(y − x)/2^96⌋` are the position's amounts at the band edges and `u0 = ⌈U·2^96·(Y − X)/(X·Y)⌉`,
/// `u1 = ⌈U·(Y − X)/2^96⌉` those of `U` band units. The inequality the credit satisfies is proven on paper; rounding and
/// overflow are covered by the fuzz suite (`test/fuzz/FloorCreditMath.fuzz.t.sol`).
/// @dev Bounds: five fixed bands and positions near `MIN_TICK` (concrete square-root prices below `2^34`) and liquidity
/// below `2^64`. The check assumes `mulmod(p, q, 2^256 − 1) == p·q` for the four products the library's `mulDiv` calls
/// form with `L`; in these shapes each is below `2^255`, so the assumption removes no input and only rules out
/// `mulDiv`'s 512-bit branch.
contract FloorCreditMathHalmosTest is Test {
    uint256 internal constant MAX_LIQUIDITY = 2 ** 64;
    uint256 internal constant SHAPES = 5;
    uint256 internal constant U = type(uint128).max;
    uint256 internal constant Q96 = 2 ** 96;

    /// @dev Ticks and square-root prices of one position `[x, y]` inside one band `[X, Y]`.
    struct Shape {
        int24 a;
        int24 b;
        int24 ba;
        int24 bb;
        uint256 x;
        uint256 y;
        uint256 bx;
        uint256 by;
    }

    /// @dev Shape `k`: a narrow position in the middle of a wide band, one at each band edge, the whole band, and a
    /// narrow position in a narrow (stable-like) band. All ticks lie in `[MIN_TICK, −870_000]`.
    function _shape(
        uint256 k
    ) internal pure returns (Shape memory s) {
        vm.assume(k < SHAPES);
        (s.ba, s.bb) = (-880_000, -870_000);
        if (k == 0) (s.a, s.b) = (-876_000, -874_000);
        else if (k == 1) (s.a, s.b) = (-880_000, -879_000);
        else if (k == 2) (s.a, s.b) = (-871_000, -870_000);
        else if (k == 3) (s.a, s.b) = (s.ba, s.bb);
        else (s.a, s.b, s.ba, s.bb) = (-878_960, -878_940, -879_000, -878_900);
        s.x = ClTickMath.getSqrtPriceAtTick(s.a);
        s.y = ClTickMath.getSqrtPriceAtTick(s.b);
        s.bx = ClTickMath.getSqrtPriceAtTick(s.ba);
        s.by = ClTickMath.getSqrtPriceAtTick(s.bb);
    }

    /// @dev See the contract's `@dev`: states that the high word of `p·q` is 0, as `mulDiv` tests it.
    function _assumeExactProduct(
        uint256 p,
        uint256 q
    ) internal pure {
        unchecked {
            vm.assume(mulmod(p, q, type(uint256).max) == p * q);
            vm.assume(mulmod(p, q, type(uint256).max) == q * p);
        }
    }

    /// @notice The library's credit equals the formula in plain arithmetic on the same terms.
    function check_creditMatchesReference(
        uint256 k,
        uint128 liquidity
    ) public pure {
        Shape memory s = _shape(k);
        vm.assume(liquidity < MAX_LIQUIDITY);
        // The band unit's amounts are concrete.
        uint256 u0 = Math.ceilDiv(Math.mulDiv(U * Q96, s.by - s.bx, s.by, Math.Rounding.Ceil), s.bx);
        uint256 u1 = Math.mulDiv(U, s.by - s.bx, Q96, Math.Rounding.Ceil);
        // The position's amounts and the two sides.
        uint256 a0 = liquidity * Q96 * (s.y - s.x) / s.y / s.x;
        uint256 a1 = liquidity * (s.y - s.x) / Q96;
        uint256 side0 = a0 * U / u0;
        uint256 side1 = a1 * U / u1;
        _assumeExactProduct(uint256(liquidity) * Q96, s.y - s.x);
        _assumeExactProduct(liquidity, s.y - s.x);
        _assumeExactProduct(a0, U);
        _assumeExactProduct(a1, U);
        uint256 credit = FloorCreditMath.credit(s.a, s.b, s.ba, s.bb, liquidity);
        assert(credit == (side0 < side1 ? side0 : side1));
    }
}
