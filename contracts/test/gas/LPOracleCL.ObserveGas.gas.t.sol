// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPoolFixture, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";

/// @notice The pinned Slipstream `CLFactory` function the test calls.
interface ISlipFactoryObserve {
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address);
}

/// @dev The one voter read the Slipstream factory makes in its constructor.
contract ObserveVoterStub {
    function factoryRegistry() external view returns (address) {
        return address(this);
    }
}

/// @notice Gas of a real Uniswap v3 and Slipstream `observe([1800, 0])` on a pool whose observation buffer anyone has
/// grown to the largest size, 65,535 slots, read from cold storage, against the LPOracle's `OBSERVE_CALL_GAS = 160,000`
/// (`LPOracleCLPool._meanTick`, `SPEC-ORC-023`). Each read must fit with a third of the allowance to spare: under the
/// former shared `POOL_CALL_GAS = 100,000` a Slipstream clone needed up to 103,000 with its call overhead (audit finding I-01, fresh audit
/// 2026-11-15), too little margin for a buffer that never shrinks.
/// @dev The buffer is filled with `vm.store` (one initialized observation every 2 s, Base's block time) instead of
/// 65,535 blocks of swaps; the pool's own `observe` then runs its binary search over the whole ring. Slipstream pools are
/// created by the pinned v1 and main factories, so each is an EIP-1167 clone and its implementation is cooled as well.
contract LPOracleCLObserveGasTest is ClPoolFixture {
    uint256 internal constant OBSERVE_CALL_GAS = 160_000;
    uint16 internal constant FULL = 65_535;
    uint256 internal constant OBSERVATIONS_SLOT = 8;
    /// @dev Slipstream's slot0 and observations slots: after six addresses, then slot0, the fee, reward, liquidity and
    /// mapping words.
    uint256 internal constant SLIP_SLOT0 = 6;
    uint256 internal constant SLIP_OBSERVATIONS_SLOT = 20;

    IClPool internal pool;

    function setUp() public {
        vm.warp(1_762_000_000);
        _deployFactory();
        (ClTestToken a, ClTestToken b,) = _sortedTokens("TA", 18, "TB", 18);
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _createPool(t0, t1, 3000, 1e8, 1e8, 2, 1e18);
        _fillBuffer(address(pool), 0, OBSERVATIONS_SLOT, block.timestamp);
        vm.warp(block.timestamp + 2 * (uint256(FULL) - 1) + 1);
    }

    /// @dev Every slot initialized from time `t0`, the newest at index 65,534; the caller warps to one second after it.
    function _fillBuffer(
        address p,
        uint256 slot0Slot,
        uint256 observationsSlot,
        uint256 t0
    ) internal {
        uint256 s0 = uint256(vm.load(p, bytes32(slot0Slot)));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 tick = int24(uint24(s0 >> 160));
        for (uint256 i = 0; i < FULL; ++i) {
            uint256 ts = t0 + 2 * i;
            // forge-lint: disable-next-line(unsafe-typecast)
            int56 cum = int56(tick) * int56(int256(2 * i));
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 word = ts | (uint256(uint56(cum)) << 32) | (i << 88) | (uint256(1) << 248);
            vm.store(p, bytes32(observationsSlot + i), bytes32(word));
        }
        // slot0: keep the price and tick, index = 65,534, cardinality and next = 65,535, unlocked.
        uint256 keep = s0 & ((uint256(1) << 184) - 1);
        uint256 w =
            keep | (uint256(FULL - 1) << 184) | (uint256(FULL) << 200) | (uint256(FULL) << 216) | (uint256(1) << 240);
        // Slipstream's slot0 has no fee-protocol byte: its unlocked flag sits at bit 232.
        if (slot0Slot != 0) {
            w = keep | (uint256(FULL - 1) << 184) | (uint256(FULL) << 200) | (uint256(FULL) << 216)
                | (uint256(1) << 232);
        }
        vm.store(p, bytes32(slot0Slot), bytes32(w));
    }

    function _ago() internal pure returns (uint32[] memory ago) {
        ago = new uint32[](2);
        ago[0] = 1800;
    }

    /// @dev Cold `observe(ago)` on `p` with ample gas (asserted to succeed) and at `OBSERVE_CALL_GAS`; an EIP-1167
    /// clone's implementation is cooled too.
    function _coldObserve(
        address p,
        uint32[] memory ago
    ) internal returns (uint256 used, bool fits) {
        address impl = p.code.length == 45 ? _cloneTarget(p) : address(0);
        vm.cool(p);
        if (impl != address(0)) vm.cool(impl);
        uint256 g = gasleft();
        (bool okAmple,) = p.staticcall{gas: 1_000_000}(abi.encodeCall(IClPool.observe, (ago)));
        used = g - gasleft();
        assertTrue(okAmple, "observe failed with ample gas");
        vm.cool(p);
        if (impl != address(0)) vm.cool(impl);
        (fits,) = p.staticcall{gas: OBSERVE_CALL_GAS}(abi.encodeCall(IClPool.observe, (ago)));
    }

    function _cloneTarget(
        address p
    ) internal view returns (address impl) {
        bytes memory code = p.code;
        assembly ("memory-safe") {
            impl := shr(96, mload(add(add(code, 0x20), 10)))
        }
    }

    /// @dev `used` fits the allowance with a third of it to spare.
    function _assertHeadroom(
        uint256 used,
        bool fits
    ) internal pure {
        assertTrue(fits, "observe does not fit OBSERVE_CALL_GAS");
        assertLe(used * 3, OBSERVE_CALL_GAS * 2, "observe leaves less than a third of OBSERVE_CALL_GAS spare");
    }

    /// @dev A Slipstream pool of the build in `out`, created by its factory (an EIP-1167 clone), with a full buffer.
    function _slipPool(
        string memory out,
        address legacy
    ) internal returns (address p) {
        ObserveVoterStub voter = new ObserveVoterStub();
        address impl = deployCode(string.concat(out, "CLPool.sol/CLPool.json"));
        address f = legacy == address(0)
            ? deployCode(string.concat(out, "CLFactory.sol/CLFactory.json"), abi.encode(address(voter), impl))
            : deployCode(string.concat(out, "CLFactory.sol/CLFactory.json"), abi.encode(address(voter), legacy, impl));
        ClTestToken a = new ClTestToken("SA", 18);
        ClTestToken b = new ClTestToken("SB", 18);
        p = ISlipFactoryObserve(f).createPool(address(a), address(b), 100, uint160(1) << 96);
        _fillBuffer(p, SLIP_SLOT0, SLIP_OBSERVATIONS_SLOT, block.timestamp - 2 * uint256(FULL));
        (bool ok, bytes memory ret) = p.staticcall(abi.encodeWithSignature("observations(uint256)", uint256(FULL - 1)));
        assertTrue(ok, "observations");
        (,,, bool init) = abi.decode(ret, (uint32, int56, uint160, bool));
        assertTrue(init, "Slipstream observation layout");
        (ok, ret) = p.staticcall(abi.encodeWithSignature("slot0()"));
        assertTrue(ok, "slot0");
        (,,, uint16 cardinality,,) = abi.decode(ret, (uint160, int24, uint16, uint16, uint16, bool));
        assertEq(cardinality, FULL, "Slipstream slot0 layout");
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

    /// @notice Measures cold `observe([1800, 0])` and checks it fits `OBSERVE_CALL_GAS` with headroom.
    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-014
    function test_TEST_042_coldObserveOnAFullBufferFitsObserveCallGas() public {
        (uint256 used, bool fits) = _coldObserve(address(pool), _ago());
        emit log_named_uint("cold observe([1800, 0]) gas, 65,535-slot buffer", used);
        _assertHeadroom(used, fits);
    }

    /// @notice The same on real Slipstream pools, v1 and main builds, each an EIP-1167 clone whose DELEGATECALL adds a
    /// cold implementation access.
    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-014
    function test_TEST_042_coldObserveOnFullSlipstreamBuffersFitsObserveCallGas() public {
        address v1 = _slipPool("out-slipstream-v1/", address(0));
        (uint256 used, bool fits) = _coldObserve(v1, _ago());
        emit log_named_uint("Slipstream v1 cold observe gas", used);
        _assertHeadroom(used, fits);
        address legacy = deployCode(
            "out-slipstream-v1/CLFactory.sol/CLFactory.json",
            abi.encode(address(new ObserveVoterStub()), deployCode("out-slipstream-v1/CLPool.sol/CLPool.json"))
        );
        address mainPool = _slipPool("out-slipstream-main/", legacy);
        (used, fits) = _coldObserve(mainPool, _ago());
        emit log_named_uint("Slipstream main cold observe gas", used);
        _assertHeadroom(used, fits);
        (uint256 worst, uint32 worstAgo) = _worstOverRing(mainPool);
        emit log_named_uint("Slipstream main worst cold observe gas over the ring", worst);
        uint32[] memory w = new uint32[](2);
        w[0] = worstAgo;
        (used, fits) = _coldObserve(mainPool, w);
        _assertHeadroom(used, fits);
    }

    /// @dev The largest cold `observe([a, 0])` gas over target positions `a` swept across the whole ring.
    function _worstOverRing(
        address p
    ) internal returns (uint256 worst, uint32 worstAgo) {
        address impl = p.code.length == 45 ? _cloneTarget(p) : address(0);
        for (uint32 a = 3; a < 2 * uint32(FULL) - 4; a += 37) {
            uint32[] memory ago = new uint32[](2);
            ago[0] = a;
            vm.cool(p);
            if (impl != address(0)) vm.cool(impl);
            uint256 g = gasleft();
            (bool ok,) = p.staticcall{gas: 1_000_000}(abi.encodeCall(IClPool.observe, (ago)));
            uint256 used = g - gasleft();
            assertTrue(ok);
            if (used > worst) (worst, worstAgo) = (used, a);
        }
    }

    /// @notice The worst case over target positions: `secondsAgo` swept across the whole ring (the search depth
    /// depends on where the target falls), each read cold; reports the largest and checks it fits `OBSERVE_CALL_GAS`
    /// with headroom.
    // TEST-042 verifies: SPEC-ORC-023, REQ-ORACLE-014
    function test_TEST_042_worstColdObserveOverTheRingFitsObserveCallGas() public {
        (uint256 worst, uint32 worstAgo) = _worstOverRing(address(pool));
        emit log_named_uint("worst cold observe gas (incl. the 2,600 cold CALL)", worst);
        emit log_named_uint("at secondsAgo", worstAgo);
        uint32[] memory w = new uint32[](2);
        w[0] = worstAgo;
        (uint256 usedWorst, bool fits) = _coldObserve(address(pool), w);
        _assertHeadroom(usedWorst, fits);
    }
}
