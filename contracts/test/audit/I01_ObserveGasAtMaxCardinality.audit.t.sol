// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPoolFixture, ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {console2} from "forge-std/console2.sol";

interface ISlipFactory {
    function createPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external returns (address);
}

interface IObsPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool);
    function observations(
        uint256 i
    ) external view returns (uint32, int56, uint160, bool);
}

/// @dev The one voter read the Slipstream factory makes in its constructor.
contract VoterStub {
    function factoryRegistry() external view returns (address) {
        return address(this);
    }
}

/// @title I01 measurement: `observe([twapWindow, 0])` under the LPOracle's fixed `POOL_CALL_GAS = 100,000`
/// @notice `LPOracleCLPool._meanTick` reads the pool's `observe` through a static call capped at `POOL_CALL_GAS`. Anyone can
/// raise a pool's observation buffer to 65,535 slots (`increaseObservationCardinalityNext`, permissionless) and the
/// slots fill with ordinary trading. The binary search over a full buffer then reads about 2 * 16 cold slots. If the read
/// needs more than the cap, `observe` fails inside the oracle, the consistency check reports unavailable for good (the
/// buffer never shrinks) and the market stays Drifting: borrowing, withdraw-with-debt and every ParameterStore setter of
/// the market stop.
/// @dev The test builds a real `uniswap-v3-core` pool and real Slipstream pools (EIP-1167 clones created by the pinned
/// v1 and main `CLFactory` builds), writes a full 65,535-slot buffer of initialized observations two seconds apart
/// (Base block time) straight into storage, checks the layout through the pools' own getters, cools the pool's storage
/// and measures `observe([1800, 0])` at the 100,000 cap and uncapped.
contract I01ObserveGasAtMaxCardinalityAuditTest is ClPoolFixture {
    uint256 internal constant POOL_CALL_GAS = 100_000;
    uint32 internal constant WINDOW = 1800;
    uint16 internal constant CARD = 65_535;
    uint256 internal constant OBS_SLOT = 8; // UniswapV3Pool: slot0, fg0, fg1, protocolFees, liquidity, ticks, bitmap, positions
    uint256 internal constant SLIP_SLOT0 = 6; // CLPool: factory, token0, token1, gauge, nft, factoryRegistry, slot0
    uint256 internal constant SLIP_OBS = 20; // ... fee/reward words, stakedLiquidity|lastUpdated|tickSpacing, liquidity, maps

    VoterStub internal voter;

    IClPool internal pool;

    function setUp() public {
        vm.warp(1_800_000_000);
        _deployFactory();
        (ClTestToken a, ClTestToken b,) = _sortedTokens("A", 18, "B", 18);
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = _createPool(t0, t1, 3000, 1e8, 1e8, 1, 1e24);
        voter = new VoterStub();
    }

    function test_I01_observeGasDirectPool() public {
        _fillBuffer(address(pool), 0, OBS_SLOT);
        (bool okCapped, uint256 used) = _measure(address(pool));
        console2.log("direct pool: uncapped gas", used, "within 100k cap", okCapped);
    }

    function test_I01_observeGasSlipstreamV1Clone() public {
        address p = _slipPool("out-slipstream-v1/", address(0));
        _fillBuffer(p, SLIP_SLOT0, SLIP_OBS);
        (bool okCapped, uint256 used) = _measure(p);
        console2.log("slipstream v1 clone: uncapped gas", used, "within 100k cap", okCapped);
    }

    function test_I01_observeGasSlipstreamMainClone() public {
        address legacy = _slipFactory("out-slipstream-v1/", address(0));
        address p = _slipPool("out-slipstream-main/", legacy);
        _fillBuffer(p, SLIP_SLOT0, SLIP_OBS);
        (bool okCapped, uint256 used) = _measure(p);
        console2.log("slipstream main clone: uncapped gas", used, "within 100k cap", okCapped);
    }

    function _slipFactory(
        string memory out,
        address legacy
    ) internal returns (address f) {
        address impl = deployCode(string.concat(out, "CLPool.sol/CLPool.json"));
        f = legacy == address(0)
            ? deployCode(string.concat(out, "CLFactory.sol/CLFactory.json"), abi.encode(address(voter), impl))
            : deployCode(string.concat(out, "CLFactory.sol/CLFactory.json"), abi.encode(address(voter), legacy, impl));
    }

    function _slipPool(
        string memory out,
        address legacy
    ) internal returns (address p) {
        address f = _slipFactory(out, legacy);
        ClTestToken a = new ClTestToken("X", 18);
        ClTestToken b = new ClTestToken("Y", 18);
        p = ISlipFactory(f).createPool(address(a), address(b), 100, uint160(1) << 96);
    }

    /// @dev Full buffer: observation i at time base + 2 i, newest at index CARD - 1, constant tick 0.
    function _fillBuffer(
        address p,
        uint256 slot0Slot,
        uint256 obsSlot
    ) internal {
        uint256 base = block.timestamp - 2 * uint256(CARD);
        for (uint256 i = 0; i < CARD; ++i) {
            uint256 ts = base + 2 * i;
            uint256 spl = i + 1;
            uint256 word = (ts & 0xffffffff) | (spl << 88) | (uint256(1) << 248);
            vm.store(p, bytes32(obsSlot + i), bytes32(word));
        }
        uint256 s0 = uint256(vm.load(p, bytes32(slot0Slot)));
        // observationIndex bits 184..199, cardinality 200..215, cardinalityNext 216..231.
        uint256 mask = ~(uint256(0xffffffffffff) << 184);
        s0 = (s0 & mask) | (uint256(CARD - 1) << 184) | (uint256(CARD) << 200) | (uint256(CARD) << 216);
        vm.store(p, bytes32(slot0Slot), bytes32(s0));
        // The layout is right only if the pool's own getters read back what was written.
        (,, uint16 index, uint16 card,,) = IObsPool(p).slot0();
        assertEq(index, CARD - 1, "observationIndex slot");
        assertEq(card, CARD, "cardinality slot");
        (uint32 ts,,, bool init) = IObsPool(p).observations(CARD - 1);
        assertTrue(init, "observation slot");
        assertEq(ts, uint32(base + 2 * (uint256(CARD) - 1)), "observation timestamp");
    }

    function _measure(
        address p
    ) internal returns (bool okCapped, uint256 used) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        bytes memory data = abi.encodeCall(IClPool.observe, (ago));
        // An EIP-1167 clone (45 bytes) delegates to the implementation named in bytes 10..29; cool it as well, as a
        // keeper's poke finds it when nothing earlier in the transaction touched the pool.
        address impl = p.code.length == 45 ? address(bytes20(_slice20(p.code, 10))) : address(0);
        vm.cool(p);
        if (impl != address(0)) vm.cool(impl);
        (okCapped,) = p.staticcall{gas: POOL_CALL_GAS}(data);
        vm.cool(p);
        if (impl != address(0)) vm.cool(impl);
        uint256 g0 = gasleft();
        (bool ok,) = p.staticcall(data);
        used = g0 - gasleft();
        assertTrue(ok, "uncapped observe must succeed");
    }

    function _slice20(
        bytes memory b,
        uint256 at
    ) internal pure returns (bytes20 out) {
        assembly ("memory-safe") {
            out := mload(add(add(b, 0x20), at))
        }
    }
}
