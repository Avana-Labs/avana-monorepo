// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollWorld, CollateralizationHandler} from "./handlers/CollateralizationHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

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
contract CollateralizationInvariantTest is CollateralizationFixture, HandlerReach {
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
        handler.seedAccounts();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
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

    // TEST-082 verifies: TEST-007
    /// @notice The handler does real work: over 32 fixed-seed runs of 50 calls from this suite's set-up state, every
    /// action succeeds in at least 30 % of its calls and every target state is reached in at least 75 % of the runs.
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](8);
        names[0] = "pledge";
        names[1] = "withdraw";
        names[2] = "borrow";
        names[3] = "repay";
        names[4] = "setPrice";
        names[5] = "liquidate";
        names[6] = "seizeAndKeep";
        names[7] = "settlePending";
        string[] memory targets = new string[](3);
        targets[0] = "honest liquidation";
        targets[1] = "kept seizure";
        targets[2] = "pending settlement";
        Reach memory r = _replay(address(handler), _actions(), CollateralizationHandler.Skipped.selector, 32, 50, 3);
        _check(r, names, targets, 30, 75);
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](3);
        hit[0] = handler.honestLiquidations() != 0;
        hit[1] = handler.keptSeizures() != 0;
        hit[2] = handler.pendingSettlements() != 0;
    }

    function _actions() internal pure returns (bytes4[] memory actions) {
        actions = new bytes4[](8);
        actions[0] = CollateralizationHandler.pledge.selector;
        actions[1] = CollateralizationHandler.withdraw.selector;
        actions[2] = CollateralizationHandler.borrow.selector;
        actions[3] = CollateralizationHandler.repay.selector;
        actions[4] = CollateralizationHandler.setPrice.selector;
        actions[5] = CollateralizationHandler.liquidate.selector;
        actions[6] = CollateralizationHandler.seizeAndKeep.selector;
        actions[7] = CollateralizationHandler.settlePending.selector;
    }
}
