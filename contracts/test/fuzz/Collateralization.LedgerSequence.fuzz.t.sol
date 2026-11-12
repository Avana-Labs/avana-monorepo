// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationLedgerModel} from "../unit/Collateralization.LedgerModel.sol";

/// @title CollateralizationLedgerSequenceFuzzTest
/// @notice Random ledger sequences on the real Collateralization and local Aave V4 compared with the reference model
/// after every step: pledges of random sizes by two borrowers, partial removals and re-credits of random records in
/// place, more pledges inserted among the changed records, and withdrawals of random records. Every step checks list
/// order (INV-015), totals, charges and counters (TEST-097) and supply = credited (INV-001, INV-008).
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 128
contract CollateralizationLedgerSequenceFuzzTest is CollateralizationLedgerModel {
    function setUp() public {
        _deployCollateralization();
    }

    // TEST-124 verifies: INV-015, REQ-VAULT-016, REQ-VAULT-024, REQ-VAULT-033, SPEC-BACK-006, Q-194
    // TEST-097 verifies: INV-027, REQ-VAULT-036, SPEC-BACK-005, SPEC-BACK-013
    // Sources: 5.1 TEST-124 (records of random sizes in random order keep the list ordered), TEST-097
    /// @notice Up to twelve pledges of 1e6 to 5e9 units, interleaved with partial removals and re-credits of earlier
    /// records and withdrawals of random records; the ledger equals the model after every step.
    function testFuzz_TEST_124_randomSequenceMatchesModel(
        uint256 seed
    ) public {
        uint256 steps = 8 + seed % 9;
        uint256 nextKey = 1;
        for (uint256 s = 0; s < steps; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, s)));
            uint256 op = r % 10;
            uint256 open = mMarket.length;
            if (op < 5 || open == 0) {
                address proxy = (r >> 8) % 2 == 0 ? aliceProxy : bobProxy;
                address depositor = proxy == aliceProxy ? alice : bob;
                if (mList[proxy].length + mZero[proxy].length == 16) continue;
                uint128 units = uint128(1e6 + (r >> 16) % 5e9);
                _doPledge(depositor, proxy, _key(nextKey++), units);
            } else if (op < 7) {
                uint256 id = mMarket[(r >> 8) % open];
                uint128 credited = mRec[id].credited;
                if (credited < 2) continue;
                uint128 units = uint128(1 + (r >> 16) % (credited - 1));
                _doPartial(id, units);
            } else if (op < 9) {
                uint256 id = mMarket[(r >> 8) % open];
                uint128 extra = uint128(1 + (r >> 16) % 2e9);
                _doRecredit(id, extra);
            } else {
                _doWithdraw(mMarket[(r >> 8) % open]);
            }
            _check("random step");
        }
    }

    // TEST-014 verifies: SPEC-BACK-005, REQ-VAULT-036, REQ-VAULT-071
    // Sources: 5.1 TEST-014 (exit charge independent of how the exit is split)
    /// @notice Removing the same units from a record in one partial removal or in two leaves the same charge (the
    /// fixed basis of SPEC-BACK-005), on the real ledger.
    function testFuzz_TEST_014_exitChargeIndependentOfSplit(
        uint128 units,
        uint128 first,
        uint128 second
    ) public {
        units = uint128(bound(units, 3, 2e12));
        uint256 total = bound(first, 2, units - 1);
        first = uint128(bound(second, 1, total - 1));
        uint256 a = _doPledge(alice, aliceProxy, _key(1), units);
        uint256 b = _doPledge(bob, bobProxy, _key(2), units);
        _doPartial(a, uint128(total));
        _doPartial(b, first);
        _doPartial(b, uint128(total) - first);
        assertEq(coll.getRecord(a).currentUsdCharge, coll.getRecord(b).currentUsdCharge, "same charge either way");
        assertEq(coll.getRecord(a).credited, coll.getRecord(b).credited);
        _check("split exits");
    }
}
