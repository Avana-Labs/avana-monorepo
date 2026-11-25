// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

interface IObservationPool {
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) external;
}

/// @notice Grows a Uniswap v3 or Slipstream pool's observation cardinality in steps of at most `MAX_STEP` slots, one
/// transaction each. `Oracle.grow` writes every new slot (about 22,200 gas), so 750 slots in one call would reach a
/// network's per-transaction gas cap (16,777,216 under EIP-7825).
library CardinalityGrowth {
    /// @notice The most slots one `increaseObservationCardinalityNext` call adds.
    uint16 internal constant MAX_STEP = 500;

    /// @notice The `cardinalityNext` one grow transaction sets from `current` toward `target`: `current` itself when it
    /// already reaches `target`, otherwise `min(target, current + MAX_STEP)`.
    function nextStep(
        uint16 current,
        uint16 target
    ) internal pure returns (uint16) {
        if (current >= target) return current;
        uint256 n = uint256(current) + MAX_STEP;
        return n < target ? uint16(n) : target;
    }

    /// @notice Raises `pool`'s `observationCardinalityNext` to at least `target`, each call adding at most `MAX_STEP`
    /// slots; no call when the pool already has enough.
    function grow(
        address pool,
        uint16 target
    ) internal {
        uint16 current = cardinalityNext(pool);
        while (current < target) {
            uint16 n = nextStep(current, target);
            IObservationPool(pool).increaseObservationCardinalityNext(n);
            current = n;
        }
    }

    /// @notice The pool's `observationCardinalityNext`: word 4 of `slot0()` in both Uniswap v3 (7 words) and Slipstream
    /// (6 words).
    function cardinalityNext(
        address pool
    ) internal view returns (uint16 next) {
        (bool ok, bytes memory ret) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok && ret.length >= 160, "slot0 unreadable");
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 160))
        }
        next = uint16(word);
    }
}
