// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice A real Uniswap v3 pool whose `slot0` reports a chosen square-root price and tick while keeping the pool's
/// own observation fields and lock flag; every other read is forwarded.
contract SpotLiarPool {
    IClPool internal immutable _POOL;
    uint160 public fakeSqrt;
    int24 public fakeTick;

    constructor(
        IClPool pool
    ) {
        _POOL = pool;
    }

    function lie(
        uint160 s,
        int24 t
    ) external {
        (fakeSqrt, fakeTick) = (s, t);
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        (,, uint16 i, uint16 c, uint16 n, uint8 f, bool u) = _POOL.slot0();
        return (fakeSqrt, fakeTick, i, c, n, f, u);
    }

    function token0() external view returns (address) {
        return _POOL.token0();
    }

    function token1() external view returns (address) {
        return _POOL.token1();
    }

    function tickSpacing() external view returns (int24) {
        return _POOL.tickSpacing();
    }

    function observe(
        uint32[] calldata ago
    ) external view returns (int56[] memory, uint160[] memory) {
        return _POOL.observe(ago);
    }
}

/// @title LPOracleSpotReadsUnitTest
/// @notice The concentrated-liquidity LPOracle reads no spot state for valuation (REQ-ORACLE-063, REQ-ORACLE-011): over
/// `latestAnswer`, `latestRoundData`, `getPriceState` and `poke` in the Live, Drifting and Cached states on a real
/// Uniswap v3 pool, no call in the call tree carries a balance, position-record, reserve, tick or fee-growth selector,
/// and the only `slot0` reads go to the market's own pool, for its lock flag and observation cardinality. A pool whose
/// `slot0` reports any other square-root price and tick serves the same price to the wei.
/// forge-config: default.isolate = false
contract LPOracleSpotReadsUnitTest is LPOracleCLFixture {
    function setUp() public {
        _deployClMarket(_ethUsdc());
    }

    /// @dev Spot reads REQ-ORACLE-063 forbids outright.
    function _forbidden() internal pure returns (bytes4[7] memory s) {
        s = [
            bytes4(keccak256("balanceOf(address)")),
            bytes4(keccak256("positions(uint256)")),
            bytes4(keccak256("positions(bytes32)")),
            bytes4(keccak256("feeGrowthGlobal0X128()")),
            bytes4(keccak256("feeGrowthGlobal1X128()")),
            bytes4(keccak256("getReserves()")),
            bytes4(keccak256("ticks(int24)"))
        ];
    }

    function _reads() internal {
        oracle.latestAnswer();
        oracle.latestRoundData();
        oracle.getPriceState();
        oracle.poke();
    }

    // TEST-266 verifies: REQ-ORACLE-063, REQ-ORACLE-011, REQ-ORACLE-103, INV-078, Q-079, Q-321
    // Sources: 5.1 TEST-266 (valuation reads only the oracle price vector; slot0 only for the lock and cardinality)
    /// @dev Kills: a balance, position-record, reserve, tick or fee-growth read added to any path, and a `slot0` read of
    /// another contract.
    function test_TEST_266_valuationAndStatePathsReadNoSpotState() public {
        vm.startStateDiffRecording();
        _reads();
        _swapTo(pool, uint160(uint256(_oracleSqrt(price0, price1)) * 102 / 100));
        vm.warp(block.timestamp + WINDOW + 1);
        _setPrices(price0, price1);
        _reads();
        p0Feed.setMode(p0Feed.latestRoundData.selector, ReadMode.Revert);
        a0Feed.setMode(a0Feed.latestRoundData.selector, ReadMode.Revert);
        _reads();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(uint8(_state().state), uint8(PriceState.Cached), "the last pass ran in Cached");
        bytes4[7] memory forbidden = _forbidden();
        bytes4 slot0 = bytes4(keccak256("slot0()"));
        uint256 calls = 0;
        uint256 slot0Reads = 0;
        for (uint256 i = 0; i < accesses.length; ++i) {
            bytes memory data = accesses[i].data;
            if (data.length < 4) continue;
            ++calls;
            bytes4 sel = bytes4(data);
            if (sel == slot0 && accesses[i].accessor != address(actor)) {
                ++slot0Reads;
                assertEq(accesses[i].account, address(pool), "slot0 of another contract");
            }
            if (accesses[i].accessor == address(actor) || accesses[i].accessor == address(pool)) continue;
            for (uint256 j = 0; j < forbidden.length; ++j) {
                assertTrue(sel != forbidden[j], string.concat("spot read to ", vm.toString(accesses[i].account)));
            }
        }
        assertGt(calls, 20, "the paths ran");
        assertGt(slot0Reads, 0, "the lock is read");
    }

    // TEST-266 verifies: REQ-ORACLE-011, REQ-ORACLE-063, SPEC-ORC-007
    /// @dev The same pool seen with any other `slot0` price and tick: the served price, fresh price and state are
    /// identical, so `slot0` contributes only its lock flag and cardinality.
    function test_TEST_266_slot0PriceAndTickNeverReachThePrice() public {
        SpotLiarPool liar = new SpotLiarPool(pool);
        IClPool real = pool;
        pool = IClPool(address(liar));
        LPOracleCL impl = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        LPOracleCL other =
            LPOracleCL(address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (_params())))));
        pool = real;
        uint160[3] memory lies = [uint160(4_295_128_740), uint160(2 ** 96), uint160(2 ** 159)];
        int24[3] memory ticks = [int24(-887_271), int24(0), int24(887_000)];
        for (uint256 i = 0; i < 3; ++i) {
            liar.lie(lies[i], ticks[i]);
            PriceStateView memory a = oracle.getPriceState();
            PriceStateView memory b = other.getPriceState();
            assertEq(b.answer, a.answer, "served price");
            assertEq(b.freshAnswer, a.freshAnswer, "fresh price");
            assertEq(uint8(b.state), uint8(a.state), "state");
            assertEq(b.consistencyDeviationBps, a.consistencyDeviationBps, "TWAP deviation");
        }
    }
}
