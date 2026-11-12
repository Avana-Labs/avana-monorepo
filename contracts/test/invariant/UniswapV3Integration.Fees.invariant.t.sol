// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3IntegrationFixture} from "../utils/fixtures/UniswapV3IntegrationFixture.sol";
import {LPVaultFeesHandler} from "./handlers/LPVaultFeesHandler.sol";

/// @title UniswapV3IntegrationFeesInvariantTest
/// @notice TEST-091 on the Uniswap v3 LPVault (the custody and fee code it shares with the Slipstream LPVault): random
/// sequences of pledges by two depositors, fee accruals, spot moves, seizures of any part of a position's units to
/// LPVaultSwap and fee collections naming the depositor, the other depositor or an attacker. After every call: fee
/// collection paid only the depositor of record, and paid every owed amount; no seizure lowered a position's owed fees;
/// for every position, the fees owed plus the fees paid equal the fees accrued.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationFeesInvariantTest is UniswapV3IntegrationFixture {
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
