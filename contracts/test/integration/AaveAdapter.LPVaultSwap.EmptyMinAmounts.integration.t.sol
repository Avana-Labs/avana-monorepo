// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title AaveAdapterLPVaultSwapEmptyMinAmountsIntegrationTest
/// @notice A repay with collateral whose `minAmounts` is empty, on the integration fixture's real AaveAdapter and
/// LPVaultSwap: the Adapter's session binds one zero per market token, the array LPVaultSwap passes to
/// `deleverageRelease` for an empty `minAmounts` (2.6 REQ-ADAPTER-080, 2.11 REQ-SWAP-106), so the release step
/// matches the session and the call settles. Found by the integration review; the LPVaultSwap suites' Adapter stand-in
/// did not compare the minimums.
/// forge-config: default.isolate = false
contract AaveAdapterLPVaultSwapEmptyMinAmountsIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-SWAP-106
    function test_TEST_239_emptyMinAmountsRepayWithCollateral() public {
        (, bytes32 key) = _openAccount(bob, MARKET_ID, 10_000e6, 10_000e6, P_VAULT);
        RepayWithCollateralParams memory p = _rwcParams(MARKET_ID, key, 1500e6, usdcReserveId);
        p.minAmounts = new uint256[](0);
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "an empty minAmounts settles");
    }
}
