// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleHandler} from "./handlers/RiskModuleHandler.sol";

/// @title RiskModuleInvariantTest
/// @notice RiskModule half of TEST-095 and TEST-098: random sequences of collateral price states, feed ages, Aave pauses
/// and freezes, drift, issuer actions, keeper counts, offboarding and time steps, with borrow and withdraw-with-debt
/// pre-checks in between. After every call: no pre-check passed while a gate of 2.7 was closed (an independent reading
/// of the gates); no borrow pre-check passed with 0 active keepers.
/// @dev The Adapter-side half (Aave HF after the Spoke call, nonce, receiver) is outside this suite.
contract RiskModuleInvariantTest is RiskModuleFixture {
    RiskModuleHandler internal handler;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        oracle.setLegMaxAge(FEED_AGE);
        handler = new RiskModuleHandler(
            RiskModuleHandler.World({
                rm: riskModule,
                registry: registry,
                spoke: rSpoke,
                oracle: oracle,
                swap: swap,
                usdt: tUsdt,
                proxy: address(proxy),
                marketId: mid,
                vtReserve: VT_RESERVE,
                debtReserve: GHO_RESERVE,
                feedAge: FEED_AGE,
                legTokens: [address(usdc), address(usdt)],
                legFeeds: [feedUsdc, feedUsdt]
            })
        );
        targetContract(address(handler));
    }

    // TEST-095 verifies: INV-023, INV-024, INV-060, INV-072, REQ-ADAPTER-024, REQ-ADAPTER-025, REQ-RISK-065
    // Sources: 5.1 TEST-095 (RiskModule half)
    function invariant_TEST_095_noGateBypassed() public view {
        assertEq(handler.violations(), 0, "a pre-check passed with a gate closed");
        // The converse: with every gate the handler models open, the pre-check passes, so the gates of 2.7 are the
        // only reasons it refuses.
        assertEq(handler.refusedWhileClear(), 0, "a pre-check refused with every gate open");
    }

    // TEST-098 verifies: REQ-RISK-071, REQ-ADAPTER-010
    function invariant_TEST_098_noBorrowWithoutKeeper() public view {
        assertEq(handler.borrowsWithoutKeeper(), 0, "a borrow passed with no active keeper");
    }
}
