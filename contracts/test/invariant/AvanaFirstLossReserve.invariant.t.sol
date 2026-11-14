// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {AvanaFirstLossReserveHandler} from "./handlers/AvanaFirstLossReserveHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title AvanaFirstLossReserveInvariantTest
/// @notice Coverage side of TEST-094 on the real local Aave V4 Hub: under random sequences of recorded deficits on
/// two assets and two drawing Spokes, interest accrual, funding, allowlist changes and `coverDeficit` calls with any
/// instance, Spoke and `maxAmount`, coverage never exceeds the recorded deficit in that asset, the instance's funded
/// balance or `maxAmount`; it reaches only Spokes on the instance's allowlist; it never reduces a deficit of another
/// asset or another Spoke; and every Hub deficit equals what was recorded less what that asset's own First-Loss Reserve
/// eliminated.
/// @dev The other clause of TEST-094, that a deficit is recorded only when the account has no collateral left in any
/// market, is a property of the liquidation (AaveAdapter, LPVaultSwap and the Aave Spoke); it belongs to the
/// liquidation invariant suite, where the deficit is reported by a real liquidation. Here a pranked drawing Spoke
/// reports it. One Hub is deployed, so "another Hub" is covered by the per-asset instances being bound to their own
/// `(Hub, assetId)` (TEST-199).
contract AvanaFirstLossReserveInvariantTest is Test {
    AvanaFirstLossReserveHandler internal handler;
    IAaveV4Hub internal hub;

    function setUp() public {
        handler = new AvanaFirstLossReserveHandler();
        handler.init();
        hub = IAaveV4Hub(handler.instance(0).HUB());
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](8);
        actions[0] = AvanaFirstLossReserveHandler.reportDeficit.selector;
        actions[1] = AvanaFirstLossReserveHandler.reportDeficit.selector;
        actions[2] = AvanaFirstLossReserveHandler.cover.selector;
        actions[3] = AvanaFirstLossReserveHandler.cover.selector;
        actions[4] = AvanaFirstLossReserveHandler.cover.selector;
        actions[5] = AvanaFirstLossReserveHandler.warp.selector;
        actions[6] = AvanaFirstLossReserveHandler.fund.selector;
        actions[7] = AvanaFirstLossReserveHandler.setAllowlist.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-094 verifies: REQ-FLR-019, REQ-FLR-018, REQ-FLR-031, SPEC-FLR-001, INV-042, Q-101, Q-142
    // Sources: 5.1 TEST-094 (coverage part)
    /// @notice Each coverage is `min(maxAmount, ceil(deficitRay / RAY), fundedBalance())` read in the same call, the
    /// recorded deficit falls by exactly `dRay`, and `totalCovered` rises by the amount.
    function invariant_TEST_094_coverageBounded() public view {
        assertEq(handler.amountOverBound(), 0, "coverage above the deficit, the funded balance or maxAmount");
        assertEq(handler.amountMismatch(), 0, "coverage or deficit fall differs from SPEC-FLR-001");
        for (uint256 a = 0; a < 2; ++a) {
            assertEq(handler.instance(a).totalCovered(), handler.coveredSum(a), "totalCovered");
        }
    }

    // TEST-094 verifies: REQ-FLR-016, REQ-FLR-029, REQ-FLR-030, INV-042, Q-142, Q-190
    /// @notice A coverage succeeds only for a Spoke on the instance's allowlist with a recorded deficit; a refused one
    /// changes no deficit and no reserve.
    function invariant_TEST_094_coverageOnlyOnAllowlistedSpokes() public view {
        assertEq(handler.coveredWhenRefused(), 0, "covered a Spoke off the allowlist or with no deficit");
        assertEq(handler.refusedChangedState(), 0, "a refused coverage changed state");
    }

    // TEST-094 verifies: REQ-FLR-040, REQ-FLR-042, REQ-FLR-027, INV-071, Q-236
    /// @notice Coverage never reduces a deficit of another asset or another Spoke, nor touches the other reserve, and
    /// every Hub deficit equals what was recorded on it less what its own asset's First-Loss Reserve eliminated.
    function invariant_TEST_094_noCrossAssetReduction() public view {
        assertEq(handler.crossEffect(), 0, "coverage moved another asset's or Spoke's deficit or reserve");
        for (uint256 a = 0; a < 2; ++a) {
            for (uint256 s = 0; s < 2; ++s) {
                assertEq(
                    hub.getSpokeDeficitRay(handler.assetId(a), handler.spokeAt(s)),
                    handler.reportedRay(a, s) - handler.eliminatedRay(a, s),
                    "deficit = recorded - eliminated by its own asset's First-Loss Reserve"
                );
            }
        }
    }

    /// @notice Every run calls `coverDeficit`, so the bounds above are exercised.
    function afterInvariant() external view {
        assertGt(handler.coverCalls(), 0, "coverDeficit was called");
    }
}
