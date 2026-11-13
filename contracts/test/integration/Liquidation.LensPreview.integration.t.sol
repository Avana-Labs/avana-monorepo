// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LiquidationLensPreviewIntegrationTest
/// @notice `TEST-205` on the deployed stack: the Lens's `previewLiquidation` parameters, executed unchanged in the
/// same block through the real LPVaultSwap (directly and through the public flash liquidation helper with
/// `flashAmount = debtToCover`), settle with the previewed debt repaid, units seized and recovery floor, for a
/// GHO-debt and a USDC-debt account opened through the real AaveAdapter; each preview gate matches what `liquidate`
/// enforces.
/// forge-config: default.isolate = false
contract LiquidationLensPreviewIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    /// @dev An account of 10,000 vault tokens pledged at $2.50 with 18,000 of debt in `reserveId`, at $2.10 after.
    function _account(
        address wallet,
        uint256 reserveId
    ) internal returns (address proxy) {
        _setPrice(MARKET_ID, 250_000_000);
        (, proxy) = _pledgeVia(wallet, MARKET_ID, 10_000e6);
        _borrowVia(wallet, MARKET_ID, reserveId, reserveId == usdcReserveId ? 18_000e6 : 18_000e18);
        _setPrice(MARKET_ID, P_VAULT);
    }

    function _deadlineIn() internal view returns (uint256) {
        return block.timestamp + 120;
    }

    /// @dev The preview's ready-to-send shape (REQ-LENS-028).
    function _checkShape(
        LiquidationPreview memory p,
        address proxy,
        uint256 reserveId
    ) internal view {
        assertTrue(p.aaveLiquidatable && p.pricesUsable && p.sharesEqualAssets, "liquidatable with usable gates");
        assertEq(p.params.proxy, proxy, "proxy");
        assertEq(p.params.marketId, MARKET_ID, "market");
        assertEq(p.params.debtReserveId, reserveId, "debt reserve");
        assertEq(p.params.minPayout, 0, "minPayout 0");
        assertEq(p.params.maxShortfall, 0, "maxShortfall 0");
        assertEq(p.params.minAmounts.length, 0, "empty minAmounts");
        assertEq(p.params.deadline, _deadlineIn(), "the input deadline");
        assertEq(uint8(p.params.routeMode), uint8(RouteMode.PrimaryThenBackup), "primary routes usable");
        assertLe(p.expectedNetPayout, p.expectedPayout, "net payout reported apart from the payout");
    }

    /// @dev The executed amounts equal the preview's (REQ-LENS-017, REQ-LENS-029).
    function _checkExecuted(
        LiquidationPreview memory p,
        LiquidationResult memory r
    ) internal pure {
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        assertEq(r.minOut, p.recoveryFloor, "recovery floor as previewed");
        assertEq(r.avanaFee, p.expectedAvanaFee, "Avana fee as previewed");
    }

    // TEST-205 verifies: REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, REQ-SWAP-011, REQ-SWAP-017, SPEC-LIQ-004, SPEC-LIQ-005, Q-232, Q-404
    function test_TEST_205_paramsExecuteUnchangedForGhoAndUsdc() public {
        address ghoProxy = _account(alice, debtReserveId);
        address usdcProxy = _account(bob, usdcReserveId);
        uint256[2] memory reserves = [debtReserveId, usdcReserveId];
        address[2] memory proxies = [ghoProxy, usdcProxy];
        // V per seized unit at $2.10 in the debt asset's base units: 2.1e12 GHO wei, 2.1 USDC units.
        uint256[2] memory vNum = [uint256(21e11), 21];
        uint256[2] memory vDen = [uint256(1), 10];
        for (uint256 i = 0; i < 2; ++i) {
            LiquidationPreview memory p = lens.previewLiquidation(proxies[i], reserves[i], _deadlineIn());
            _checkShape(p, proxies[i], reserves[i]);
            LiquidationResult memory r = _liquidateAs(keeper, p.params);
            _checkExecuted(p, r);
            // expectedPayout is keeperOut at R = V (REQ-LENS-029): the executed payout differs by exactly V - R.
            uint256 v = r.unitsSeized * vNum[i] / vDen[i];
            assertEq(r.borrowerSurplus + r.shortfall, 0, "no surplus and no top-up at these prices");
            assertEq(p.expectedPayout - r.keeperOut, v - r.recovered, "expectedPayout = Kf + V - D - A");
            assertEq(p.expectedNetPayout, p.expectedPayout - p.params.debtToCover, "net payout beyond the funding");
        }
    }

    /// @notice A caller may raise `minPayout` up to `expectedPayout`; LPVaultSwap then holds the call to it, so a
    /// realized payout below it (routes and unwind below the oracle value) reverts `PayoutTooLow` and changes nothing.
    // TEST-205 verifies: REQ-LENS-029, REQ-SWAP-026, Q-345
    function test_TEST_205_raisedMinPayoutIsEnforced() public {
        address proxy = _account(bob, usdcReserveId);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        LiquidationParams memory raised = p.params;
        raised.minPayout = p.expectedPayout;
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        _fundCaller(keeper, raised);
        vm.expectPartialRevert(ILPVaultSwapErrors.PayoutTooLow.selector);
        vm.prank(keeper);
        lvs.liquidate(raised);
        assertEq(_debtOf(proxy, usdcReserveId), debtBefore, "nothing repaid");
        raised.minPayout = p.expectedPayout - p.expectedAvanaFee;
        LiquidationResult memory r = _liquidateAs(keeper, raised);
        _checkExecuted(p, r);
        assertGe(r.keeperOut, raised.minPayout, "the raised minimum held");
    }

    // TEST-205 verifies: REQ-LENS-028, REQ-HELPER-002, REQ-SWAP-014, REQ-SWAP-105, Q-232, Q-345
    function test_TEST_205_sameParamsThroughFlashHelper() public {
        address ghoProxy = _account(alice, debtReserveId);
        address usdcProxy = _account(bob, usdcReserveId);
        uint256[2] memory reserves = [debtReserveId, usdcReserveId];
        address[2] memory proxies = [ghoProxy, usdcProxy];
        address caller = makeAddr("helperCaller");
        for (uint256 i = 0; i < 2; ++i) {
            LiquidationPreview memory p = lens.previewLiquidation(proxies[i], reserves[i], _deadlineIn());
            _checkShape(p, proxies[i], reserves[i]);
            uint256 f = p.params.debtToCover;
            FlashLiquidationRequest memory q = FlashLiquidationRequest({
                params: p.params, flashAmount: f, maxPremium: (f * 5 + 9999) / 10_000, maxTopUp: 0, minPayout: 0
            });
            CollPoolToken asset = _asset(reserves[i]);
            uint256 before = asset.balanceOf(caller);
            uint256 debtBefore = _debtOf(proxies[i], reserves[i]);
            vm.prank(caller);
            uint256 payout = helper.flashLiquidate(q);
            assertEq(debtBefore - _debtOf(proxies[i], reserves[i]), p.expectedDebtRepaid, "D as previewed");
            assertEq(asset.balanceOf(caller) - before, payout, "net payout to the caller, who funded nothing");
            assertGt(payout, 0, "keeperOut covers the loan and its premium");
            assertEq(asset.balanceOf(address(helper)), 0, "the helper keeps nothing");
        }
        assertEq(v3Pool.flashLoanCalls(), 2, "one loan per helper call");
    }

    /// @notice With the primary route of a released token unusable the preview asks for `BackupOnly`, which settles.
    // TEST-205 verifies: REQ-LENS-028, REQ-SWAP-022
    function test_TEST_205_backupOnlyWhenPrimaryUnusable() public {
        address proxy = _account(bob, usdcReserveId);
        reg.setRouteUsable(MARKET_ID, address(usdt), address(usdc), 0, false);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertEq(uint8(p.params.routeMode), uint8(RouteMode.BackupOnly), "backup routes only");
        uint256 primarySwaps = usdtUsdcPool.swaps();
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        _checkExecuted(p, r);
        assertEq(usdtUsdcPool.swaps(), primarySwaps, "the primary was never called");
    }

    /// @notice Each gate the preview reports refuses the call it describes, and passes once cleared.
    // TEST-205 verifies: REQ-LENS-016, REQ-SWAP-008, REQ-SWAP-091, REQ-SWAP-096, REQ-SWAP-007
    function test_TEST_205_previewGatesMatchLiquidate() public {
        address proxy = _account(bob, usdcReserveId);
        // Collateral price liquidation-paused.
        lpo.setFlags(true, false, false);
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertFalse(p.pricesUsable, "preview: collateral price unusable");
        _expectRefused(p.params, abi.encodeWithSelector(ILPVaultSwapErrors.StalePrice.selector));
        lpo.setFlags(false, false, false);
        // The USDC DebtOracle's leg older than liquidationPriceMaxAge.
        usdcOracle.setLeg(uint64(block.timestamp - FEED_AGE - 1));
        p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertFalse(p.debtPriceFresh, "preview: debt price stale");
        _expectRefused(p.params, abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
        usdcOracle.setLeg(uint64(block.timestamp));
        // The repaid reserve paused on Aave.
        vm.prank(aaveDao);
        (bool ok,) = aave.spokeConfigurator
            .call(abi.encodeWithSignature("updatePaused(address,uint256,bool)", aave.cdpSpoke, usdcReserveId, true));
        assertTrue(ok, "pause the reserve");
        p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertTrue(p.debtReservePaused, "preview: debt reserve paused");
        _expectRefused(p.params, "");
        vm.prank(aaveDao);
        (ok,) = aave.spokeConfigurator
            .call(abi.encodeWithSignature("updatePaused(address,uint256,bool)", aave.cdpSpoke, usdcReserveId, false));
        assertTrue(ok, "unpause the reserve");
        // Every gate clear: the same preview executes.
        p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertTrue(p.pricesUsable && p.debtPriceFresh && !p.debtReservePaused, "gates clear");
        _checkExecuted(p, _liquidateAs(keeper, p.params));
    }

    function _expectRefused(
        LiquidationParams memory params,
        bytes memory err
    ) internal {
        _fundCaller(keeper, params);
        if (err.length == 0) vm.expectRevert();
        else vm.expectRevert(err);
        vm.prank(keeper);
        lvs.liquidate(params);
        vm.prank(keeper);
        _asset(params.debtReserveId).approve(lpVaultSwap, 0);
    }
}
