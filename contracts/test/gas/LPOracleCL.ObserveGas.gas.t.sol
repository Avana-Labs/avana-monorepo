// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPoolFixture, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";

/// @notice Gas of a real Uniswap v3 `observe([1800, 0])` on a pool whose observation buffer anyone has grown to the
/// largest size, 65,535 slots, read from cold storage, against the LPOracle's `POOL_CALL_GAS = 100,000`
/// (`LPOracleCLPool._meanTick`, `SPEC-ORC-023`).
/// @dev The buffer is filled with `vm.store` (one initialized observation every 2 s, Base's block time) instead of
/// 65,535 blocks of swaps; the pool's own `observe` then runs its binary search over the whole ring.
contract LPOracleCLObserveGasTest is ClPoolFixture {
    uint256 internal constant POOL_CALL_GAS = 100_000;
    uint16 internal constant FULL = 65_535;
    uint256 internal constant OBSERVATIONS_SLOT = 8;

    IClPool internal pool;

    function setUp() public {
        vm.warp(1_762_000_000);
        _deployFactory();
        (ClTestToken a, ClTestToken b,) = _sortedTokens("TA", 18, "TB", 18);
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _createPool(t0, t1, 3000, 1e8, 1e8, 2, 1e18);
        _fillBuffer();
    }

    /// @dev Every slot initialized, the newest at index 65,534, `now` one second after it.
    function _fillBuffer() internal {
        uint256 s0 = uint256(vm.load(address(pool), bytes32(0)));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 tick = int24(uint24(s0 >> 160));
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < FULL; ++i) {
            uint256 ts = t0 + 2 * i;
            // forge-lint: disable-next-line(unsafe-typecast)
            int56 cum = int56(tick) * int56(int256(2 * i));
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 word = ts | (uint256(uint56(cum)) << 32) | (i << 88) | (uint256(1) << 248);
            vm.store(address(pool), bytes32(OBSERVATIONS_SLOT + i), bytes32(word));
        }
        // slot0: keep the price and tick, index = 65,534, cardinality and next = 65,535, unlocked.
        uint256 keep = s0 & ((uint256(1) << 184) - 1);
        uint256 w =
            keep | (uint256(FULL - 1) << 184) | (uint256(FULL) << 200) | (uint256(FULL) << 216) | (uint256(1) << 240);
        vm.store(address(pool), bytes32(0), bytes32(w));
        vm.warp(t0 + 2 * (uint256(FULL) - 1) + 1);
    }

    function _ago() internal pure returns (uint32[] memory ago) {
        ago = new uint32[](2);
        ago[0] = 1800;
    }

    /// @notice The filled buffer is read as the pool's own: `observe` succeeds with ample gas and the mean tick over
    /// 1,800 s is the stored tick.
    // TEST-042 verifies: SPEC-ORC-023
    function test_TEST_042_fullObservationBufferIsReadByThePool() public view {
        (int56[] memory c,) = pool.observe(_ago());
        uint256 s0 = uint256(vm.load(address(pool), bytes32(0)));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 tick = int24(uint24(s0 >> 160));
        assertEq((c[1] - c[0]) / 1800, int56(tick));
    }

    /// @notice Measures cold `observe([1800, 0])` and checks it fits `POOL_CALL_GAS`.
    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-014
    function test_TEST_042_coldObserveOnAFullBufferFitsPoolCallGas() public {
        vm.cool(address(pool));
        uint256 g = gasleft();
        (bool okAmple,) = address(pool).staticcall{gas: 1_000_000}(abi.encodeCall(IClPool.observe, (_ago())));
        uint256 used = g - gasleft();
        assertTrue(okAmple);
        emit log_named_uint("cold observe([1800, 0]) gas, 65,535-slot buffer", used);

        vm.cool(address(pool));
        (bool ok,) = address(pool).staticcall{gas: POOL_CALL_GAS}(abi.encodeCall(IClPool.observe, (_ago())));
        assertTrue(ok, "observe does not fit POOL_CALL_GAS");
    }

    /// @notice The worst case over target positions: `secondsAgo` swept across the whole ring (the search depth
    /// depends on where the target falls), each read cold; reports the largest and checks it fits `POOL_CALL_GAS`.
    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-014
    function test_TEST_042_worstColdObserveOverTheRingFitsPoolCallGas() public {
        uint256 worst = 0;
        uint32 worstAgo = 0;
        for (uint32 a = 3; a < 2 * uint32(FULL) - 4; a += 37) {
            uint32[] memory ago = new uint32[](2);
            ago[0] = a;
            vm.cool(address(pool));
            uint256 g = gasleft();
            (bool ok,) = address(pool).staticcall{gas: 1_000_000}(abi.encodeCall(IClPool.observe, (ago)));
            uint256 used = g - gasleft();
            assertTrue(ok);
            if (used > worst) (worst, worstAgo) = (used, a);
        }
        emit log_named_uint("worst cold observe gas (incl. the 2,600 cold CALL)", worst);
        emit log_named_uint("at secondsAgo", worstAgo);
        uint32[] memory w = new uint32[](2);
        w[0] = worstAgo;
        vm.cool(address(pool));
        (bool fits,) = address(pool).staticcall{gas: POOL_CALL_GAS}(abi.encodeCall(IClPool.observe, (w)));
        assertTrue(fits, "worst-case observe does not fit POOL_CALL_GAS");
    }
}
