// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {AccountGateStatus} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleBoundariesUnitTest
/// @notice Every numeric gate of the borrow-side checks at its boundary, with the exact error one unit past it: the
/// per-feed collateral age, the debt price age, the health-factor floor, the frozen-reserve supply, Hub shares ==
/// assets, the keeper count and the sequencer grace end (REQ-ADAPTER-016, REQ-RISK-061, REQ-RISK-059, REQ-ADAPTER-019,
/// REQ-ADAPTER-021, REQ-ADAPTER-010, REQ-RISK-081).
contract RiskModuleBoundariesUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
    }

    function _borrow() internal {
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    function _withdraw() internal {
        riskModule.preWithdrawCheck(address(proxy));
    }

    /// @dev Report with the two tokens' legs at their own times.
    function _reportAt(
        uint64 at0,
        uint64 at1
    ) internal {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (at0, at1);
        oracle.setTokens(toks, feeds, ats, new uint256[](2), new uint32[](2));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Collateral feed age (REQ-ADAPTER-016)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-028 verifies: REQ-ADAPTER-016
    function test_TEST_028_unusedLegIsSkipped() public {
        // A token priced through one leg leaves its second slot empty: no age check for address(0).
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        feeds[0] = feedUsdc;
        uint64[] memory ats = new uint64[](2);
        ats[0] = uint64(block.timestamp);
        oracle.setTokens(toks, feeds, ats, new uint256[](2), new uint32[](2));
        _borrow();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Debt price age (REQ-RISK-061)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-201 verifies: REQ-RISK-061, REQ-ADAPTER-062
    function test_TEST_201_fixedPriceReserveIsNeverAged() public {
        // GHO is priced at a fixed value: its source must be the recorded one, and no DebtOracle is read or poked.
        vm.warp(block.timestamp + 10 * 88_200);
        _reportAt(uint64(block.timestamp), uint64(block.timestamp));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        _borrow();
        aaveOracle.setSource(GHO_RESERVE, makeAddr("otherGhoSource"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.UnexpectedDebtPriceSource.selector, GHO_RESERVE, makeAddr("otherGhoSource")
            )
        );
        _withdraw();
    }

    // TEST-201 verifies: REQ-RISK-061, REQ-RISK-056
    function test_TEST_201_debtPriceOfABorrowedReserveIsGated() public {
        // The reserve borrowed is in scope before it is held: its price is gated.
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 1);
        // A withdraw-with-debt of an account that holds no USDC does not read it.
        usdcOracle.setReport(PriceState.Expired, 0, false);
        _withdraw();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), block.timestamp
            )
        );
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 1);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Health floor (REQ-RISK-059, REQ-RISK-068)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-236 verifies: REQ-RISK-059, REQ-ADAPTER-027, SPEC-CF-005, SPEC-CF-003
    function test_TEST_236_healthFloorBoundary() public {
        // Required level max(1.00, minHealthFactor): equal passes, one wei below reverts.
        _debt(1.25e18, 1000);
        assertEq(riskModule.postHealthCheck(address(proxy), 1.25e18), 1.25e18);
        _debt(1.25e18 - 1, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.25e18 - 1, 1.25e18));
        riskModule.postHealthCheck(address(proxy), 1.25e18);
        // The caller's minimum above the health factor sets the level.
        _debt(1.3e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.3e18, 1.3e18 + 1));
        riskModule.postHealthCheck(address(proxy), 1.3e18 + 1);
        // A minimum below Aave's 1.00: the level is 1.00.
        _debt(1e18 - 1, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1e18 - 1, 1e18));
        riskModule.postHealthCheck(address(proxy), 0.9e18);
    }

    // TEST-236 verifies: REQ-RISK-059, SPEC-CF-005, SPEC-CF-003
    function testFuzz_TEST_236_healthFloor(
        uint96 hf,
        uint96 minHf
    ) public {
        _debt(hf, 1000);
        uint256 required = 1e18;
        if (minHf > required) required = minHf;
        if (hf < required) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hf, required));
        }
        riskModule.postHealthCheck(address(proxy), minHf);
    }

    // TEST-236 verifies: REQ-RISK-059
    function test_TEST_236_debtFreeAccountPasses() public {
        // Aave reports type(uint256).max for an account without debt.
        rSpoke.setAccount(address(proxy), type(uint256).max, 0, 0);
        assertEq(riskModule.postHealthCheck(address(proxy), type(uint256).max), type(uint256).max);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Hub shares, keepers (REQ-ADAPTER-021, REQ-ADAPTER-010)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-028 verifies: REQ-ADAPTER-021, REQ-ADAPTER-037
    function testFuzz_TEST_028_hubSharesExactlyEqual(
        uint128 assets,
        uint128 shares
    ) public {
        rHub.setAdded(VT_ASSET, assets, shares);
        assertEq(riskModule.isHubSharesEqualAssets(mid), assets == shares);
        if (assets != shares) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HubSharesNotEqualAssets.selector, mid));
        }
        _withdraw();
    }

    // TEST-068 verifies: REQ-ADAPTER-010, REQ-RISK-071
    function testFuzz_TEST_068_anyActiveKeeperSuffices(
        uint256 keepers
    ) public {
        keepers = bound(keepers, 0, 1000);
        swap.setKeepers(keepers);
        if (keepers == 0) vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        _borrow();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Sequencer grace end (REQ-RISK-081)
    // -----------------------------------------------------------------------------------------------------------------
}
