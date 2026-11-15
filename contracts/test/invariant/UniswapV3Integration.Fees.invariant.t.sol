// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {LPVaultFeesHandler} from "./handlers/LPVaultFeesHandler.sol";

/// @title UniswapV3IntegrationFeesInvariantTest
/// @notice TEST-091 on the Uniswap v3 LPVault (the custody and fee code it shares with the Slipstream LPVault): random
/// sequences of pledges by two depositors, fee accruals, spot moves, seizures of any part of a position's units to
/// LPVaultSwap and fee collections naming the depositor, the other depositor or an attacker. After every call: fee
/// collection paid only the depositor of record, and paid every owed amount; no seizure lowered a position's owed fees;
/// for every position, the fees owed plus the fees paid equal the fees accrued.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationFeesInvariantTest is UniswapV3IntegrationFixture, HandlerReach {
    LPVaultFeesHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler =
            new LPVaultFeesHandler(vault, nfpm, pool500, lock, [adapter, coll, lpVaultSwap, attacker], [alice, bob]);
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](5);
        actions[0] = LPVaultFeesHandler.pledge.selector;
        actions[1] = LPVaultFeesHandler.accrue.selector;
        actions[2] = LPVaultFeesHandler.moveSpot.selector;
        actions[3] = LPVaultFeesHandler.seize.selector;
        actions[4] = LPVaultFeesHandler.collect.selector;
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
        Reach memory r =
            _replayLanded(address(handler), actions, LPVaultFeesHandler.Skipped.selector, 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(5, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](5), new string[](5), new int16[][](5));
        (actions[0], names[0]) = (LPVaultFeesHandler.pledge.selector, "pledge");
        kinds[0] = new int16[](2);
        kinds[0][0] = 256;
        kinds[0][1] = 128;
        (actions[1], names[1]) = (LPVaultFeesHandler.accrue.selector, "accrue");
        kinds[1] = new int16[](3);
        kinds[1][0] = 256;
        kinds[1][1] = 128;
        kinds[1][2] = 128;
        (actions[2], names[2]) = (LPVaultFeesHandler.moveSpot.selector, "moveSpot");
        kinds[2] = new int16[](1);
        kinds[2][0] = -24;
        (actions[3], names[3]) = (LPVaultFeesHandler.seize.selector, "seize");
        kinds[3] = new int16[](2);
        kinds[3][0] = 256;
        kinds[3][1] = 256;
        (actions[4], names[4]) = (LPVaultFeesHandler.collect.selector, "collect");
        kinds[4] = new int16[](2);
        kinds[4][0] = 256;
        kinds[4][1] = 256;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    // TEST-091 verifies: INV-033, REQ-VAULT-064, REQ-VAULT-065, REQ-VAULT-120, REQ-AMM-CORE-010, Q-030, Q-061
    // Sources: 5.1 TEST-091 (fee collection pays only the depositor of record), QNT-11, HYP-28
    /// @notice No fee token reached anyone but the position's depositor, no collection naming someone else succeeded,
    /// and every successful collection paid exactly what was owed.
    function invariant_TEST_091_feesOnlyToDepositor() public view {
        assertEq(handler.paidToOthers(), 0, "fees reached someone other than the depositor");
        assertEq(handler.foreignCollections(), 0, "a collection for another address succeeded");
        assertEq(handler.wrongCollections(), 0, "a collection paid other than every owed amount");
    }

    // TEST-091 verifies: INV-033, REQ-VAULT-058, REQ-VAULT-067, SPEC-BACK-008, Q-061
    // Sources: 5.1 TEST-091 (no liquidation reduces a record's owed fees)
    /// @notice No seizure lowered a position's owed fees, and for every position owed + paid = accrued.
    function invariant_TEST_091_seizureNeverReducesOwedFees() public view {
        assertEq(handler.feesCut(), 0, "a seizure took owed fees");
        uint256 n = handler.keyCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes32 key = handler.keys(i);
            (uint256 o0, uint256 o1) = handler.owed(key);
            (uint256 p0, uint256 p1) = handler.paid(key);
            (uint256 a0, uint256 a1) = handler.accrued(key);
            assertEq(o0 + p0, a0, "token0: owed + paid = accrued");
            assertEq(o1 + p1, a1, "token1: owed + paid = accrued");
        }
    }
}
