// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @notice Governance-page rows of the LegacyRiskModule that the other unit tests do not check: it holds no per-market
/// switch.
contract RiskModuleGovernanceRowsUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-035 verifies: REQ-ACCESS-035, REQ-ACCESS-081, REQ-ACCESS-136, REQ-RISK-015, REQ-ADAPTER-017, REQ-RISK-032, REQ-RISK-033, REQ-RISK-035, REQ-RISK-037
    // Sources: 2.15 REQ-ACCESS-035 (the LegacyRiskModule holds no switch and no parameter)
    function test_TEST_035_noMarketSwitchOnTheRiskModule() public {
        // The market status (Active, Offboarding, wind-down, Closed) is the MarketRegistry's; the LegacyRiskModule can
        // neither set nor clear it (REQ-RISK-033, REQ-RISK-037).
        string[9] memory absent = [
            "freezeMarket(uint256)",
            "pauseMarket(uint256)",
            "setPoolBroken(uint256,bool)",
            "isPoolBroken(uint256)",
            "liftHalting(uint256)",
            "setMarketOffboarding(uint256)",
            "activateMarket(uint256)",
            "stepWindDown(uint256)",
            "closeMarket(uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(riskModule).call(abi.encodeWithSignature(absent[i], mid, true));
            assertFalse(ok, absent[i]);
        }
    }
}
