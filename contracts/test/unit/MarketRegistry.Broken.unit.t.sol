// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title MarketRegistryBrokenUnitTest
/// @notice A broken MarketRegistry (every call to it reverts) on the real RiskModule: the new-activity checks that read
/// it, the pledge check, the borrow pre-check and the withdraw-with-debt pre-check, fail closed with the registry's
/// error, and pass again once the registry answers.
/// @dev The registry's revert is a mocked revert of every call to its proxy, as a broken implementation would give.
/// The AaveAdapter side (repay and debt-free exits that read no registry state) joins with the AaveAdapter; the
/// ProxyManager side is `test_TEST_229_registryRevertPropagates`.
contract MarketRegistryBrokenUnitTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18;

    function setUp() public {
        _deployRiskWorld();
    }

    /// @dev Kills: a RiskModule read of the registry wrapped in a try/catch that lets the check pass on a revert.
    // TEST-243 verifies: REQ-CONFIG-069
    function test_TEST_243_brokenRegistryFailsNewActivityClosed() public {
        bytes memory broken = bytes("registry broken");
        vm.mockCallRevert(address(registry), bytes(""), broken);

        vm.expectRevert(broken);
        _pledge(TEN_K, _counters(), false);
        vm.expectRevert(broken);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(broken);
        riskModule.preWithdrawCheck(address(proxy));

        vm.clearMockedCalls();
        _pledge(TEN_K, _counters(), false);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }
}
