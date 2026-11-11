// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {ReadMode} from "../utils/mocks/LPOracleMocks.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

/// @notice Gas starvation of `poke()` (2.10 `REQ-ORACLE-024`, `REQ-ORACLE-039`, `REQ-ORACLE-102`, `SPEC-ORC-023`): the
/// `pokeMinGas` check measures the gas left at the implementation's entry, so a transaction must also pay for the
/// proxy and the call before it; every read inside needs its full explicit gas before it is made, so a poke given too
/// little gas reverts and commits no failure, timer, latch, decimals mark or price, whatever limit it was given.
/// forge-config: default.isolate = false
contract LPOraclePokeGasUnitTest is LPOracleFixture {
    /// @dev The stored outcome of a poke: what a starved poke must leave unchanged.
    struct Stored {
        uint64 failedSince;
        uint64 disagreeSince;
        bool latched;
        uint64 recoveredAt;
        uint256 accepted;
        uint64 acceptedAt;
        uint256 checkpoint;
        uint64 checkpointAt;
        bool decimalsInvalid;
        uint64 decimalsAt;
    }

    function setUp() public {
        _deployMarket();
    }

    function _stored() internal view returns (Stored memory s) {
        (s.failedSince, s.disagreeSince, s.latched, s.recoveredAt) = oracle.storedTimers();
        (s.accepted, s.acceptedAt) = oracle.lastAcceptedPrice();
        (s.checkpoint, s.checkpointAt) = oracle.priceCheckpoint();
        (s.decimalsInvalid, s.decimalsAt) = oracle.decimalsStatus();
    }

    function _assertUnchanged(
        Stored memory a,
        Stored memory b
    ) internal pure {
        assertEq(a.failedSince, b.failedSince, "failedSince");
        assertEq(a.disagreeSince, b.disagreeSince, "disagreeSince");
        assertEq(a.latched, b.latched, "latch");
        assertEq(a.recoveredAt, b.recoveredAt, "recoveredAt");
        assertEq(a.accepted, b.accepted, "accepted price");
        assertEq(a.acceptedAt, b.acceptedAt, "accepted timestamp");
        assertEq(a.checkpoint, b.checkpoint, "checkpoint");
        assertEq(a.checkpointAt, b.checkpointAt, "checkpoint time");
        assertEq(a.decimalsInvalid, b.decimalsInvalid, "decimals mark");
        assertEq(a.decimalsAt, b.decimalsAt, "decimals verification");
    }

    function _poke(
        uint256 gas
    ) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(oracle).call{gas: gas}(abi.encodeCall(oracle.poke, ()));
    }

    /// @dev Upgrades the feed to an implementation whose floor is 1 and sets `pokeMinGas = 1`, so the sweeps below can
    /// starve every read inside the poke, not only the entry check.
    function _lowerFloor() internal {
        LPOracleHarness next = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, 1, POKE_CEILING, false);
        vm.startPrank(tl);
        oracle.upgradeToAndCall(address(next), "");
        oracle.setPokeMinGas(1);
        vm.stopPrank();
    }

    /// @dev Pokes at every limit from `lo` to `hi` in steps of `step` from the same state. A poke that reverts must
    /// revert (`InsufficientGas`, or out of gas) and leave `before` as stored; a poke that completes must leave
    /// `expectFailedSince` as `failedSince` and no decimals mark. Returns the smallest limit that completed.
    function _sweep(
        uint256 lo,
        uint256 hi,
        uint256 step,
        uint64 expectFailedSince
    ) internal returns (uint256 firstOk, uint256 starved) {
        Stored memory before = _stored();
        uint256 snap = vm.snapshotState();
        for (uint256 g = lo; g <= hi; g += step) {
            (bool ok, bytes memory ret) = _poke(g);
            Stored memory afterPoke = _stored();
            if (ok) {
                if (firstOk == 0) firstOk = g;
                assertEq(afterPoke.failedSince, expectFailedSince, "a completed poke records the true failure state");
                assertFalse(afterPoke.decimalsInvalid, "no decimals mark from gas");
            } else {
                ++starved;
                // InsufficientGas from a pre-call check, or out of gas in the logic between reads (the implementation's
                // delegatecall then reverts FailedCall) or before it (no data).
                bytes4 sel = bytes4(ret);
                assertTrue(
                    ret.length == 0 || sel == ILPOracleErrors.InsufficientGas.selector
                        || sel == Errors.FailedCall.selector,
                    "a starved poke reverts InsufficientGas or out of gas"
                );
                _assertUnchanged(before, afterPoke);
            }
            vm.revertToState(snap);
        }
    }

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-038, SPEC-ORC-023
    /// @notice With `pokeMinGas = POKE_MIN_GAS_FLOOR = 900,000`, a call that forwards exactly 900,000 gas to the proxy
    /// reverts `InsufficientGas(left, 900,000)` with `left` below the floor: the floor is the gas left at the
    /// implementation's entry check, so a caller's limit must also cover the proxy's dispatch, the 1/64 kept by the
    /// delegatecall and its own work before the call. The smallest passing call gas is within 900,000 / 63 + 10,000 of
    /// the floor.
    function test_TEST_042_floorIsGasLeftAtTheEntryCheck() public {
        assertEq(oracle.pokeMinGas(), 900_000);
        vm.warp(T0 + 60);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T0 + 60);
        Stored memory before = _stored();
        (bool ok, bytes memory ret) = _poke(900_000);
        assertFalse(ok, "exactly the floor at the proxy is not the floor at the entry check");
        assertEq(bytes4(ret), ILPOracleErrors.InsufficientGas.selector);
        (, uint256 left, uint256 required) = abi.decode(bytes.concat(bytes28(0), ret), (bytes32, uint256, uint256));
        assertEq(required, 900_000, "the check names pokeMinGas");
        assertLt(left, 900_000);
        _assertUnchanged(before, _stored());
        uint256 snap = vm.snapshotState();
        uint256 lo = 900_000;
        uint256 hi = 1_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            (ok,) = _poke(mid);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("smallest call gas that passes a 900,000 entry check", hi);
        assertGt(hi, 900_000);
        assertLe(hi, 900_000 + uint256(900_000) / 63 + 10_000, "overhead before the check: proxy and 1/64");
        (ok,) = _poke(hi);
        assertTrue(ok);
        assertEq(_stored().acceptedAt, T0 + 60, "the poke completed and accepted the new round");
    }

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-039, REQ-ORACLE-102, REQ-ORACLE-107, SPEC-ORC-023, ATTACK-042
    /// @notice A healthy market poked at every limit from 20,000 to 600,000 gas in steps of 2,500: below the gas the
    /// poke needs it reverts and stores nothing; from there on it completes with no failure and no decimals mark. No
    /// limit makes a healthy feed look failed.
    function test_TEST_042_starvedPokeNeverRecordsAFailure() public {
        _lowerFloor();
        vm.warp(T0 + 3700);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T0 + 3700);
        (uint256 firstOk, uint256 starved) = _sweep(20_000, 600_000, 2500, 0);
        emit log_named_uint("smallest limit that completed", firstOk);
        assertGt(firstOk, 0, "the poke completes with enough gas");
        assertGt(starved, 10, "and reverts below it at many limits");
    }

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-027, REQ-ORACLE-030, SPEC-ORC-013, REQ-ORACLE-102
    /// @notice A failed market (both routes of token A stale) poked at every limit: a completed poke stores the true
    /// failure start `staleAt`, never `now`; a starved one stores nothing, so it neither starts the timer late nor
    /// latches.
    function test_TEST_042_starvedPokeOfAFailedMarket() public {
        _lowerFloor();
        uint256 staleAt = T0 + MAX_AGE + 1;
        uint256 t = staleAt + 500;
        vm.warp(t);
        vm.roll(block.number + 1);
        pB.push(int256(ONE), t);
        aB.push(int256(ONE), t);
        (uint256 firstOk,) = _sweep(20_000, 600_000, 2500, uint64(staleAt));
        assertGt(firstOk, 0);
        assertEq(uint8(_state().state), uint8(PriceState.Cached));
    }

    // TEST-042 verifies: REQ-ORACLE-102, REQ-ORACLE-039, SPEC-ORC-023
    /// @notice The distinction the gas guard draws: a source that burns its whole explicit gas is a failed source and
    /// fails the market (here a token's `decimals()` and both of token A's routes), while a caller who gives too little
    /// gas for the same reads gets `InsufficientGas` and changes nothing.
    function test_TEST_042_burningSourceFailsStarvedCallerReverts() public {
        _lowerFloor();
        vm.warp(T0 + 60);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T0 + 60);
        pA.setMode(pA.latestRoundData.selector, ReadMode.BurnGas);
        aA.setMode(aA.latestRoundData.selector, ReadMode.BurnGas);
        uint256 snap = vm.snapshotState();
        (bool ok,) = _poke(5_000_000);
        assertTrue(ok);
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertEq(failedSince, T0 + 60, "a source burning its full gas is a failure");
        vm.revertToState(snap);
        Stored memory before = _stored();
        (ok,) = _poke(120_000);
        assertFalse(ok, "the caller's limit cannot cover the reads");
        _assertUnchanged(before, _stored());
    }
}
