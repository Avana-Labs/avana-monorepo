// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";

/// @notice Governance-page rows of the MarketRegistry that the other unit tests do not check: the per-market switch,
/// pool flag, halting lift and chain-wide lifts that do not exist, and the per-Hub lift after a chain-wide stop.
contract MarketRegistryGovernanceRowsUnitTest is MarketRegistryFixture {
    address internal correlatedHub = makeAddr("correlatedLpHub");

    function setUp() public {
        _setUpWorld();
        vm.prank(address(timelock));
        registry.recordHub(correlatedHub, RiskTier.Correlated);
    }

    /// @dev A call to `signature` on the registry finds no function: it reverts with empty return data.
    function _assertAbsent(
        string memory signature
    ) internal {
        (bool ok, bytes memory ret) =
            address(registry).call(abi.encodeWithSignature(signature, uint256(1), address(0), uint8(0)));
        assertFalse(ok, signature);
        assertEq(ret.length, 0, signature);
    }

    // TEST-035 verifies: REQ-ACCESS-035, REQ-ACCESS-081, REQ-ACCESS-136, REQ-ACCESS-087
    // Sources: 2.15 REQ-ACCESS-035, REQ-ACCESS-081, REQ-ACCESS-136, REQ-ACCESS-087
    // No per-market freeze or unfreeze, no pool-broken flag and no halting lift exist on the registry; per-market
    // containment is the market breaker, the Aave reserve freeze and the Offboarding status.
    function test_TEST_035_noMarketSwitchPoolFlagOrHaltingLift() public {
        string[9] memory absent = [
            "freezeMarket(uint256)",
            "unfreezeMarket(uint256)",
            "setPoolBroken(uint256,bool)",
            "poolBroken(uint256)",
            "isPoolBroken(uint256)",
            "liftHalting()",
            "liftHalting(uint256)",
            "liftHalting(address)",
            "isHalting(uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            _assertAbsent(absent[i]);
        }
    }

    // TEST-065 verifies: REQ-ACCESS-172, REQ-ACCESS-087, SPEC-GOV-004
    // Sources: 2.15 REQ-ACCESS-172 (no unfreezeAll or unpauseAll: each Hub is lifted on its own)
    // Kills: an `unfreeze` or `unpause` body (MarketRegistrySafetyLogic) that moves every Hub instead of `hub` alone.
    function test_TEST_065_chainWideStopsAreLiftedHubByHub() public {
        _assertAbsent("unfreezeAll()");
        _assertAbsent("unpauseAll()");
        address h = address(hub);
        vm.startPrank(emergencyGuardian);
        registry.freezeAll();
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.Frozen));
        assertEq(uint8(registry.pauseState(correlatedHub)), uint8(PauseState.Frozen));
        registry.unfreeze(h);
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.None));
        assertEq(uint8(registry.pauseState(correlatedHub)), uint8(PauseState.Frozen), "unfreeze lifted another Hub");
        registry.pauseAll(PauseReason.MintPathSuspect);
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.Paused));
        assertEq(uint8(registry.pauseState(correlatedHub)), uint8(PauseState.Paused));
        registry.unpause(correlatedHub);
        vm.stopPrank();
        assertEq(uint8(registry.pauseState(correlatedHub)), uint8(PauseState.None));
        assertEq(uint8(registry.pauseReason(correlatedHub)), uint8(PauseReason.None));
        assertEq(uint8(registry.pauseState(h)), uint8(PauseState.Paused), "unpause lifted another Hub");
        assertEq(uint8(registry.pauseReason(h)), uint8(PauseReason.MintPathSuspect));
    }
}
