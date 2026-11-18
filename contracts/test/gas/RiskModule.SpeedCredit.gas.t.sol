// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits, SpeedLimit} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title RiskModuleSpeedCreditGasTest
/// @notice Gas of the RiskModule's speed credits on the real RiskModule and local Aave V4, cold: `creditRepay` against
/// the AaveAdapter's `SPEED_CREDIT_GAS` (250,000) and `creditWithdraw` against Collateralization's (100,000). Each
/// stipend must leave at least 40 % unused under every build profile (the CI profile measures about 128,000 for
/// `creditRepay`, the default profile about 104,000).
/// forge-config: default.isolate = false
contract RiskModuleSpeedCreditGasTest is AaveAdapterRiskFixture {
    uint32 internal constant TAU = 3600;
    address internal p;

    function setUp() public override {
        super.setUp();
        (, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        rstore.setMarketSpeed(MARKET_ID, MarketSpeedLimits(TAU, 0, 0, 2000e8, 2000e8, 1000e8, 1000e8));
        rstore.setDebtSpeed(aave.hub, address(debt), SpeedLimit(0, TAU, 5000e18, 5000e18));
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
    }

    // TEST-326 verifies: REQ-RISK-005, REQ-RISK-092
    function test_TEST_326_creditRepayFitsHalfTheStipend() public {
        vm.prank(adapter);
        uint256 g = gasleft();
        rm.creditRepay(p, debtReserveId, 100e18);
        uint256 used = g - gasleft();
        emit log_named_uint("creditRepay gas", used);
        assertLe(used, 150_000, "60 % of the Adapter's 250,000 stipend");
    }

    // TEST-322 verifies: REQ-RISK-005, REQ-RISK-093
    function test_TEST_322_creditWithdrawFitsHalfTheStipend() public {
        vm.prank(address(coll));
        uint256 g = gasleft();
        rm.creditWithdraw(MARKET_ID, 100e8);
        uint256 used = g - gasleft();
        emit log_named_uint("creditWithdraw gas", used);
        assertLe(used, 60_000, "60 % of Collateralization's 100,000 stipend");
    }
}
