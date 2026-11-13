// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @title ParameterStoreNoRestrictionUnitTest
/// @notice The ParameterStore holds no restriction of its own: the only pause state is the MarketRegistry's.
contract ParameterStoreNoRestrictionUnitTest is ParameterStoreFixture {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        _deployStore(false);
    }

    // TEST-168 verifies: REQ-CONFIG-057, Q-226, Q-227
    // Sources: 5.1 TEST-168 (pause location: the ParameterStore holds no restriction storage or selector)
    /// @notice Neither the ParameterStore proxy, its implementation nor any of its five logic contracts answers a
    /// pause, per-function pause, market freeze, pool-broken flag, keeper suspension, route quarantine, incident clock or
    /// tolerance override selector.
    function test_TEST_168_noRestrictionSelectorInTheStoreOrItsLogics() public {
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
        address impl = address(uint160(uint256(vm.load(address(store), IMPLEMENTATION_SLOT))));
        assertTrue(impl.code.length > 0, "implementation read from the proxy");
        address[7] memory targets =
            [address(store), impl, logics.tighten, logics.loosen, logics.listing, logics.adminOracle, logics.adminRisk];
        for (uint256 t = 0; t < targets.length; ++t) {
            for (uint256 i = 0; i < absent.length; ++i) {
                vm.prank(address(timelock));
                (bool ok,) = targets[t].call(abi.encodeWithSignature(absent[i], uint256(1), true));
                assertFalse(ok, absent[i]);
            }
        }
    }
}
