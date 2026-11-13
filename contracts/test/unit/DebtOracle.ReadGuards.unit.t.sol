// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {IDebtOracleErrors} from "../../src/oracle/debt-oracle/IDebtOracleErrors.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";

/// @title DebtOracleReadGuardsUnitTest
/// @notice The gas guard of every external read (SPEC-ORC-023): a view given too little gas reverts
/// `InsufficientGas(gasLeft, required)` at the read the guard stops, never answering a failed asset; given enough it
/// answers the healthy asset Live.
contract DebtOracleReadGuardsUnitTest is DebtOracleFixture {
    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 10);
    }

    // TEST-042 verifies: REQ-ORACLE-102, SPEC-ORC-023, REQ-ORACLE-039, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-102 (no caller can make a healthy feed look failed)
    /// @notice `getPriceState` called with 60,000 to 1,000,000 gas in steps of 10,000: every call either answers the
    /// healthy asset Live at $0.9999 or reverts `InsufficientGas(gasLeft, required)` with `gasLeft < required`; the
    /// starved calls do revert at the guard, and 1,000,000 gas answers.
    function test_TEST_042_starvedReadRevertsAtTheGuard() public view {
        uint256 guarded = 0;
        bool answered = false;
        for (uint256 gas = 60_000; gas <= 1_000_000; gas += 10_000) {
            (bool ok, bytes memory ret) =
                address(oracle).staticcall{gas: gas}(abi.encodeCall(IDebtOracle.getPriceState, ()));
            if (ok) {
                DebtPriceView memory v = abi.decode(ret, (DebtPriceView));
                assertEq(uint8(v.state), uint8(PriceState.Live), "a healthy asset");
                assertEq(uint256(v.answer), 99_990_000);
                answered = gas == 1_000_000 || answered;
                continue;
            }
            assertEq(ret.length, 68, "the guard's revert, not an out-of-gas");
            assertEq(bytes4(ret), IDebtOracleErrors.InsufficientGas.selector);
            (uint256 left, uint256 required) = abi.decode(_tail(ret), (uint256, uint256));
            assertLt(left, required);
            ++guarded;
        }
        assertGt(guarded, 0, "some starved call stops at the guard");
        assertTrue(answered, "1,000,000 gas answers");
    }

    function _tail(
        bytes memory ret
    ) internal pure returns (bytes memory t) {
        t = new bytes(ret.length - 4);
        for (uint256 i = 0; i < t.length; ++i) {
            t[i] = ret[i + 4];
        }
    }
}
