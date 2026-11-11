// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleCrossHubUnitTest
/// @notice `preBorrowCheck` of a debt reserve funded by another Hub than the market's: the cross-Hub switch and the
/// registry's draw-cap sum against the funding Hub's credit line (REQ-RISK-082, SPEC-CAP-010).
contract RiskModuleCrossHubUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
        _enableCrossHubDebt();
        _debt(1.5e18, 1000);
    }

    function _setLinesEnabled(
        bool on
    ) internal {
        vm.prank(address(timelock));
        registry.setCrossHubLinesEnabled(on);
    }

    // TEST-273 verifies: REQ-RISK-082, SPEC-CAP-010
    function test_TEST_273_crossHubBorrowNeedsLinesEnabled() public {
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        _setLinesEnabled(false);
        vm.expectRevert(IMarketRegistryHubs.CrossHubLinesDisabled.selector);
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        // Same-Hub reserves skip the line, and a withdraw-with-debt never reads it, even with DAI debt held.
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        rSpoke.setStatus(address(proxy), DAI_RESERVE, false, true);
        riskModule.preWithdrawCheck(address(proxy));
        _setLinesEnabled(true);
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
    }

    // TEST-273 verifies: REQ-RISK-082, SPEC-CAP-010
    function test_TEST_273_drawCapSumAboveLine() public {
        assertEq(registry.crossHubLinesEnabled(), true);
        (uint256 line, uint256 sum) = registry.creditLine(address(hub2), address(tDai));
        assertEq(line, 1_000_000);
        assertEq(sum, 500_000);
        // The funding Hub raises the Spoke's draw cap to exactly the line: still within it.
        hub2.setSpokeConfig(DAI_ASSET, address(spoke), 0, 1_000_000);
        registry.syncDrawCap(address(spoke), DAI_RESERVE);
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        // One unit above the line: every cross-Hub borrow of DAI reverts; same-Hub GHO is unaffected.
        hub2.setSpokeConfig(DAI_ASSET, address(spoke), 0, 1_000_001);
        registry.syncDrawCap(address(spoke), DAI_RESERVE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CreditLineExceeded.selector,
                address(hub2),
                address(tDai),
                1_000_001,
                1_000_000
            )
        );
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }
}
