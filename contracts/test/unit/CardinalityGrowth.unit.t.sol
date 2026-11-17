// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CardinalityGrowth} from "../../script/deploy/lib/CardinalityGrowth.sol";
import {Test} from "forge-std/Test.sol";

/// @notice A pool's `slot0` and `increaseObservationCardinalityNext` as Uniswap v3 keeps them: the call only raises,
/// and every slot it adds is counted per call.
contract MockObservationPool {
    uint16 public next;
    uint16 public maxAdded;
    uint256 public calls;

    constructor(
        uint16 next_
    ) {
        next = next_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (2 ** 96, 0, 0, next, next, 0, true);
    }

    function increaseObservationCardinalityNext(
        uint16 n
    ) external {
        calls++;
        if (n <= next) return;
        if (n - next > maxAdded) maxAdded = n - next;
        next = n;
    }
}

/// @notice Exposes the library to external calls.
contract CardinalityGrowthHarness {
    function grow(
        address pool,
        uint16 target
    ) external {
        CardinalityGrowth.grow(pool, target);
    }

    function nextStep(
        uint16 current,
        uint16 target
    ) external pure returns (uint16) {
        return CardinalityGrowth.nextStep(current, target);
    }
}

contract CardinalityGrowthTest is Test {
    CardinalityGrowthHarness internal h = new CardinalityGrowthHarness();

    /// 151 to 901 (Base at 2 s blocks): two calls, 500 then 250 slots.
    function test_grow_baseTarget_twoCallsOfAtMost500() public {
        MockObservationPool p = new MockObservationPool(151);
        h.grow(address(p), 901);
        assertEq(p.next(), 901);
        assertEq(p.calls(), 2);
        assertEq(p.maxAdded(), 500);
    }

    /// From a new pool (cardinality 1) to 901: 500, then 400.
    function test_grow_newPool_twoCalls() public {
        MockObservationPool p = new MockObservationPool(1);
        h.grow(address(p), 901);
        assertEq(p.next(), 901);
        assertEq(p.calls(), 2);
        assertEq(p.maxAdded(), 500);
    }

    /// A pool that already has enough is not called.
    function test_grow_enough_noCall() public {
        MockObservationPool p = new MockObservationPool(901);
        h.grow(address(p), 151);
        assertEq(p.calls(), 0);
        assertEq(p.next(), 901);
    }

    /// No single call adds more than 500 slots, the pool ends at the target, and the calls are the fewest that allow.
    function testFuzz_grow_noCallAbove500(
        uint16 start,
        uint16 target
    ) public {
        start = uint16(bound(start, 1, type(uint16).max));
        MockObservationPool p = new MockObservationPool(start);
        h.grow(address(p), target);
        assertLe(p.maxAdded(), CardinalityGrowth.MAX_STEP);
        if (target <= start) {
            assertEq(p.calls(), 0);
            assertEq(p.next(), start);
        } else {
            assertEq(p.next(), target);
            assertEq(p.calls(), (uint256(target) - start + 499) / 500);
        }
    }

    function testFuzz_nextStep_boundedAndProgresses(
        uint16 current,
        uint16 target
    ) public view {
        uint16 n = h.nextStep(current, target);
        if (current >= target) {
            assertEq(n, current);
        } else {
            assertGt(n, current);
            assertLe(n, target);
            assertLe(uint256(n) - current, 500);
        }
    }
}
