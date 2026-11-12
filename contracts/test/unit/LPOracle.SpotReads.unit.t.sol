// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/PriceState.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title LPOracleSpotReadsUnitTest
/// @notice The LPOracle's valuation and state paths read no spot state (REQ-ORACLE-063): over `latestAnswer`,
/// `latestRoundData`, `getPriceState` and `poke` in the Live, Drifting and Cached states, no call made anywhere in the
/// call tree carries a pool spot-price, spot-balance, position-record or fee-growth selector. This is the oracle half
/// of TEST-266's spot-move invariance (the quote reads the oracle price vector, never `slot0`); the integration half
/// moves the pool's spot and compares compositions, and the fork half runs both on the pinned pools.
/// forge-config: default.isolate = false
contract LPOracleSpotReadsUnitTest is LPOracleFixture {
    uint256 internal constant T1 = T0 + 60;

    function setUp() public {
        _deployMarket();
        vm.warp(T1);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T1);
    }

    /// @dev Spot reads REQ-ORACLE-063 forbids: pool spot price and liquidity state, balances, position records and
    /// fee growth of Uniswap v3, Slipstream and v2-style pools.
    function _forbidden() internal pure returns (bytes4[8] memory s) {
        s = [
            bytes4(keccak256("slot0()")),
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

    // TEST-266 verifies: REQ-ORACLE-063, INV-078, Q-079, Q-321
    // Sources: 5.1 TEST-266 (the composition reads only the oracle price vector and never slot0)
    /// @notice Every read and write path of the oracle, in three states, makes no spot read.
    /// @dev Kills: a `slot0`, `balanceOf`, position-record or fee-growth read added to any valuation or state path.
    function test_TEST_266_valuationAndStatePathsReadNoSpotState() public {
        vm.startStateDiffRecording();
        _reads();
        oracle.setConsistency(false, true, 80, false);
        _reads();
        oracle.setConsistency(false, false, 0, false);
        pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);
        aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);
        _reads();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertEq(uint8(_state().state), uint8(PriceState.Cached), "the last pass ran in Cached");
        bytes4[8] memory forbidden = _forbidden();
        uint256 calls = 0;
        for (uint256 i = 0; i < accesses.length; ++i) {
            bytes memory data = accesses[i].data;
            if (data.length < 4) continue;
            ++calls;
            bytes4 sel = bytes4(data);
            for (uint256 j = 0; j < forbidden.length; ++j) {
                assertTrue(sel != forbidden[j], string.concat("spot read to ", vm.toString(accesses[i].account)));
            }
        }
        assertGt(calls, 20, "the paths ran");
    }
}
