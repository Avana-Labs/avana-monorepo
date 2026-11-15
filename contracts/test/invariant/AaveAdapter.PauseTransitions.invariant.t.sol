// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {AaveAdapterPauseHandler, PauseWorld} from "./handlers/AaveAdapterPauseHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title AaveAdapterPauseTransitionsInvariantTest
/// @notice The Adapter side of TEST-193: the Hub's pause state and reason, address freezes and a reverting
/// MarketRegistry or RiskModule change at random between borrower actions. After every call: no exit Aave allows ever
/// reverted (repay by the borrower or a third party, debt-free withdrawal, `repayAllAndWithdraw`, fee collection, the
/// debt mark); no pledge, borrow or withdrawal with debt succeeded in a state that refuses it; the Lock is free; every
/// market's supply stays backed.
/// forge-config: default.isolate = false
contract AaveAdapterPauseTransitionsInvariantTest is AaveAdapterFixture, HandlerReach {
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, AaveAdapterPauseHandler.Skipped.selector, 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(11, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](11), new string[](11), new int16[][](11));
        (actions[0], names[0]) = (AaveAdapterPauseHandler.setPause.selector, "setPause");
        kinds[0] = new int16[](1);
        kinds[0][0] = 8;
        (actions[1], names[1]) = (AaveAdapterPauseHandler.setFreeze.selector, "setFreeze");
        kinds[1] = new int16[](2);
        kinds[1][0] = 8;
        kinds[1][1] = 1;
        (actions[2], names[2]) = (AaveAdapterPauseHandler.breakNeighbours.selector, "breakNeighbours");
        kinds[2] = new int16[](2);
        kinds[2][0] = 1;
        kinds[2][1] = 1;
        (actions[3], names[3]) = (AaveAdapterPauseHandler.pledge.selector, "pledge");
        kinds[3] = new int16[](1);
        kinds[3][0] = 8;
        (actions[4], names[4]) = (AaveAdapterPauseHandler.borrow.selector, "borrow");
        kinds[4] = new int16[](2);
        kinds[4][0] = 8;
        kinds[4][1] = 256;
        (actions[5], names[5]) = (AaveAdapterPauseHandler.withdrawWithDebt.selector, "withdrawWithDebt");
        kinds[5] = new int16[](1);
        kinds[5][0] = 8;
        (actions[6], names[6]) = (AaveAdapterPauseHandler.repay.selector, "repay");
        kinds[6] = new int16[](3);
        kinds[6][0] = 8;
        kinds[6][1] = 1;
        kinds[6][2] = 256;
        (actions[7], names[7]) = (AaveAdapterPauseHandler.repayAllAndWithdraw.selector, "repayAllAndWithdraw");
        kinds[7] = new int16[](1);
        kinds[7][0] = 8;
        (actions[8], names[8]) = (AaveAdapterPauseHandler.withdrawDebtFree.selector, "withdrawDebtFree");
        kinds[8] = new int16[](1);
        kinds[8][0] = 8;
        (actions[9], names[9]) = (AaveAdapterPauseHandler.collectFees.selector, "collectFees");
        kinds[9] = new int16[](2);
        kinds[9][0] = 8;
        kinds[9][1] = 256;
        (actions[10], names[10]) = (AaveAdapterPauseHandler.refreshDebtMark.selector, "refreshDebtMark");
        kinds[10] = new int16[](1);
        kinds[10][0] = 8;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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
