// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapterHalmosTest} from "../halmos/AaveAdapter.halmos.t.sol";

/// @title AaveAdapterHalmosRepayUnitTest
/// @notice Replays the counterexamples of `check_repaySizingAndRefund` from Halmos run 43742353540 (debt 2^127) on the
/// production repay steps the Halmos check drives.
contract AaveAdapterHalmosRepayUnitTest is AaveAdapterHalmosTest {
    // TEST-029 verifies: REQ-PROXY-088, SPEC-PROXY-003
    function test_TEST_029_halmosRepayCounterexamplesHold() public {
        uint128 d = uint128(1) << 127;
        this.check_repaySizingAndRefund(d, d + (d >> 1), true);
    }

    // TEST-029 verifies: REQ-PROXY-088, SPEC-PROXY-003
    function test_TEST_029_halmosRepayAllAtCap() public {
        uint128 d = uint128(1) << 127;
        this.check_repaySizingAndRefund(d, d, true);
    }

    // TEST-029 verifies: REQ-PROXY-088, SPEC-PROXY-003
    function test_TEST_029_halmosPartialRepayAtDebt() public {
        uint128 d = uint128(1) << 127;
        this.check_repaySizingAndRefund(d, d, false);
    }

    // TEST-029 verifies: REQ-PROXY-088, SPEC-PROXY-003
    function test_TEST_029_halmosPartialRepayBelowDebt() public {
        uint128 d = uint128(1) << 127;
        this.check_repaySizingAndRefund(d, d >> 1, false);
    }

    // TEST-029 verifies: REQ-PROXY-088, SPEC-PROXY-003
    function test_TEST_029_smallRepay() public {
        this.check_repaySizingAndRefund(1000, 400, false);
    }
}
