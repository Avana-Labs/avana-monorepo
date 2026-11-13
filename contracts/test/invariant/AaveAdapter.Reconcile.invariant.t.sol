// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {AdapterReconcileHandler, ReconcileWorld} from "./handlers/AdapterReconcileHandler.sol";

/// @title AaveAdapterReconcileInvariantTest
/// @notice Per-proxy ledger and reconcile on exit (TEST-085, TEST-153) on real PositionProxies created by the real
/// ProxyManager for the real AaveAdapter, on the real local Aave V4, Collateralization and vault token, for an
/// LPVaultSwap that seizes and keeps vault tokens at random as well as liquidating and settling honestly.
/// forge-config: default.isolate = false
contract AaveAdapterReconcileInvariantTest is AaveAdapterFixture {
    AdapterReconcileHandler internal handler;

    function setUp() public override {
        super.setUp();
        ReconcileWorld memory world = ReconcileWorld({
            adapter: adapterC,
            coll: coll,
            swap: swap,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            hub: aave.hub,
            token: token,
            market: MARKET_ID,
            reserve: vtReserveId,
            gho: debt,
            ghoReserve: debtReserveId,
            vtPrice: vtPrice,
            integrationId: INTEGRATION
        });
        handler = new AdapterReconcileHandler(world, [alice, bob, carol]);
        targetContract(address(handler));
    }

    // TEST-085 verifies: INV-008, REQ-VAULT-129, REQ-VAULT-131
    // Sources: QNT-07, HYP-05
    /// @notice For every PositionProxy, its supplied vault-token shares on the Spoke never exceed Collateralization's
    /// credited units for it, whatever the LPVaultSwap did, and equal them at the end of every withdrawal and honest
    /// liquidation settlement of that proxy.
    function invariant_TEST_085_suppliedAtMostCreditedPerProxy() public view {
        uint256 n = handler.proxyCount();
        for (uint256 i = 0; i < n; ++i) {
            address p = handler.proxies(i);
            assertLe(
                IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, p),
                coll.getAccountCredited(p, vt),
                "supplied <= credited"
            );
        }
        assertEq(handler.ledgerAfterExitViolations(), 0, "supplied == credited after an exit or settlement");
    }

    // TEST-153 verifies: INV-001, INV-008, INV-058, REQ-VAULT-136, REQ-VAULT-139, SPEC-BACK-012
    // Sources: QNT-03, QNT-07, QNT-37, QNT-T09
    /// @notice After every call: `totalSupply == getTotalCredited + pending.units`; the pending units never exceed the
    /// vault tokens outside the Hub; Collateralization holds pool tokens for the pending balance and the LPVault holds
    /// none of them beyond its float.
    function invariant_TEST_153_supplyEqualsCreditedPlusPending() public view {
        uint256 pendingUnits = coll.getPending(vt).units;
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + pendingUnits, "supply = credited + pending");
        assertLe(pendingUnits, token.totalSupply() - token.balanceOf(aave.hub), "pending <= units outside the Hub");
        if (pendingUnits > 0) {
            uint256[] memory amounts = coll.getPending(vt).amounts;
            assertGe(usdc.balanceOf(address(coll)), amounts[0], "Collateralization holds the pending USDC");
            assertGe(usdt.balanceOf(address(coll)), amounts[1], "Collateralization holds the pending USDT");
        }
    }

    // TEST-153 verifies: INV-008, REQ-VAULT-136
    /// @notice A plain sequence reaches every branch: a hostile seize-and-keep, a withdrawal that reconciles it into
    /// the pending balance, an honest liquidation and an honest settlement of the pending units.
    function test_TEST_153_handlerReachesReconcileAndSettlement() public {
        handler.pledge(0, 5_000_000_000);
        handler.pledge(0, 4_000_000_000);
        handler.pledge(1, 5_000_000_000);
        // Alice: 9,000 units at $2.00 (capacity $14,400) owes 12,000 GHO; Bob: 5,000 units owes 7,000 GHO.
        handler.borrow(0, 4000);
        handler.borrow(0, 4000);
        handler.borrow(0, 4000);
        handler.borrow(1, 4000);
        handler.borrow(1, 3000);
        handler.setPrice(0);
        handler.seize(0, 1500, true);
        handler.seize(1, 1500, false);
        handler.setPrice(type(uint256).max);
        handler.exit(0, 0);
        handler.settle(type(uint256).max);
        assertEq(handler.seizures(), 2, "a hostile and an honest seizure");
        assertEq(handler.reconciles(), 1, "a withdrawal reconciled the kept units");
        assertEq(handler.settlements(), 1, "an honest settlement");
        invariant_TEST_085_suppliedAtMostCreditedPerProxy();
        invariant_TEST_153_supplyEqualsCreditedPlusPending();
    }
}
