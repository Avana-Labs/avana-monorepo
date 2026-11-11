// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryCreditLines} from "../../src/policy/market-registry/IMarketRegistryCreditLines.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RegistryCoverageSpokeMock} from "../utils/mocks/MarketRegistryMocks.sol";

/// @title RiskModuleCrossHubUnitTest
/// @notice `preBorrowCheck` of a debt reserve funded by another Hub than the market's: the cross-Hub switch and the
/// registry's draw-cap sum against the funding Hub's credit line and the line's first-loss coverage (REQ-RISK-082,
/// SPEC-CAP-010).
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

    /// @dev DAI's Coverage Spoke, as the registry records it.
    function _daiCoverage() internal view returns (RegistryCoverageSpokeMock) {
        return RegistryCoverageSpokeMock(registry.getDebtReserve(address(spoke), DAI_RESERVE).coverageSpoke);
    }

    /// @dev `⌈line × 10^18 × coverageRatioBps / 10^4⌉` for the 1,000,000 DAI line at 2,000 bps.
    uint256 internal constant DAI_REQUIRED = 2e23;

    function _expectCoverage(
        uint256 funded
    ) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IMarketRegistryCreditLines.CoverageBelowRatio.selector,
                address(hub2),
                address(tDai),
                DAI_REQUIRED,
                funded
            )
        );
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
    }

    // TEST-273 verifies: REQ-RISK-082, REQ-CONFIG-081
    // Sources: 2.8 REQ-CONFIG-081 (required = ceil(line x 10^dec x coverageRatioBps / 10^4))
    function test_TEST_273_coverageGateAtItsBoundary() public {
        (uint256 required, uint256 funded) = registry.creditLineCoverage(address(hub2), address(tDai));
        assertEq(required, DAI_REQUIRED);
        assertEq(funded, 4e24);
        // Exactly covered: the borrow passes.
        _daiCoverage().setFunded(DAI_REQUIRED, false);
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        // One base unit short: every cross-Hub borrow of DAI reverts with the registry's error and both amounts.
        _daiCoverage().setFunded(DAI_REQUIRED - 1, false);
        _expectCoverage(DAI_REQUIRED - 1);
        _daiCoverage().setFunded(0, false);
        _expectCoverage(0);
        // A same-Hub reserve never reads the coverage of another Hub's line.
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        _daiCoverage().setFunded(DAI_REQUIRED, false);
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
    }

    // TEST-273 verifies: REQ-RISK-082, REQ-CONFIG-081
    function testFuzz_TEST_273_coverageGate(
        uint256 funded
    ) public {
        funded = bound(funded, 0, 1e30);
        _daiCoverage().setFunded(funded, false);
        if (funded < DAI_REQUIRED) _expectCoverage(funded);
        else riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
    }

    // TEST-273 verifies: REQ-RISK-082, REQ-ADAPTER-024
    function test_TEST_273_crossHubErrorOrder() public {
        _daiCoverage().setFunded(0, false);
        hub2.setSpokeConfig(DAI_ASSET, address(spoke), 0, 1_000_001);
        registry.syncDrawCap(address(spoke), DAI_RESERVE);
        // The switch is checked first, then the line sum, then the coverage.
        _setLinesEnabled(false);
        vm.expectRevert(IMarketRegistryHubs.CrossHubLinesDisabled.selector);
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        _setLinesEnabled(true);
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
        hub2.setSpokeConfig(DAI_ASSET, address(spoke), 0, 1_000_000);
        registry.syncDrawCap(address(spoke), DAI_RESERVE);
        _expectCoverage(0);
    }

    // TEST-273 verifies: REQ-RISK-082, REQ-ADAPTER-025, REQ-ADAPTER-038
    function test_TEST_273_coverageIsABorrowGateOnly() public {
        rSpoke.setStatus(address(proxy), DAI_RESERVE, false, true);
        _daiCoverage().setFunded(0, false);
        // Withdraw-with-debt never reads the credit line or its coverage, even with DAI debt held.
        riskModule.preWithdrawCheck(address(proxy));
        // The status does not know which reserve will be borrowed, so it reads neither: the borrow flag stays true
        // while a DAI borrow itself reverts.
        AccountGateStatus memory st = riskModule.getAccountGateStatus(address(proxy));
        assertTrue(st.borrowAllowed);
        assertTrue(st.withdrawWithDebtAllowed);
        _expectCoverage(0);
        // Borrowing more of a held cross-Hub reserve is a borrow of it: the gate applies.
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-273 verifies: REQ-RISK-082, REQ-RISK-056
    function test_TEST_273_coverageReadRevertPropagates() public {
        vm.mockCallRevert(address(_daiCoverage()), abi.encodeWithSignature("fundedBalance()"), "coverage");
        vm.expectRevert("coverage");
        riskModule.preBorrowCheck(address(proxy), DAI_RESERVE, 1);
        // Same-Hub borrows and withdraw-with-debt do not depend on it.
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }
}
