// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @notice Governance-page rows of the RiskModule that the other unit tests do not check: it holds no per-market switch,
/// and `pokeBreakers` is permissionless and only records breaches.
contract RiskModuleGovernanceRowsUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-035 verifies: REQ-ACCESS-035, REQ-ACCESS-081, REQ-ACCESS-136, REQ-RISK-015, REQ-ADAPTER-017, REQ-RISK-032, REQ-RISK-033, REQ-RISK-035, REQ-RISK-037
    // Sources: 2.15 REQ-ACCESS-035 (the RiskModule holds no switch and no parameter)
    function test_TEST_035_noMarketSwitchOnTheRiskModule() public {
        // The market status (Active, Offboarding, wind-down, Closed) and the Hub's pause state are the MarketRegistry's;
        // the RiskModule can neither set nor clear them (REQ-RISK-033, REQ-RISK-037).
        string[12] memory absent = [
            "freezeMarket(uint256)",
            "unfreezeMarket(uint256)",
            "pauseMarket(uint256)",
            "setPoolBroken(uint256,bool)",
            "isPoolBroken(uint256)",
            "liftHalting(uint256)",
            "setMarketOffboarding(uint256)",
            "activateMarket(uint256)",
            "stepWindDown(uint256)",
            "closeMarket(uint256)",
            "unfreeze(address)",
            "unpause(address)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(riskModule).call(abi.encodeWithSignature(absent[i], mid, true));
            assertFalse(ok, absent[i]);
        }
    }

    // TEST-228 verifies: REQ-ACCESS-035, REQ-ACCESS-158, REQ-ACCESS-012
    // Sources: 2.15 REQ-ACCESS-035, REQ-ACCESS-158 (permissionless `pokeBreakers` records breaches and latches only)
    // Kills: an access check added to `RiskModule.pokeBreakers` (RiskModule.sol, `function pokeBreakers`).
    function testFuzz_TEST_228_pokeBreakersIsPermissionless(
        address caller
    ) public {
        rVault.setDepth(0, false);
        vm.warp(block.timestamp + 1);
        vm.prank(caller);
        uint32 reasons = riskModule.pokeBreakers(mid);
        assertEq(reasons & BreakerReasons.POOL_DEPTH, BreakerReasons.POOL_DEPTH);
        (uint32 latched, uint64 lastBreach) = registry.marketBreaker(mid);
        assertEq(lastBreach, block.timestamp, "breach time recorded");
        assertEq(latched & BreakerReasons.TEMPORARY, 0, "a temporary gate is never latched");
    }
}
