// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleGasFixture} from "../utils/fixtures/LPOracleGasFixture.sol";
import {OcrAggregatorMock} from "../utils/mocks/ChainlinkCostMocks.sol";

/// @notice `POKE_MIN_GAS_FLOOR` of `SPEC-ORC-023` measured on the worst-case poke of a two-token market: both routes
/// of each token on two legs (the standby in the primary slot), every leg's round the first of a new aggregator phase
/// after a gap longer than its feed age, so every recovery lookup is taken through the previous phase, and an
/// oracle-network second source per token; every account and slot cold. The smallest entry gas at which `poke()`
/// completes is `max(W_poke, max_k(u_k + ceil(64 G_k / 63) + POST_CALL_GAS))`; the implementation's floor must be at
/// least that, so a poke at `pokeMinGas` never reverts `InsufficientGas` and every read receives its full gas.
contract LPOraclePokeFloorGasTest is LPOracleGasFixture {
    /// @notice `POKE_MIN_GAS_FLOOR` of a two-token concentrated-liquidity implementation on Ethereum (`SPEC-ORC-023`).
    uint256 internal constant POKE_MIN_GAS_FLOOR_2 = 900_000;

    function setUp() public {
        // Floor 1: the implementation under measurement accepts any entry gas, so the measured minimum is the poke's
        // own.
        _setUpGas(false, 1);
        gasRegistry.useStandby(usdc, RouteSlot.Primary);
        gasRegistry.useStandby(usdt, RouteSlot.Primary);
        ILPOracle(address(oracle)).poke();
        // Every leg goes silent for longer than its feed age, then publishes the first round of a new phase.
        vm.warp(block.timestamp + MAX_AGE + 10_000);
        vm.roll(block.number + 1);
        uint256 at = block.timestamp - 60;
        uint8[8] memory routeLegs = [1, 2, 4, 5, 6, 7, 8, 9];
        for (uint256 i = 0; i < routeLegs.length; ++i) {
            uint256 leg = routeLegs[i];
            OcrAggregatorMock fresh = new OcrAggregatorMock(
                OcrAggregatorMock(legs[leg].aggregator()).decimals(),
                OcrAggregatorMock(legs[leg].aggregator()).minAnswer(),
                OcrAggregatorMock(legs[leg].aggregator()).maxAnswer()
            );
            fresh.setRound(leg == 2 || leg == 5 || leg == 7 || leg == 9 ? int192(4000e8) : int192(2.5e14), uint32(at));
            legs[leg].newPhase(fresh);
        }
        _round(10, 1e8, at);
        _round(11, 1e8, at);
    }

    function _pokeWith(
        uint256 gas
    ) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(oracle).call{gas: gas}(abi.encodeCall(ILPOracle.poke, ()));
    }

    /// @dev Smallest entry gas in `[lo, hi]` at which `accept` holds for the poke's outcome (monotone in the gas).
    function _search(
        uint256 lo,
        uint256 hi,
        bool readBoundOnly
    ) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (bool ok, bytes memory ret) = _pokeWith(mid);
            vm.revertToState(snap);
            bool pass = ok || (readBoundOnly && bytes4(ret) != ILPOracleErrors.InsufficientGas.selector);
            if (pass) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-038, REQ-ORACLE-102, SPEC-ORC-023, REQ-ORACLE-089
    /// @notice The worst-case poke completes at the floor: every read on the way meets its pre-call bound (the
    /// smallest entry gas with no `InsufficientGas` is `max_k(u_k + ceil(64 G_k / 63) + POST_CALL_GAS)`) and the whole
    /// poke fits (`W_poke`); below the measured minimum it reverts and changes nothing.
    function test_TEST_042_worstCasePokeWithinFloor() public {
        uint256 snap = vm.snapshotState();
        uint256 used = gasleft();
        ILPOracle(address(oracle)).poke();
        used -= gasleft();
        vm.revertToState(snap);
        uint256 readBound = _search(100_000, 3_000_000, true);
        uint256 minimum = _search(100_000, 3_000_000, false);
        (bool below, bytes memory ret) = _pokeWith(readBound - 1);
        vm.revertToState(snap);
        assertFalse(below, "below the read bound");
        assertEq(bytes4(ret), ILPOracleErrors.InsufficientGas.selector, "a read short of its bound reverts first");
        (, uint256 left, uint256 required) = abi.decode(bytes.concat(bytes28(0), ret), (bytes32, uint256, uint256));
        emit log_named_uint("W_poke (cold, gas used with ample gas)", used);
        emit log_named_uint("max_k(u_k + bound_k): smallest entry gas with no InsufficientGas", readBound);
        emit log_named_uint("binding read: gas used before it, u_k", readBound - 1 - left);
        emit log_named_uint("binding read: ceil(64 G_k / 63) + POST_CALL_GAS", required);
        emit log_named_uint("smallest entry gas at which poke completes", minimum);
        assertLe(minimum, POKE_MIN_GAS_FLOOR_2, "POKE_MIN_GAS_FLOOR");
        (bool ok,) = _pokeWith(POKE_MIN_GAS_FLOOR_2);
        assertTrue(ok, "poke at the floor");
        (, uint64 acceptedAt) = ILPOracle(address(oracle)).lastAcceptedPrice();
        assertEq(acceptedAt, block.timestamp - 60, "the fresh price was accepted");
    }
}
