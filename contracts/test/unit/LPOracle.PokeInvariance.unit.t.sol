// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";

/// @title LPOraclePokeInvarianceUnitTest
/// @notice Whether a `poke()` can move the price Aave reads (`latestAnswer`, the AaveOracle source of the vault-token
/// reserve) within one block, which decides whether LPVaultSwap may read the account's health factor before it pokes
/// the market's LPOracle. A poke stores first observations only (Q-199): a newly accepted round (Live serves the fresh
/// price either way), the first failure (`failedSince = min(staleStart, now)`, the start the view already assumes) and
/// the first disagreement (`disagreeSince = now`, likewise) leave `latestAnswer` unchanged in the same block. The one
/// evaluation that differs is the token-decimals check, which only the poke reads (REQ-ORACLE-107): once a token's
/// decimals return to the stored value, views still serve the accepted price (Cached) until the poke clears the mark
/// and the market serves its fresh price (Live). So a health factor read before the poke can differ from the one Aave
/// applies in `liquidationCall` after it, and LPVaultSwap reads it after its pokes (REQ-SWAP-006).
/// forge-config: default.isolate = false
contract LPOraclePokeInvarianceUnitTest is LPOracleFixture {
    function setUp() public {
        _deployMarket();
    }

    /// @dev The next block at `t`.
    function _block(
        uint256 t
    ) internal {
        vm.warp(t);
        vm.roll(block.number + 1);
    }

    /// @dev `latestAnswer` and the state before and after one poke in the current block.
    function _acrossPoke() internal returns (int256 before, int256 after_, PriceState sBefore, PriceState sAfter) {
        before = oracle.latestAnswer();
        sBefore = _state().state;
        oracle.poke();
        after_ = oracle.latestAnswer();
        sAfter = _state().state;
    }

    // TEST-049 verifies: REQ-SWAP-006, REQ-SWAP-008, REQ-ORACLE-029, Q-199
    /// @notice A new round 1 % lower on every feed, not yet accepted: the poke stores it as the accepted price, and
    /// the served price is the same before and after (Live serves the fresh price).
    function test_TEST_049_acceptingANewRoundLeavesTheServedPrice() public {
        _block(T0 + 600);
        _pushAll(int256(99e6), T0 + 600);
        int256 accepted0 = _state().acceptedAnswer;
        (int256 before, int256 after_, PriceState s0, PriceState s1) = _acrossPoke();
        assertEq(uint8(s0), uint8(PriceState.Live), "Live");
        assertEq(uint8(s1), uint8(PriceState.Live), "still Live");
        assertNotEq(_state().acceptedAnswer, accepted0, "the poke stored the new round");
        assertEq(after_, before, "the served price did not move");
    }

    // TEST-049 verifies: REQ-SWAP-006, REQ-SWAP-008, REQ-ORACLE-027, Q-199
    /// @notice Every feed past its heartbeat and margin: the poke records the failure start the view already uses,
    /// and the market serves the accepted price before and after.
    function test_TEST_049_recordingAFailureLeavesTheServedPrice() public {
        _block(T0 + 88_201);
        (int256 before, int256 after_, PriceState s0, PriceState s1) = _acrossPoke();
        assertEq(uint8(s0), uint8(PriceState.Cached), "Cached before");
        assertEq(uint8(s1), uint8(PriceState.Cached), "Cached after");
        (uint64 failedSince,,,) = oracle.storedTimers();
        assertGt(failedSince, 0, "the poke stored the failure start");
        assertEq(after_, before, "the served price did not move");
    }

    // TEST-049 verifies: REQ-SWAP-006, REQ-SWAP-008, REQ-ORACLE-028, Q-199
    /// @notice Token A's alternate route reads $0.97 against $1.00: the poke stores the disagreement start the view
    /// already uses, and the served price and the pause are the same before and after.
    function test_TEST_049_recordingADisagreementLeavesTheServedPrice() public {
        _block(T0 + 600);
        _pushAll(int256(ONE), T0 + 600);
        aA.push(int256(97e6), T0 + 600);
        bool pause0 = _state().disagreementPauseActive;
        (int256 before, int256 after_,,) = _acrossPoke();
        (, uint64 disagreeSince,,) = oracle.storedTimers();
        assertEq(disagreeSince, T0 + 600, "the poke stored the disagreement start");
        assertTrue(pause0 && _state().disagreementPauseActive, "inside the pause before and after");
        assertEq(after_, before, "the served price did not move");
    }

    // TEST-049 verifies: REQ-SWAP-006, REQ-ORACLE-107
    /// @notice The exception: token A's decimals changed (the poke marks the configuration invalid and the market
    /// serves the accepted price), the feeds then fall 2 %, and the decimals return. Views keep serving the accepted
    /// price until the next poke clears the mark, after which the market serves its fresh price: the poke moves the
    /// price Aave reads, so an account's health factor read before the poke can differ from the one after.
    function test_TEST_049_clearingADecimalsMarkMovesTheServedPrice() public {
        tokenA.setDecimals(18);
        _block(T0 + 60);
        _pushAll(int256(ONE), T0 + 60);
        oracle.poke();
        _block(T0 + 120);
        _pushAll(int256(98e6), T0 + 120);
        tokenA.setDecimals(6);
        PriceStateView memory v = _state();
        (int256 before, int256 after_, PriceState s0, PriceState s1) = _acrossPoke();
        assertEq(uint8(s0), uint8(PriceState.Cached), "the stored mark holds until the poke");
        assertEq(before, v.acceptedAnswer, "views serve the accepted price");
        assertEq(uint8(s1), uint8(PriceState.Live), "the poke clears the mark");
        assertLt(after_, before, "the served price moved across the poke");
    }
}
