// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {ParameterStoreSpeedHandler} from "./handlers/ParameterStoreSpeedHandler.sol";

/// @title ParameterStoreSpeedInvariantTest
/// @notice TEST-325 under random sequences: speed-limit tightenings and loosenings by the timelock, the Joint
/// Configuration Safe and a stranger, starting from never-written values. After every call: each stored value is
/// all zero or within the bounds of REQ-PSTORE-035; no write moved a value against its setter's direction; the
/// steward never loosened; the stranger never wrote.
contract ParameterStoreSpeedInvariantTest is ParameterStoreFixture {
    ParameterStoreSpeedHandler internal handler;
    address internal safe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore(false);
        _listMarket();
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, safe);
        handler = new ParameterStoreSpeedHandler(store, address(timelock), safe, M, address(hub), gho);
        targetContract(address(handler));
    }

    // TEST-325 verifies: REQ-PSTORE-035, REQ-RISK-096
    function invariant_TEST_325_valuesZeroOrWithinBounds() public view {
        MarketSpeedLimits memory m = store.marketSpeedLimits(M);
        if (m.window != 0) {
            assertTrue(m.window >= 3600 && m.window <= 604_800, "market window");
            assertLe(m.borrowRateBps, 10_000);
            assertLe(m.pledgeRateBps, 10_000);
            assertLe(m.borrowMinUsd, m.borrowMaxUsd);
            assertLe(m.pledgeMinUsd, m.pledgeMaxUsd);
        } else {
            assertEq(abi.encode(m), abi.encode(MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0)), "never written is all zero");
        }
        SpeedLimit memory d = store.debtSpeedLimit(address(hub), gho);
        if (d.window != 0) {
            assertTrue(d.window >= 3600 && d.window <= 604_800, "debt window");
            assertLe(d.rateBps, 10_000);
            assertLe(d.min, d.max);
        } else {
            assertEq(abi.encode(d), abi.encode(SpeedLimit(0, 0, 0, 0)));
        }
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-PSTORE-002, REQ-CONFIG-049
    function invariant_TEST_325_directionsAndRoles() public view {
        assertEq(handler.wrongDirection(), 0, "a value moved against its setter");
        assertEq(handler.stewardLoosenings(), 0, "the steward loosened");
        assertEq(handler.strangerWrites(), 0, "a stranger wrote");
    }
}
