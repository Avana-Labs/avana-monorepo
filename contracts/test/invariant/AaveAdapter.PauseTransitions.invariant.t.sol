// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {AaveAdapterPauseHandler, PauseWorld} from "./handlers/AaveAdapterPauseHandler.sol";

/// @title AaveAdapterPauseTransitionsInvariantTest
/// @notice The Adapter side of TEST-193: the Hub's pause state and reason, address freezes and a reverting
/// MarketRegistry or RiskModule change at random between borrower actions. After every call: no exit Aave allows ever
/// reverted (repay by the borrower or a third party, debt-free withdrawal, `repayAllAndWithdraw`, fee collection, the
/// debt mark); no pledge, borrow or withdrawal with debt succeeded in a state that refuses it; the Lock is free; every
/// market's supply stays backed.
/// forge-config: default.isolate = false
contract AaveAdapterPauseTransitionsInvariantTest is AaveAdapterFixture {
    AaveAdapterPauseHandler internal handler;

    function setUp() public override {
        super.setUp();
        PauseWorld memory world = PauseWorld({
            adapter: adapterC,
            coll: coll,
            registry: registry,
            risk: risk,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            hub: aave.hub,
            vaultToken: vt,
            market: MARKET_ID,
            reserve: vtReserveId,
            gho: debt,
            ghoReserve: debtReserveId,
            integrationId: INTEGRATION
        });
        handler = new AaveAdapterPauseHandler(world, [alice, bob, carol], makeAddr("rescueService"));
        // Each wallet starts with an account and some debt, so every exit has something to exit.
        for (uint256 i = 0; i < 3; ++i) {
            handler.pledge(uint8(i));
            handler.pledge(uint8(i));
            handler.borrow(uint8(i), 500e18);
        }
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](11);
        actions[0] = AaveAdapterPauseHandler.setPause.selector;
        actions[1] = AaveAdapterPauseHandler.setFreeze.selector;
        actions[2] = AaveAdapterPauseHandler.breakNeighbours.selector;
        actions[3] = AaveAdapterPauseHandler.pledge.selector;
        actions[4] = AaveAdapterPauseHandler.borrow.selector;
        actions[5] = AaveAdapterPauseHandler.withdrawWithDebt.selector;
        actions[6] = AaveAdapterPauseHandler.repay.selector;
        actions[7] = AaveAdapterPauseHandler.repayAllAndWithdraw.selector;
        actions[8] = AaveAdapterPauseHandler.withdrawDebtFree.selector;
        actions[9] = AaveAdapterPauseHandler.collectFees.selector;
        actions[10] = AaveAdapterPauseHandler.refreshDebtMark.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-032, REQ-PROXY-035, REQ-ADAPTER-071, REQ-ADAPTER-096, REQ-ADAPTER-104, INV-043, INV-044, INV-045, INV-067
    // Sources: 5.1 TEST-193 (Adapter side), QNT-14, QNT-15
    /// @notice No exit Aave allows ever reverted, in any pause state or reason, for a frozen wallet, with a reverting
    /// MarketRegistry or RiskModule.
    function invariant_TEST_193_exitsNeverFail() public view {
        assertEq(handler.exitFailures(), 0, string(handler.lastExitError()));
    }

    // TEST-193 verifies: REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-072, REQ-ADAPTER-073, REQ-ADAPTER-082, REQ-ADAPTER-083, INV-049
    /// @notice No pledge succeeded under `Paused(MintPathSuspect)` or into a debt-free account under Frozen, no frozen
    /// wallet opened an account, no borrow succeeded outside None or for a frozen wallet, and no withdrawal with debt
    /// succeeded under Paused or for a frozen wallet.
    function invariant_TEST_193_newActivityOnlyWhereAllowed() public view {
        assertEq(handler.forbiddenSuccesses(), 0, "new activity in a refusing state");
    }

    // TEST-060 verifies: REQ-PROXY-048, REQ-LOCK-007
    /// @notice The Lock is free between calls whatever the call did.
    function invariant_TEST_060_lockFreeBetweenCalls() public view {
        assertFalse(lock.isLocked(), "lock held between calls");
    }

    // TEST-083 verifies: REQ-ADAPTER-069, SPEC-PROXY-008, INV-001, INV-080
    /// @notice With no seizure in this campaign, supply equals the credited units exactly.
    function invariant_TEST_083_supplyEqualsCredited() public view {
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "backing");
        assertEq(token.balanceOf(adapter), 0, "adapter holds no units");
    }

    // TEST-193 verifies: REQ-ADAPTER-086
    /// @notice A directed run of the campaign's worst case: every stop at once, then every exit.
    function test_TEST_193_everyStopThenEveryExit() public {
        handler.setPause(3);
        handler.setFreeze(0, true);
        handler.breakNeighbours(true, true);
        handler.repay(0, true, 100e18);
        // Fees and the debt mark while the positions are open (after the withdrawals there would be nothing to act on).
        handler.collectFees(0, 1000);
        handler.refreshDebtMark(0);
        handler.repayAllAndWithdraw(0);
        handler.withdrawDebtFree(0);
        assertEq(handler.exitFailures(), 0, string(handler.lastExitError()));
        assertEq(handler.exitsDone(), 5, "exits completed");
        handler.borrow(1, 1e18);
        handler.pledge(1);
        assertEq(handler.forbiddenSuccesses(), 0, "refused");
        registry.setPause(aave.hub, PauseState.None, PauseReason.None);
    }
}
