// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {AvanaFirstLossReserveHandler} from "./handlers/AvanaFirstLossReserveHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
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
contract AvanaFirstLossReserveInvariantTest is Test, HandlerReach {
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
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
        (actions[0], names[0]) = (AvanaFirstLossReserveHandler.reportDeficit.selector, "reportDeficit");
        kinds[0] = new int16[](2);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        (actions[1], names[1]) = (AvanaFirstLossReserveHandler.cover.selector, "cover");
        kinds[1] = new int16[](2);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        (actions[2], names[2]) = (AvanaFirstLossReserveHandler.warp.selector, "warp");
        kinds[2] = new int16[](1);
        kinds[2][0] = 256;
        (actions[3], names[3]) = (AvanaFirstLossReserveHandler.fund.selector, "fund");
        kinds[3] = new int16[](2);
        kinds[3][0] = 256;
        kinds[3][1] = 256;
        (actions[4], names[4]) = (AvanaFirstLossReserveHandler.setAllowlist.selector, "setAllowlist");
        kinds[4] = new int16[](2);
        kinds[4][0] = 256;
        kinds[4][1] = 1;
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
