// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @title CollateralizationSeizureGasTest
/// @notice Collateralization's own share of the worst-case liquidation of `SPEC-BACK-016`: an account-market at 16
/// records, an unsettled seizure reconciled first, then one `settleSeizure` that debits every record (16 record
/// updates, 16 list removals, 16 exposure releases and 16 + 1 LPVault `unwind` calls). The LPVault is the fixture's
/// constant-cost mock, so the figure is the ledger's work alone; the fork suite of TEST-269 measures the whole
/// liquidation with real Uniswap v3 and Slipstream unwinds against `G(16) = 5.15M`.
/// forge-config: default.isolate = false
contract CollateralizationSeizureGasTest is CollateralizationFixture {
    /// @notice Budget of the ledger's part: measured at about 1.2M with the mock LPVault, kept with margin so a
    /// regression in the per-record cost fails here before the fork measurement.
    uint256 internal constant LEDGER_BUDGET_16 = 1_600_000;

    function setUp() public {
        _deployCollateralization();
    }

    // TEST-269 verifies: SPEC-BACK-016, REQ-VAULT-108
    // Sources: 2.3 SPEC-BACK-016, REQ-VAULT-108 (16 records, about 5,150,000 gas for the whole liquidation)
    /// @notice A reconcile plus a 16-record debit stays within the ledger budget.
    function test_TEST_269_sixteenRecordSeizureWithReconcile() public {
        for (uint256 i = 0; i < 16; ++i) {
            _pledge(alice, aliceProxy, bytes32(100 + i), 500_000_000);
        }
        _borrow(aliceProxy, 12_000e18);
        vtPrice.set(1.3e8);
        uint256 kept = _seizeAndKeep(aliceProxy, 100e18);
        assertGt(kept, 0);

        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        uint256 seized = _seizeAndKeep(aliceProxy, 12_000e18);
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        uint256[] memory mins = new uint256[](2);
        vm.prank(lpVaultSwap);
        uint256 start = gasleft();
        coll.settleSeizure(aliceProxy, vt, seized, mins);
        uint256 used = start - gasleft();
        vm.prank(lpVaultSwap);
        lock.release();

        assertEq(coll.getAccountCredited(aliceProxy, vt), 0, "every record debited");
        assertEq(coll.getPending(vt).units, kept, "the kept seizure was reconciled first");
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 16, "all 16 records stay open at 0");
        assertLe(used, LEDGER_BUDGET_16, "ledger share of the 16-record liquidation");
        emit log_named_uint("settleSeizure gas, 16 records with reconcile", used);
    }
}
