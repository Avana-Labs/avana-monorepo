// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

/// @notice Fuzzed borrow-only gates and gas starvation of the LPOracle (2.10 `REQ-ORACLE-100`, `REQ-ORACLE-107`,
/// `REQ-ORACLE-024`): any second-source configuration word changes nothing but the confirmation; the token-decimals
/// verification age changes nothing but `borrowAllowed`; any gas limit either completes a poke with the true outcome or
/// reverts and stores nothing.
/// forge-config: default.isolate = false
contract LPOracleConfirmationFuzzTest is LPOracleFixture {
    uint256 internal constant STRIDE = OracleInputsLayout.TOKEN_WORDS + OracleInputsLayout.SECOND_WORDS;
    uint256 internal constant T1 = T0 + 60;

    function setUp() public {
        _deployMarket();
        vm.warp(T1);
        vm.roll(block.number + 1);
        _pushAll(int256(ONE), T1);
    }

    /// @dev Moves the feeds to one of four situations: Live, Drifting by disagreement, Live on token A's alternate, or
    /// failed with both of token A's routes stale.
    function _situation(
        uint256 kind,
        uint256 answer
    ) internal returns (uint256 t) {
        kind = kind % 4;
        t = T1;
        if (kind == 0) {
            _pushAll(int256(answer), T1);
        } else if (kind == 1) {
            _pushAll(int256(answer), T1);
            aA.push(int256(answer * 96 / 100), T1);
        } else {
            t = T1 + MAX_AGE + 1;
            vm.warp(t);
            pB.push(int256(answer), t);
            aB.push(int256(answer), t);
            sA.push(int256(answer), t);
            sB.push(int256(answer), t);
            if (kind == 2) aA.push(int256(answer), t);
        }
    }

    // TEST-219 verifies: REQ-ORACLE-100, REQ-ORACLE-042, REQ-ORACLE-016, SPEC-ORC-020
    /// @notice Any value in any second-source word of either token leaves the state, the served price, its timestamp,
    /// the failure start, the age limits and `liquidationPaused` as with the valid configuration at the same state,
    /// and a poke from the same snapshot stores the same failure timer and accepted price.
    function testFuzz_TEST_219_anySecondSourceWordChangesOnlyConfirmation(
        uint256 kind,
        uint256 answer,
        uint256 token,
        uint256 word,
        uint256 value
    ) public {
        answer = bound(answer, 95_000_000, 101_000_000);
        token = token % 2;
        word = word % OracleInputsLayout.SECOND_WORDS;
        _situation(kind, answer);
        address[] memory list = _two(address(tokenA), address(tokenB));
        uint256 snap = vm.snapshotState();
        PriceStateView memory a = _state();
        PriceState pokedA = oracle.poke();
        (uint64 failedA,,,) = oracle.storedTimers();
        (uint256 acceptedA, uint64 acceptedAtA) = oracle.lastAcceptedPrice();
        vm.revertToState(snap);
        uint256[] memory w = store.getOracleInputs(address(oracle), list, true);
        w[OracleInputsLayout.HEAD_WORDS + token * STRIDE + OracleInputsLayout.TOKEN_WORDS + word] = value;
        vm.mockCall(address(store), abi.encodeCall(store.getOracleInputs, (address(oracle), list, true)), abi.encode(w));
        PriceStateView memory b = _state();
        assertEq(uint8(a.state), uint8(b.state), "state");
        assertEq(a.answer, b.answer, "answer");
        assertEq(b.answer, oracle.latestAnswer(), "answer == latestAnswer()");
        assertEq(a.servedUpdatedAt, b.servedUpdatedAt, "served timestamp");
        assertEq(a.failureStart, b.failureStart, "failure start");
        assertEq(a.borrowPriceMaxAge, b.borrowPriceMaxAge, "borrow age");
        assertEq(a.liquidationPriceMaxAge, b.liquidationPriceMaxAge, "liquidation age");
        assertEq(a.liquidationPaused, b.liquidationPaused, "liquidationPaused");
        assertEq(a.reasons & ~uint256(1 << 16), b.reasons & ~uint256(1 << 16), "reasons other than bit 16");
        if (b.borrowAllowed) assertFalse(_has(b.reasons, 16), "borrowAllowed only when every token is confirmed");
        assertEq(uint8(oracle.poke()), uint8(pokedA), "poke state");
        (uint64 failedB,,,) = oracle.storedTimers();
        (uint256 acceptedB, uint64 acceptedAtB) = oracle.lastAcceptedPrice();
        assertEq(failedB, failedA, "failure timer");
        assertEq(acceptedB, acceptedA, "accepted price");
        assertEq(acceptedAtB, acceptedAtA, "accepted timestamp");
    }

    // TEST-294 verifies: REQ-ORACLE-107, REQ-ORACLE-100
    /// @notice `dt` seconds after a verifying poke, `borrowAllowed` holds exactly while `dt <= 7,200` (the feeds stay
    /// fresh), and the state, served price and `liquidationPaused` do not depend on `dt` within the feeds' age.
    function testFuzz_TEST_294_verificationAgeGatesBorrowOnly(
        uint256 dt
    ) public {
        dt = bound(dt, 0, 50_000);
        oracle.poke();
        PriceStateView memory at0 = _state();
        vm.warp(T1 + dt);
        PriceStateView memory v = _state();
        assertEq(v.borrowAllowed, dt <= 7200, "borrowAllowed iff verified within 7,200 s");
        assertEq(_has(v.reasons, 19), dt > 7200, "reason bit 19");
        assertEq(uint8(v.state), uint8(at0.state), "state");
        assertEq(v.answer, at0.answer, "served price");
        assertEq(v.liquidationPaused, at0.liquidationPaused, "liquidationPaused");
    }

    // TEST-042 verifies: REQ-ORACLE-024, REQ-ORACLE-102, REQ-ORACLE-027, SPEC-ORC-023
    /// @notice With the entry floor lowered to 1 so every read can be starved: at any gas limit a poke either reverts
    /// (`InsufficientGas` or out of gas) and stores nothing, or completes and stores the failure start it stores with
    /// ample gas.
    function testFuzz_TEST_042_anyGasLimitCommitsTheTrueOutcome(
        uint256 kind,
        uint256 gasLimit
    ) public {
        LPOracleHarness next = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, 1, POKE_CEILING, false);
        vm.startPrank(tl);
        oracle.upgradeToAndCall(address(next), "");
        oracle.setPokeMinGas(1);
        vm.stopPrank();
        _situation(kind, uint256(ONE));
        gasLimit = bound(gasLimit, 10_000, 1_500_000);
        uint256 snap = vm.snapshotState();
        oracle.poke{gas: 10_000_000}();
        (uint64 truth,,,) = oracle.storedTimers();
        (, uint64 acceptedTruth) = oracle.lastAcceptedPrice();
        vm.revertToState(snap);
        (uint256 acceptedBefore, uint64 acceptedAtBefore) = oracle.lastAcceptedPrice();
        (bool ok, bytes memory ret) = address(oracle).call{gas: gasLimit}(abi.encodeCall(oracle.poke, ()));
        (uint64 failedSince,,,) = oracle.storedTimers();
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        (bool invalid,) = oracle.decimalsStatus();
        assertFalse(invalid, "gas never marks the decimals");
        if (ok) {
            assertEq(failedSince, truth, "a completed poke stores the true failure start");
            assertEq(acceptedAt, acceptedTruth, "and the true accepted price");
        } else {
            bytes4 sel = bytes4(ret);
            assertTrue(
                ret.length == 0 || sel == ILPOracleErrors.InsufficientGas.selector || sel == Errors.FailedCall.selector
            );
            assertEq(failedSince, 0, "a starved poke stores no failure");
            assertEq(accepted, acceptedBefore);
            assertEq(acceptedAt, acceptedAtBefore);
        }
    }
}
