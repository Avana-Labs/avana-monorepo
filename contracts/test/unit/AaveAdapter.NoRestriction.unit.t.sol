// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @title AaveAdapterNoRestrictionUnitTest
/// @notice The AaveAdapter holds no restriction of its own: it reads the MarketRegistry's pause state for new activity.
contract AaveAdapterNoRestrictionUnitTest is AaveAdapterFixture {
    // TEST-168 verifies: REQ-ADAPTER-044, Q-226, Q-227
    // Sources: 5.1 TEST-168 (pause location: the AaveAdapter holds no restriction storage or selector)
    /// @notice Neither the Adapter proxy, its implementation nor any of its four logic contracts answers a pause,
    /// per-function pause, market freeze, pool-broken flag, keeper suspension, route quarantine, incident clock or
    /// tolerance override selector; the refusal of a borrow follows the MarketRegistry's pause state alone, set and
    /// cleared there with no Adapter call.
    function test_TEST_168_noRestrictionSelectorAndPauseReadFromTheRegistry() public {
        string[15] memory absent = [
            "pause()",
            "unpause()",
            "paused()",
            "pauseFunction(bytes4)",
            "pauseMarket(uint256)",
            "freezeMarket(uint256)",
            "freeze(address)",
            "setPoolBroken(uint256,bool)",
            "isPoolBroken(uint256)",
            "suspendKeeper(address)",
            "quarantineRoute(uint256)",
            "startIncident(uint256)",
            "incidentStartedAt(uint256)",
            "setToleranceOverride(uint256,uint256)",
            "pauseState(address)"
        ];
        address[6] memory targets =
            [adapter, address(implementation), logics.user, logics.exit, logics.collateral, logics.settlement];
        for (uint256 t = 0; t < targets.length; ++t) {
            for (uint256 i = 0; i < absent.length; ++i) {
                vm.prank(timelock);
                (bool ok,) = targets[t].call(abi.encodeWithSignature(absent[i], uint256(MARKET_ID), true));
                assertFalse(ok, absent[i]);
            }
        }
        (, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _pause(PauseState.Paused, PauseReason.General);
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, nonce);
        _pause(PauseState.None, PauseReason.None);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        assertEq(adapterC.borrowNonce(p), nonce + 1, "borrowing follows the registry's state");
    }
}
