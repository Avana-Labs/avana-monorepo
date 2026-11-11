// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {CollateralizationLedgerHarness, HarnessLock} from "../utils/harness/CollateralizationLedgerHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title CollateralizationHalmosTest
/// @notice Symbolic checks of Collateralization's record internals for every credited value, debit size, caller and
/// Lock holder: the exit charge depends only on the remaining units (PROP-028), insertion is largest-first with ties by
/// lowest ID (PROP-014), a debit walks from the head and touches only what it debits (PROP-012), a debit above the
/// credit reverts with no change (PROP-013), and the caller gates admit exactly the named member holding the Lock
/// (PROP-037).
/// @dev The harness inherits the production internals and writes records as `pledge` does after its external checks.
/// Lists are three records long (the walks are concrete loops); credited values are bounded to uint64 and charges to
/// the records' own units so the nonlinear charge arithmetic stays tractable. Fuzz twins in
/// `test/fuzz/Collateralization.fuzz.t.sol` cover the full ranges.
/// Compilation: the harness inherits the facets and compiles with the default legacy pipeline, while the deployed
/// `Collateralization.sol` is built via IR at 200 runs (foundry.toml compilation restriction). These checks therefore
/// cover the source logic of the internals; the deployed bytecode is covered by the unit, fuzz, invariant and gas suites,
/// which deploy `Collateralization.sol:Collateralization`, and by Certora, which compiles with the same two settings.
contract CollateralizationHalmosTest is Test {
    address internal constant PROXY = address(0xA11CE);
    address internal constant ADAPTER = address(0xADA);
    address internal constant SWAP = address(0x5A1);

    CollateralizationLedgerHarness internal h;
    HarnessLock internal lock;

    function setUp() public {
        lock = new HarnessLock();
        h = new CollateralizationLedgerHarness(ADAPTER, SWAP, address(lock));
    }

    // PROP-028 verifies: SPEC-BACK-005, SPEC-BACK-013, REQ-VAULT-036, INV-027
    /// @notice `ceil(V0 * r / U0)` is monotone in the remaining units, at most `V0`, `V0` at `r = U0` and 0 at
    /// `r = 0`, so any split of exits releases the same total and the last exit releases exactly what remains.
    function check_PROP_028_exitChargeIndependentOfSplit(
        uint64 v0,
        uint64 u0,
        uint64 x1,
        uint64 x2
    ) public view {
        vm.assume(u0 > 0 && x1 <= u0 && x2 <= u0 - x1);
        uint256 afterFirst = h.remainingCharge(v0, u0 - x1, u0);
        uint256 afterBoth = h.remainingCharge(v0, u0 - x1 - x2, u0);
        assert(afterBoth <= afterFirst);
        assert(afterFirst <= v0);
        assert(h.remainingCharge(v0, 0, u0) == 0);
        assert(h.remainingCharge(v0, u0, u0) == v0);
    }

    // PROP-014 verifies: SPEC-BACK-006, REQ-VAULT-016, INV-015
    /// @notice Three pledges of any sizes leave the list ordered largest-first with ties by lowest record ID.
    function check_PROP_014_insertionLargestFirst(
        uint64 a,
        uint64 b,
        uint64 c
    ) public {
        vm.assume(a > 0 && b > 0 && c > 0);
        h.seed(PROXY, a, 1, 0, 0);
        h.seed(PROXY, b, 1, 0, 0);
        h.seed(PROXY, c, 1, 0, 0);
        uint256[] memory l = h.list(PROXY);
        assert(l.length == 3);
        for (uint256 i = 1; i < 3; ++i) {
            uint256 prev = h.record(l[i - 1]).credited;
            uint256 cur = h.record(l[i]).credited;
            assert(prev > cur || (prev == cur && l[i - 1] < l[i]));
        }
    }

    // PROP-012 verifies: SPEC-BACK-006, REQ-VAULT-054, REQ-VAULT-056, REQ-VAULT-074, INV-015, ATTACK-013
    /// @notice A debit of `u <= Σ credited` over a three-record list debits exactly `u` head first: every record
    /// before the last one touched is emptied and moved to the zero-credit list, the last one touched keeps the rest
    /// and sits at the head, the records after it are untouched.
    function check_PROP_012_debitHeadFirst(
        uint64 a,
        uint64 b,
        uint64 c,
        uint256 u
    ) public {
        vm.assume(a > 0 && b > 0 && c > 0);
        h.seed(PROXY, a, 1, 0, 0);
        h.seed(PROXY, b, 1, 0, 0);
        h.seed(PROXY, c, 1, 0, 0);
        uint256 sum = uint256(a) + b + c;
        vm.assume(u <= sum);
        uint256[] memory before = h.list(PROXY);
        uint256[3] memory cr;
        for (uint256 i = 0; i < 3; ++i) {
            cr[i] = h.record(before[i]).credited;
        }
        h.debit(PROXY, u);
        assert(h.credit(PROXY) == sum - u);
        uint256 rem = u;
        uint256 emptied = 0;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 take = rem < cr[i] ? rem : cr[i];
            rem -= take;
            BackingRecord memory r = h.record(before[i]);
            assert(r.credited == cr[i] - take);
            assert(r.depositor != address(0));
            if (take == cr[i]) {
                assert(!r.inList);
                ++emptied;
            }
        }
        uint256[] memory l = h.list(PROXY);
        assert(l.length == 3 - emptied);
        if (emptied < 3) assert(l[0] == before[emptied]);
    }

    // PROP-013 verifies: SPEC-BACK-006, REQ-VAULT-055, REQ-VAULT-117
    /// @notice A debit above the account's credit reverts `InsufficientCredit` and leaves the credit unchanged.
    function check_PROP_013_debitAboveCreditReverts(
        uint64 a,
        uint64 b,
        uint256 u
    ) public {
        vm.assume(a > 0 && b > 0);
        h.seed(PROXY, a, 1, 0, 0);
        h.seed(PROXY, b, 1, 0, 0);
        uint256 sum = uint256(a) + b;
        vm.assume(u > sum);
        (bool ok, bytes memory ret) = address(h).call(abi.encodeCall(h.debit, (PROXY, u)));
        assert(!ok);
        assert(
            keccak256(ret) == keccak256(abi.encodeWithSelector(ICollateralizationErrors.InsufficientCredit.selector))
        );
        assert(h.credit(PROXY) == sum);
    }

    // PROP-037 verifies: REQ-VAULT-086, REQ-VAULT-091, REQ-LOCK-010, REQ-LOCK-016, INV-054
    /// @notice The Adapter gate passes exactly for the Adapter holding the Lock, the LPVaultSwap gate exactly for
    /// LPVaultSwap holding it, and a ledger view exactly while the Lock is free or read by its holder.
    function check_PROP_037_gatesAdmitOnlyTheHoldingMember(
        address caller,
        address holder
    ) public {
        lock.setHolder(holder);
        vm.prank(caller);
        (bool okA,) = address(h).call(abi.encodeCall(h.gateAdapter, ()));
        assert(okA == (caller == ADAPTER && holder == ADAPTER));
        vm.prank(caller);
        (bool okS,) = address(h).call(abi.encodeCall(h.gateLPVaultSwap, ()));
        assert(okS == (caller == SWAP && holder == SWAP));
        vm.prank(caller);
        (bool okV,) = address(h).call(abi.encodeCall(h.gateView, ()));
        assert(okV == (holder == address(0) || holder == caller));
    }
}
