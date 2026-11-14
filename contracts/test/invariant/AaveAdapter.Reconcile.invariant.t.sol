// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {AdapterReconcileHandler, ReconcileWorld} from "./handlers/AdapterReconcileHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title AaveAdapterReconcileInvariantTest
/// @notice Per-proxy ledger and reconcile on exit (TEST-085, TEST-153) on real PositionProxies created by the real
/// ProxyManager for the real AaveAdapter, on the real local Aave V4, Collateralization and vault token, for an
/// LPVaultSwap that seizes and keeps vault tokens at random as well as liquidating and settling honestly.
/// forge-config: default.isolate = false
contract AaveAdapterReconcileInvariantTest is AaveAdapterFixture, HandlerReach {
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
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    function _actions() internal pure returns (bytes4[] memory a) {
        a = new bytes4[](6);
        (a[0], a[1], a[2], a[3], a[4], a[5]) =
        (
            AdapterReconcileHandler.pledge.selector,
            AdapterReconcileHandler.borrow.selector,
            AdapterReconcileHandler.setPrice.selector,
            AdapterReconcileHandler.seize.selector,
            AdapterReconcileHandler.exit.selector,
            AdapterReconcileHandler.settle.selector
        );
    }

    // TEST-082 verifies: TEST-007
    /// @notice The handler reaches the states the reconcile invariants are about: over 32 fixed-seed runs of 50 calls
    /// from set-up, every action succeeds in at least 25 % of its calls (settle 10 %: it needs units an honest
    /// seizure left with LPVaultSwap) and a kept seizure, an honest liquidation, a reconciling exit and a settlement
    /// are each reached in at least 40 % of the runs (before steering: no seizure in any run).
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](6);
        (names[0], names[1], names[2], names[3], names[4], names[5]) =
        ("pledge", "borrow", "setPrice", "seize", "exit", "settle");
        string[] memory targets = new string[](4);
        (targets[0], targets[1], targets[2], targets[3]) =
        ("kept seizure", "honest liquidation", "reconciling exit", "settlement");
        uint256[] memory minOk = _floors(6, 25);
        minOk[5] = 10;
        Reach memory r = _replay(address(handler), _actions(), AdapterReconcileHandler.Skipped.selector, 32, 50, 4);
        _check(r, names, targets, minOk, _floors(4, 40));
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](4);
        hit[0] = handler.keptSeizures() != 0;
        hit[1] = handler.seizures() > handler.keptSeizures();
        hit[2] = handler.reconciles() != 0;
        hit[3] = handler.settlements() != 0;
    }

    /// @dev Five words, with `seize`'s `hostile` reduced to 0 or 1.
    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        uint256 w2 = _word(seed, 3);
        if (selector == AdapterReconcileHandler.seize.selector) w2 %= 2;
        return abi.encodeWithSelector(selector, _word(seed, 1), _word(seed, 2), w2, _word(seed, 4), _word(seed, 5));
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
        assertEq(handler.keptSeizures(), 1, "the hostile seizure kept units");
        assertEq(handler.reconciles(), 1, "a withdrawal reconciled the kept units");
        assertEq(handler.settlements(), 1, "an honest settlement");
        invariant_TEST_085_suppliedAtMostCreditedPerProxy();
        invariant_TEST_153_supplyEqualsCreditedPlusPending();
    }
}
