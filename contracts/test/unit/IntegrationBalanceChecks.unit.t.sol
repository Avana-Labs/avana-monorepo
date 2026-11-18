// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {Held, IntegrationBalanceChecks} from "../invariant/handlers/IntegrationBalanceChecks.sol";
import {Test} from "forge-std/Test.sol";

/// @title IntegrationBalanceChecksUnitTest
/// @notice The deficit branch of TEST-104's direct balance check (REQ-SWAP-027, SPEC-LIQ-022): the part of `B` paid
/// into the First-Loss Reserve reaches the Hub, and it must be all of `B` on a call of an account underwater before it
/// or that raised the Spoke's deficit, and 0 on any other call. One settlement: the caller funds 100, the routes recover 120, `D` 100, `A` 20, `B` 100.
contract IntegrationBalanceChecksUnitTest is Test {
    function _result() internal pure returns (LiquidationResult memory r) {
        (r.callerFunds, r.recovered, r.debtRepaid, r.avanaFee, r.borrowerSurplus) = (100, 120, 100, 20, 100);
    }

    /// @dev Balances before and after; `toReserve` of `B` reaches the Hub, the rest the wallet; `deficitRose` marks a
    /// call that raised the Spoke's deficit.
    function _held(
        uint256 toReserve,
        bool deficitRose
    ) internal pure returns (Held memory b, Held memory a) {
        return _held(toReserve, deficitRose, false);
    }

    /// @dev The same, with `underwater` marking an account underwater before the call.
    function _held(
        uint256 toReserve,
        bool deficitRose,
        bool underwater
    ) internal pure returns (Held memory b, Held memory a) {
        b.underwater = underwater;
        (b.caller, b.sources) = (100, 120);
        (a.hub, a.fee, a.wallet) = (100 + toReserve, 20, 100 - toReserve);
        a.deficit = deficitRose ? 1 : 0;
    }

    // TEST-104 verifies: REQ-SWAP-027, SPEC-LIQ-022
    function test_TEST_104_deficitCallFundsAllOfB() public pure {
        (Held memory b, Held memory a) = _held(100, true);
        (bool conserved, bool reported) = IntegrationBalanceChecks.direct(b, a, _result(), 100);
        assertTrue(conserved && reported, "B to the reserve on a deficit call");
    }

    // TEST-104 verifies: REQ-SWAP-027, SPEC-LIQ-022
    function test_TEST_104_reserveFundedWithoutDeficitIsABreak() public pure {
        (Held memory b, Held memory a) = _held(100, false);
        (, bool reported) = IntegrationBalanceChecks.direct(b, a, _result(), 100);
        assertFalse(reported, "B diverted without a deficit");
    }

    // TEST-104 verifies: REQ-SWAP-027, SPEC-LIQ-022
    function test_TEST_104_deficitCallPayingTheBorrowerIsABreak() public pure {
        (Held memory b, Held memory a) = _held(0, true);
        (, bool reported) = IntegrationBalanceChecks.direct(b, a, _result(), 0);
        assertFalse(reported, "B paid to the defaulted borrower");
    }

    // TEST-104 verifies: REQ-SWAP-027, SPEC-LIQ-022
    function test_TEST_104_underwaterCallWithoutDeficitFundsAllOfB() public pure {
        (Held memory b, Held memory a) = _held(100, false, true);
        (bool conserved, bool reported) = IntegrationBalanceChecks.direct(b, a, _result(), 100);
        assertTrue(conserved && reported, "B to the reserve on an underwater account's partial call");
    }

    // TEST-104 verifies: REQ-SWAP-027, SPEC-LIQ-022
    function test_TEST_104_underwaterCallPayingTheBorrowerIsABreak() public pure {
        (Held memory b, Held memory a) = _held(0, false, true);
        (, bool reported) = IntegrationBalanceChecks.direct(b, a, _result(), 0);
        assertFalse(reported, "B paid to the underwater borrower");
    }

    // TEST-104 verifies: REQ-SWAP-027, SPEC-LIQ-022
    function test_TEST_104_ordinaryCallPaysTheBorrower() public pure {
        (Held memory b, Held memory a) = _held(0, false);
        (bool conserved, bool reported) = IntegrationBalanceChecks.direct(b, a, _result(), 0);
        assertTrue(conserved && reported, "B to the borrower without a deficit");
    }
}
