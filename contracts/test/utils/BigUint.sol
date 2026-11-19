// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title BigUint
/// @notice Exact unsigned integers of any size for test oracles: little-endian limbs below 2^128, so a limb product
/// plus two limbs never exceeds 2^256 − 1. Only what exact rational comparisons need: from, add, mul, compare.
library BigUint {
    uint256 private constant LIMB = 1 << 128;
    uint256 private constant MASK = LIMB - 1;

    function from(
        uint256 v
    ) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = v & MASK;
        r[1] = v >> 128;
    }

    function add(
        uint256[] memory a,
        uint256[] memory b
    ) internal pure returns (uint256[] memory r) {
        uint256 n = (a.length > b.length ? a.length : b.length) + 1;
        r = new uint256[](n);
        uint256 carry;
        for (uint256 i; i < n; ++i) {
            uint256 s = carry + (i < a.length ? a[i] : 0) + (i < b.length ? b[i] : 0);
            r[i] = s & MASK;
            carry = s >> 128;
        }
    }

    function mul(
        uint256[] memory a,
        uint256[] memory b
    ) internal pure returns (uint256[] memory r) {
        r = new uint256[](a.length + b.length);
        for (uint256 i; i < a.length; ++i) {
            uint256 carry;
            for (uint256 j; j < b.length; ++j) {
                // (2^128 − 1)^2 + 2·(2^128 − 1) = 2^256 − 1: never overflows.
                uint256 s = r[i + j] + a[i] * b[j] + carry;
                r[i + j] = s & MASK;
                carry = s >> 128;
            }
            r[i + b.length] = carry;
        }
    }

    function mul(
        uint256[] memory a,
        uint256 b
    ) internal pure returns (uint256[] memory) {
        return mul(a, from(b));
    }

    /// @return −1, 0 or 1 as `a` is below, equal to or above `b`.
    function cmp(
        uint256[] memory a,
        uint256[] memory b
    ) internal pure returns (int256) {
        uint256 n = a.length > b.length ? a.length : b.length;
        for (uint256 k = n; k > 0; --k) {
            uint256 x = k - 1 < a.length ? a[k - 1] : 0;
            uint256 y = k - 1 < b.length ? b[k - 1] : 0;
            if (x != y) return x < y ? int256(-1) : int256(1);
        }
        return 0;
    }

    function lte(
        uint256[] memory a,
        uint256[] memory b
    ) internal pure returns (bool) {
        return cmp(a, b) <= 0;
    }
}
