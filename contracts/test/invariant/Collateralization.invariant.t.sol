// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollWorld, CollateralizationHandler} from "./handlers/CollateralizationHandler.sol";

/// @title CollateralizationInvariantTest
/// @notice Backing and per-proxy ledger invariants on the real Collateralization, the real Lock, the real vault token
/// and the real local Aave V4 (the LPVault, RiskModule and LPOracle are the fixture's mocks): random sequences of
/// pledges, withdrawals, borrows, repays, price moves, honest liquidations, seize-and-keep liquidations by a
/// non-conforming LPVaultSwap and pending settlements by two borrowers. After every call: supply equals credited plus
/// pending (INV-001, every burn here is settled in its own call); each proxy's supplied shares plus its unreconciled
/// kept units equal its credited units (INV-008, equality again after any withdrawal or settlement of that proxy); the
/// account credits sum to the market total; pending units plus unreconciled kept units equal what LPVaultSwap holds.
/// @dev Each handler call is one transaction: a member's Lock session spans several calls the handler makes.
/// forge-config: default.isolate = false
contract CollateralizationInvariantTest is CollateralizationFixture {
    CollateralizationHandler internal handler;

    function setUp() public {
        _deployCollateralization();
        CollWorld memory world = CollWorld({
            coll: coll,
            lock: lock,
            token: token,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            debt: debt,
            vtPrice: vtPrice,
            adapter: adapter,
            lpVaultSwap: lpVaultSwap,
            vtReserveId: vtReserveId,
            debtReserveId: debtReserveId,
            marketId: MARKET_ID
        });
        handler = new CollateralizationHandler(world, [aliceProxy, bobProxy], [alice, bob]);
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](8);
        actions[0] = CollateralizationHandler.pledge.selector;
        actions[1] = CollateralizationHandler.withdraw.selector;
        actions[2] = CollateralizationHandler.borrow.selector;
        actions[3] = CollateralizationHandler.repay.selector;
        actions[4] = CollateralizationHandler.setPrice.selector;
        actions[5] = CollateralizationHandler.liquidate.selector;
        actions[6] = CollateralizationHandler.seizeAndKeep.selector;
        actions[7] = CollateralizationHandler.settlePending.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-083 verifies: INV-001, SPEC-BACK-009
    // TEST-153 verifies: INV-001, INV-058, REQ-VAULT-137
    // Sources: 4.1 INV-001, 5.1 TEST-153 (supply == credited + pending after every call)
    function invariant_TEST_153_supplyEqualsCreditedPlusPending() public view {
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "backing");
    }

    // TEST-085 verifies: INV-008, REQ-VAULT-129, REQ-VAULT-140
    // TEST-153 verifies: INV-008, INV-058, SPEC-BACK-011
    // Sources: 4.1 INV-008, 5.1 TEST-085
    function invariant_TEST_085_suppliedPlusUnreconciledEqualsCredited() public view {
        uint256 sum = 0;
        for (uint256 i = 0; i < 2; ++i) {
            address proxy = handler.proxyAt(i);
            uint256 credited = coll.getAccountCredited(proxy, vt);
            uint256 supplied = _shares(proxy);
            assertLe(supplied, credited, "supply at most credited");
            assertEq(supplied + handler.unreconciled(proxy), credited, "shortfall is exactly the kept units");
            sum += credited;
        }
        assertEq(sum, coll.getTotalCredited(vt), "account credits sum to the market total");
    }

    // TEST-153 verifies: INV-058, REQ-VAULT-137, REQ-VAULT-139
    function invariant_TEST_153_pendingBackedByKeptUnits() public view {
        uint256 unreconciled = handler.unreconciled(aliceProxy) + handler.unreconciled(bobProxy);
        assertEq(coll.getPending(vt).units + unreconciled, handler.keptHeld(), "pending + unreconciled = kept");
    }
}
