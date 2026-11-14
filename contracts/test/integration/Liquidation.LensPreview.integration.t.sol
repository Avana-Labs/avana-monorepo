// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {IMarketRegistryRoutes} from "../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";

/// @title LiquidationLensPreviewIntegrationTest
/// @notice `TEST-205` on the real stack (`RealStackFlows`): the Lens's `previewLiquidation` parameters, executed
/// unchanged in the same block through the real LPVaultSwap (directly and through the real FlashLiquidator with
/// `flashAmount = debtToCover`, borrowing from the Aave V3 Pool stand-in), settle with the previewed debt repaid, units
/// seized, recovery floor and Avana fee, for a GHO-debt and a USDC-debt account opened through the real AaveAdapter;
/// each preview gate matches what `liquidate` enforces. The gates are real: a primary route disabled through the real
/// timelock and MarketRegistry, feeds left unpublished past their `liquidationPriceMaxAge`, and the Aave DAO pausing the
/// repaid reserve.
/// @dev Each account: 10,000 vault tokens ($20,000 at $2.00, CF 30 %) against 5,880 of debt, HF 1.020; USDT then falls
/// to $0.93 (`_depegUsdt`), the vault token to $1.9287 and HF to 0.984. The preview values the seizure at the oracle
/// (`R = V`); the real unwind and route pools recover slightly less, so the executed payout is below `expectedPayout`
/// by exactly `V - R`. The USDC DebtOracle and the market's LPOracle read the same USDC feeds, so a stale USDC feed
/// closes both gates and `liquidate` refuses at its collateral rule (`StalePrice`), which runs first; the debt rule
/// alone (`DebtPriceStale`) is checked on the stand-in fixture in `Liquidation.LensPreview.DebtStale`.
/// forge-config: default.isolate = false
contract LiquidationLensPreviewIntegrationTest is RealStackFlows {
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
    }

    /// @dev An account of 10,000 vault tokens with 5,880 of debt in `reserveId` (call `_depegUsdt` after).
    function _account(
        address wallet,
        uint256 reserveId
    ) internal returns (address proxy) {
        (, proxy) = _pledgeAs(wallet, mA, UNITS);
        _borrowAs(wallet, mA, reserveId, reserveId == usdcReserveId ? 5880e6 : 5880e18);
    }

    function _deadlineIn() internal view returns (uint256) {
        return block.timestamp + 120;
    }

    /// @dev The oracle value of `c` vault-token units in the debt asset's base units (USDC: 6 decimals, GHO: 18).
    function _value(
        uint256 c,
        uint256 reserveId
    ) internal view returns (uint256) {
        uint256 price8 = uint256(mkt[mA].oracle.latestAnswer());
        uint256 scale = reserveId == usdcReserveId ? 1 : 1e12;
        return c * price8 * scale / 1e8;
    }

    /// @dev The preview's ready-to-send shape (REQ-LENS-028).
    function _checkShape(
        LiquidationPreview memory p,
        address proxy,
        uint256 reserveId
    ) internal view {
        assertTrue(p.aaveLiquidatable && p.pricesUsable && p.sharesEqualAssets, "liquidatable with usable gates");
        assertEq(p.params.proxy, proxy, "proxy");
        assertEq(p.params.marketId, mA, "market");
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
        address ghoProxy = _account(alice, ghoReserveId);
        address usdcProxy = _account(bob, usdcReserveId);
        _depegUsdt(93_000_000);
        uint256[2] memory reserves = [ghoReserveId, usdcReserveId];
        address[2] memory proxies = [ghoProxy, usdcProxy];
        for (uint256 i = 0; i < 2; ++i) {
            LiquidationPreview memory p = lens.previewLiquidation(proxies[i], reserves[i], _deadlineIn());
            _checkShape(p, proxies[i], reserves[i]);
            LiquidationResult memory r = _liquidateAs(keeper, p.params);
            _checkExecuted(p, r);
            // expectedPayout is keeperOut at R = V (REQ-LENS-029): the executed payout differs by exactly V - R.
            uint256 v = _value(r.unitsSeized, reserves[i]);
            assertEq(r.borrowerSurplus + r.shortfall, 0, "no surplus and no top-up at these prices");
            assertLt(r.recovered, v, "the real unwind and routes recover below the oracle value");
            assertEq(p.expectedPayout - r.keeperOut, v - r.recovered, "expectedPayout = Kf + V - D - A");
            assertEq(p.expectedNetPayout, p.expectedPayout - p.params.debtToCover, "net payout beyond the funding");
        }
    }

    /// @notice A caller may raise `minPayout` up to `expectedPayout`; LPVaultSwap then holds the call to it, so a
    /// realized payout below it (the real unwind and route pools recover below the oracle value) reverts
    /// `PayoutTooLow` and changes nothing.
    // TEST-205 verifies: REQ-LENS-029, REQ-SWAP-026, Q-345
    function test_TEST_205_raisedMinPayoutIsEnforced() public {
        address proxy = _account(bob, usdcReserveId);
        _depegUsdt(93_000_000);
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
        address ghoProxy = _account(alice, ghoReserveId);
        address usdcProxy = _account(bob, usdcReserveId);
        _depegUsdt(93_000_000);
        uint256[2] memory reserves = [ghoReserveId, usdcReserveId];
        address[2] memory proxies = [ghoProxy, usdcProxy];
        address caller = makeAddr("helperCaller");
        for (uint256 i = 0; i < 2; ++i) {
            LiquidationPreview memory p = lens.previewLiquidation(proxies[i], reserves[i], _deadlineIn());
            _checkShape(p, proxies[i], reserves[i]);
            uint256 f = p.params.debtToCover;
            FlashLiquidationRequest memory q = FlashLiquidationRequest({
                params: p.params, flashAmount: f, maxPremium: (f * 5 + 9999) / 10_000, maxTopUp: 0, minPayout: 0
            });
            ClTestToken asset = _assetOf(reserves[i]);
            uint256 before = asset.balanceOf(caller);
            uint256 debtBefore = _debtOf(proxies[i], reserves[i]);
            vm.prank(caller);
            uint256 payout = IFlashLiquidator(flashLiquidator).flashLiquidate(q);
            assertApproxEqAbs(
                debtBefore - _debtOf(proxies[i], reserves[i]), p.expectedDebtRepaid, 1, "D as previewed (Aave rounds)"
            );
            assertEq(asset.balanceOf(caller) - before, payout, "net payout to the caller, who funded nothing");
            assertGt(payout, 0, "keeperOut covers the loan and its premium");
            assertEq(asset.balanceOf(flashLiquidator), 0, "the helper keeps nothing");
        }
        assertEq(v3Pool.flashLoanCalls(), 2, "one loan per helper call");
    }

    /// @notice With the primary route of a released token disabled through the real timelock and MarketRegistry, the
    /// preview asks for `BackupOnly`, which settles without touching the primary's pool.
    // TEST-205 verifies: REQ-LENS-028, REQ-SWAP-022
    function test_TEST_205_backupOnlyWhenPrimaryUnusable() public {
        address proxy = _account(bob, usdcReserveId);
        _depegUsdt(93_000_000);
        _govern(
            address(registry), abi.encodeCall(IMarketRegistryRoutes.disableRoute, (mA, address(usdt), address(usdc), 0))
        );
        (, bool usable) = registry.getRoute(mA, address(usdt), address(usdc), 0);
        assertFalse(usable, "the primary USDT -> USDC route is disabled");
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertEq(uint8(p.params.routeMode), uint8(RouteMode.BackupOnly), "backup routes only");
        IClPool primaryPool = routePoolOf[address(usdt)][address(usdc)][0];
        IClPool backupPool = routePoolOf[address(usdt)][address(usdc)][1];
        uint256 primaryUsdt = usdt.balanceOf(address(primaryPool));
        uint256 backupUsdt = usdt.balanceOf(address(backupPool));
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        _checkExecuted(p, r);
        assertEq(usdt.balanceOf(address(primaryPool)), primaryUsdt, "the primary was never called");
        assertGt(usdt.balanceOf(address(backupPool)), backupUsdt, "the backup ran");
    }

    /// @notice Each gate the preview reports refuses the call it describes, and passes once cleared.
    // TEST-205 verifies: REQ-LENS-016, REQ-SWAP-008, REQ-SWAP-091, REQ-SWAP-096, REQ-SWAP-007
    function test_TEST_205_previewGatesMatchLiquidate() public {
        address proxy = _account(bob, usdcReserveId);
        _depegUsdt(93_000_000);
        // Collateral price liquidation-paused: every USDT feed left past its liquidationPriceMaxAge (the LPOracle
        // fails and serves Cached), USDC and so the debt price kept fresh (a keeper pokes the DebtOracle).
        _letFeedsAge();
        _republish(address(usdc));
        usdcOracle.poke();
        LiquidationPreview memory p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertFalse(p.pricesUsable, "preview: collateral price unusable");
        assertTrue(p.debtPriceFresh, "preview: the debt price is fresh");
        _expectRefused(p.params, abi.encodeWithSelector(ILPVaultSwapErrors.StalePrice.selector));
        _refreshAndPoke();
        // Every USDC feed left past its liquidationPriceMaxAge: the DebtOracle is stale, and so is the USDC leg of the
        // collateral price; the collateral rule runs first.
        _letFeedsAge();
        _republish(address(usdt));
        p = lens.previewLiquidation(proxy, usdcReserveId, _deadlineIn());
        assertFalse(p.debtPriceFresh, "preview: debt price stale");
        assertFalse(p.pricesUsable, "preview: prices unusable");
        _expectRefused(p.params, abi.encodeWithSelector(ILPVaultSwapErrors.StalePrice.selector));
        _refreshAndPoke();
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

    /// @dev Time moves past every feed's `liquidationPriceMaxAge` (`FEED_AGE`) with no new round anywhere.
    function _letFeedsAge() internal {
        vm.warp(block.timestamp + FEED_AGE + 1);
        vm.roll(block.number + (FEED_AGE + 1) / BLOCK_TIME);
        ghoFeed.push(ghoFeed.answer(), block.timestamp);
    }

    /// @dev Every feed republished, then every LPOracle and the USDC DebtOracle poked, as a keeper does.
    function _refreshAndPoke() internal {
        _refreshFeeds();
        _pokeAll();
        usdcOracle.poke();
    }

    /// @dev A new round now, at its current answer, on every feed of `token`.
    function _republish(
        address token
    ) internal {
        OracleFeedMock[4] storage f = feedsOf[token];
        for (uint256 i = 0; i < 4; ++i) {
            f[i].push(f[i].answer(), block.timestamp);
        }
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
        _assetOf(params.debtReserveId).approve(lpVaultSwap, 0);
    }
}
