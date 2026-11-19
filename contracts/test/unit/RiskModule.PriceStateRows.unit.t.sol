// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/legacy/risk-module/types/RiskModuleTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModulePriceStateRowsUnitTest
/// @notice The LegacyRiskModule's share of the USD-band breach (TEST-043) and of the persistent disagreement (TEST-157): how
/// the reviewed LegacyRiskModule, on the real MarketRegistry, gates borrow, withdraw-with-debt and pledges on the LPOracle's
/// reported state and reasons. The LPOracle is the fixture's settable report (`RiskLPOracleMock`); the oracle's own
/// state machine is the LPOracle suite's subject.
contract RiskModulePriceStateRowsUnitTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18;
    uint32 internal constant USD_BAND = 1 << 3;
    uint32 internal constant ANY_TOKEN_DISAGREE = 1 << 2;

    function setUp() public {
        _deployRiskWorld();
    }
}
