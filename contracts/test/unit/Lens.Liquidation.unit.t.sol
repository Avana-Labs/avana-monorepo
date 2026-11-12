// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {MarketParams as MarketParamsLike} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensLiquidationUnitTest
/// @notice `previewLiquidation` on the real Aave V4 Spoke: identity and reserve checks, every gate, Aave's sizing
/// compiled from the pinned `LiquidationLogic`, the ready-to-send parameters with the inclusion margin, and the expected
/// amounts, each compared with a `liquidationCall` executed in the same block.
/// forge-config: default.isolate = false
contract LensLiquidationUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;
    uint256 internal constant DEADLINE = T0 + 120;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // ─── identity ───

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-033
    function test_TEST_069_unknownProxyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownProxy.selector, bobProxy));
        lens.previewLiquidation(bobProxy, debtReserveId, DEADLINE);
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-033
    function test_TEST_069_proxyNotRegisteredOnVaultTokenReverts() public {
        address stray = makeAddr("strayProxy");
        adapterMock.bind(bob, stray, aave.cdpSpoke, MARKET_ID, vt, vtReserveId);
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownProxy.selector, stray));
        lens.previewLiquidation(stray, debtReserveId, DEADLINE);
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-032
    function test_TEST_069_unknownDebtReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 77));
        lens.previewLiquidation(aliceProxy, 77, DEADLINE);
        reg.disableDebtReserve(aave.cdpSpoke, usdcReserveId);
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, usdcReserveId));
        lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE);
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-005
    function test_TEST_069_identityFields() public view {
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(p.blockNumber, block.number, "block");
        assertEq(p.timestamp, block.timestamp, "timestamp");
        assertEq(p.proxy, aliceProxy, "proxy");
        assertEq(p.marketId, MARKET_ID, "market");
        assertEq(p.vaultToken, vt, "vault token");
        assertEq(p.reserveId, vtReserveId, "collateral reserve");
        assertEq(p.debtReserveId, debtReserveId, "debt reserve");
        assertEq(p.debtAsset, address(debt), "debt asset");
        assertEq(p.suppliedUnits, UNITS, "supplied units");
        IAaveV4Spoke.LiquidationConfig memory lc = IAaveV4Spoke(aave.cdpSpoke).getLiquidationConfig();
        assertEq(p.targetHealthFactor, lc.targetHealthFactor, "target HF");
        assertEq(p.healthFactorForMaxBonus, lc.healthFactorForMaxBonus, "HF for max bonus");
        assertEq(p.liquidationBonusFactor, lc.liquidationBonusFactor, "bonus factor");
    }

    // ─── healthy accounts ───

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-017, REQ-LENS-028
    function test_TEST_069_healthyAccountHasZeroAmounts() public {
        _borrow(aliceProxy, 5000e18);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertFalse(p.aaveLiquidatable, "HF 3.2");
        assertEq(p.healthFactor, _hf(aliceProxy), "Aave's health factor");
        assertEq(p.expectedDebtRepaid, 0, "nothing to repay");
        assertEq(p.expectedUnitsSeized, 0, "nothing seized");
        assertEq(p.params.debtToCover, 0, "params amount 0");
        assertEq(p.recoveryFloor, 0, "no floor");
        assertEq(p.expectedPayout, 0, "no payout");
        assertEq(p.params.proxy, aliceProxy, "params still name the account");
        assertEq(p.params.deadline, DEADLINE, "deadline copied");
        assertGt(p.minOutPerWholeToken, 0, "the whole-token floor is reported at every health factor");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-017
    function test_TEST_069_noDebtOnReserveHasZeroAmounts() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE);
        assertTrue(p.aaveLiquidatable, "liquidatable");
        assertEq(p.expectedDebtRepaid, 0, "no USDC debt: Aave would refuse");
        assertEq(p.params.debtToCover, 0, "nothing to send");
    }

    // ─── sizing equals execution ───

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, Q-232, Q-268
    function test_TEST_069_ghoSizingEqualsExecution() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.aaveLiquidatable, "HF 0.96");
        assertEq(p.bonusBps, _bonus(aliceProxy), "the Spoke's bonus");
        assertEq(p.params.debtToCover, p.expectedDebtRepaid, "a regular partial liquidation sends Aave's size");
        (uint256 repaid, uint256 seized) = _execute(address(debt), debtReserveId, aliceProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "debt Aave pulled");
        assertEq(seized, p.expectedUnitsSeized, "units seized");
        assertApproxEqAbs(_hf(aliceProxy), 1.1e18, 0.001e18, "restored to the target health factor");
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-029
    function test_TEST_069_usdcSizingEqualsExecution() public {
        _borrowUsdc(aliceProxy, 15_000e6);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE);
        assertTrue(p.aaveLiquidatable, "liquidatable");
        (uint256 repaid, uint256 seized) = _execute(address(usdc), usdcReserveId, aliceProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "USDC repaid");
        assertEq(seized, p.expectedUnitsSeized, "units seized");
        assertEq(p.routeUsable.length, 2, "only USDT needs a route into USDC");
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-029
    function test_TEST_069_sizingWithAccruedInterestEqualsExecution() public {
        _borrow(aliceProxy, 15_500e18);
        vm.warp(block.timestamp + 200 days);
        _setVtPrice(1.93e8);
        assertGt(_debtOf(aliceProxy, debtReserveId), 15_500e18, "the drawn index grew");
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.aaveLiquidatable, "below 1 at the grown debt");
        (uint256 repaid, uint256 seized) = _execute(address(debt), debtReserveId, aliceProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "drawn shares at the grown index, rounded up");
        assertEq(seized, p.expectedUnitsSeized, "seizure from the RAY debt");
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-028, Q-235, Q-268
    function test_TEST_069_dustRemainderAsksForMarginedWholeDebt() public {
        // 1,060 GHO owed; Aave's own sizing would leave a remainder under $1,050.
        _open(bob, bobProxy, 2, 700e6);
        _borrow(bobProxy, 1060e18);
        _setVtPrice(1.85e8);
        LiquidationPreview memory p = lens.previewLiquidation(bobProxy, debtReserveId, DEADLINE);
        assertTrue(p.aaveLiquidatable, "liquidatable");
        uint256 total = _debtOf(bobProxy, debtReserveId);
        assertEq(p.params.debtToCover, _ceilDiv(total * 10_500, 10_000), "whole debt plus 5 %");
        (uint256 repaid,) = _execute(address(debt), debtReserveId, bobProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "Aave repays its own size");
        assertLe(repaid, p.params.debtToCover, "never more than sent");
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-028
    function test_TEST_069_wholeDebtIsMarginedAndStaysValidLater() public {
        _open(bob, bobProxy, 2, 600e6);
        _borrow(bobProxy, 900e18);
        _setVtPrice(1.7e8);
        LiquidationPreview memory p = lens.previewLiquidation(bobProxy, debtReserveId, DEADLINE);
        uint256 total = _debtOf(bobProxy, debtReserveId);
        assertEq(p.expectedDebtRepaid, total, "dust rule: the whole debt");
        assertEq(p.params.debtToCover, _ceilDiv(total * 10_500, 10_000), "margined");
        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 7200);
        assertGt(_debtOf(bobProxy, debtReserveId), total, "the debt grew");
        (uint256 repaid,) = _execute(address(debt), debtReserveId, bobProxy, p.params.debtToCover);
        assertGt(repaid, total, "repaid the grown debt");
        assertEq(_debtOf(bobProxy, debtReserveId), 0, "the stale params still repay the whole, grown debt");
    }

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-028
    function test_TEST_069_allCollateralSeizedIsMargined() public {
        _open(bob, bobProxy, 2, 4000e6);
        _borrow(bobProxy, 6000e18);
        _setVtPrice(1e8);
        LiquidationPreview memory p = lens.previewLiquidation(bobProxy, debtReserveId, DEADLINE);
        assertEq(p.expectedUnitsSeized, 4000e6, "the whole collateral");
        uint256 total = _debtOf(bobProxy, debtReserveId);
        assertLt(p.expectedDebtRepaid, total, "a deficit remains");
        assertEq(p.params.debtToCover, _ceilDiv(total * 10_500, 10_000), "all-collateral: margined whole debt");
        (uint256 repaid, uint256 seized) = _execute(address(debt), debtReserveId, bobProxy, p.params.debtToCover);
        assertEq(repaid, p.expectedDebtRepaid, "repaid");
        assertEq(seized, p.expectedUnitsSeized, "seized");
    }

    // TEST-069 verifies: REQ-LENS-028
    function test_TEST_069_remainderAboveMarginSendsExactSize() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        uint256 rest = _debtOf(aliceProxy, debtReserveId) - p.expectedDebtRepaid;
        assertGt(rest, 1050e18, "remainder far above $1,050");
        assertEq(p.params.debtToCover, p.expectedDebtRepaid, "sized exactly");
    }

    // TEST-069 verifies: REQ-LENS-028, Q-404
    function test_TEST_069_paramsReadyToSend() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(p.params.proxy, aliceProxy, "proxy");
        assertEq(p.params.marketId, MARKET_ID, "market");
        assertEq(p.params.debtReserveId, debtReserveId, "reserve");
        assertEq(uint8(p.params.routeMode), uint8(RouteMode.PrimaryThenBackup), "primary routes usable");
        assertEq(p.params.minAmounts.length, 0, "no per-leg minimums");
        assertEq(p.params.deadline, DEADLINE, "deadline");
        assertEq(p.params.minPayout, 0, "caller's choice");
        assertEq(p.params.maxShortfall, 0, "never authorizes a top-up");
    }

    // TEST-205 verifies: REQ-LENS-028, REQ-LENS-017, REQ-LENS-029, Q-232, Q-404
    function test_TEST_205_paramsExecuteUnchangedForGhoAndUsdc() public {
        _open(bob, bobProxy, 2, 10_000e6);
        _borrow(aliceProxy, 15_000e18);
        _borrowUsdc(bobProxy, 15_000e6);
        _setVtPrice(1.8e8);
        LiquidationPreview memory g = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        LiquidationPreview memory u = lens.previewLiquidation(bobProxy, usdcReserveId, DEADLINE);
        for (uint256 i = 0; i < 2; ++i) {
            LiquidationPreview memory p = i == 0 ? g : u;
            assertEq(p.params.minPayout, 0, "minPayout 0");
            assertEq(p.params.maxShortfall, 0, "maxShortfall 0");
            assertEq(p.params.minAmounts.length, 0, "empty minAmounts");
            assertEq(p.params.deadline, DEADLINE, "the input deadline");
            assertLe(
                p.expectedPayout, p.params.debtToCover + p.expectedUnitsSeized * 2e12, "a caller may raise minPayout"
            );
        }
        (uint256 rg, uint256 sg) = _execute(address(debt), debtReserveId, aliceProxy, g.params.debtToCover);
        (uint256 ru, uint256 su) = _execute(address(usdc), usdcReserveId, bobProxy, u.params.debtToCover);
        assertEq(rg, g.expectedDebtRepaid, "GHO debt repaid");
        assertEq(sg, g.expectedUnitsSeized, "GHO-debt units seized");
        assertEq(ru, u.expectedDebtRepaid, "USDC debt repaid");
        assertEq(su, u.expectedUnitsSeized, "USDC-debt units seized");
    }

    // TEST-069 verifies: REQ-LENS-004, ATTACK-135
    function test_TEST_069_stalePreviewCanOnlyRevert() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.aaveLiquidatable, "liquidatable when read");
        _setVtPrice(2e8);
        uint256 debtBefore = _debtOf(aliceProxy, debtReserveId);
        uint256 unitsBefore = token.balanceOf(lpVaultSwap);
        debt.mint(lpVaultSwap, p.params.debtToCover);
        vm.startPrank(lpVaultSwap);
        debt.approve(aave.cdpSpoke, p.params.debtToCover);
        vm.expectRevert();
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, aliceProxy, p.params.debtToCover, false);
        vm.stopPrank();
        assertEq(_debtOf(aliceProxy, debtReserveId), debtBefore, "nothing moved");
        assertEq(token.balanceOf(lpVaultSwap), unitsBefore, "no seizure");
        assertFalse(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).aaveLiquidatable, "a re-read shows it");
    }

    // ─── gates ───

    // TEST-069 verifies: REQ-LENS-016, REQ-SWAP-008, Q-247
    function test_TEST_069_pricesUsableWhenFresh() public view {
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.pricesUsable, "Live, fresh inputs, fixed debt price");
        assertTrue(p.debtPriceFresh, "GHO fixed price");
        assertFalse(p.feedsDisagree, "agree");
        assertFalse(p.inGrace, "no grace");
        assertTrue(p.sharesEqualAssets, "shares = assets");
        assertEq(p.activeKeeperCount, 1, "one committed operator");
        assertFalse(p.vaultTokenReservePaused, "collateral live");
        assertFalse(p.debtReservePaused, "debt live");
        assertEq(uint8(p.pauseState), uint8(PauseState.None), "no pause");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-SWAP-008
    function test_TEST_069_liquidationPausedBlocks() public {
        for (uint8 s = 2; s < 4; ++s) {
            lpo.setState(PriceState(s), 0, true);
            LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
            assertFalse(p.pricesUsable, "Cached and Expired block seizure");
        }
        lpo.setState(PriceState.Drifting, 0, false);
        assertTrue(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).pricesUsable, "Drifting is usable");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-SWAP-008
    function test_TEST_069_staleInputBlocks() public {
        lpo.setTokenAt(1, uint64(block.timestamp - FEED_AGE - 1), 0);
        assertFalse(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).pricesUsable, "USDT past 88,200 s");
        lpo.setTokenAt(1, uint64(block.timestamp - FEED_AGE), 0);
        assertTrue(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).pricesUsable, "at the bound: fresh");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-030
    function test_TEST_069_staleDebtPriceBlocksOnlyItsReserve() public {
        _borrow(aliceProxy, 1000e18);
        _borrowUsdc(aliceProxy, 1000e6);
        vm.warp(block.timestamp + 4201);
        lpo.setTokenAt(0, uint64(block.timestamp - 600), 0);
        lpo.setTokenAt(1, uint64(block.timestamp - 600), 0);
        LiquidationPreview memory usdcPreview = lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE);
        assertFalse(usdcPreview.debtPriceFresh, "USDC accepted round too old");
        assertFalse(usdcPreview.pricesUsable, "repaying USDC is blocked");
        LiquidationPreview memory ghoPreview = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(ghoPreview.debtPriceFresh, "GHO fresh");
        assertTrue(ghoPreview.pricesUsable, "repaying GHO still runs");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-030
    function test_TEST_069_debtOracleNotLiveBlocks() public {
        usdcOracle.set(0.9999e8, PriceState.Cached, 0.9999e8, uint64(block.timestamp));
        assertFalse(lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE).debtPriceFresh, "Cached");
    }

    // TEST-069 verifies: REQ-LENS-016, Q-208
    function test_TEST_069_disagreementReported() public {
        lpo.setDisagreement(uint64(block.timestamp - 100), true, false);
        lpo.setState(PriceState.Live, 1 << 9, true);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.feedsDisagree, "pause active");
        assertFalse(p.pricesUsable, "seizure paused");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-SWAP-009
    function test_TEST_069_graceReported() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        lpo.setGrace(true, uint64(block.timestamp - 10), uint64(block.timestamp + 1790));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.inGrace, "grace");
        assertFalse(p.belowGraceHealthFactor, "HF 0.96 above 0.95");
        store.setGraceHealthFactor(0.97e18);
        assertTrue(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).belowGraceHealthFactor, "below 0.97");
        lpo.setGrace(false, 0, 0);
        assertFalse(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).belowGraceHealthFactor, "no grace");
    }

    // TEST-069 verifies: REQ-LENS-016
    function test_TEST_069_sharesNotEqualAssetsReported() public {
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedAssets(uint256)", vtAssetId), abi.encode(1));
        assertFalse(lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE).sharesEqualAssets, "differ");
        vm.clearMockedCalls();
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-028, Q-379
    function test_TEST_069_routesAndRouteMode() public {
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(p.routeUsable.length, 4, "two tokens x primary and backup");
        assertEq(p.routeUsable[0].token, address(usdc), "USDC first");
        assertEq(p.routeUsable[0].debtAsset, address(debt), "into GHO");
        assertEq(p.routeUsable[0].routeKind, 0, "primary");
        assertEq(p.routeUsable[1].routeKind, 1, "backup");
        assertEq(p.routeUsable[2].token, address(usdt), "USDT second");
        reg.setRoute(MARKET_ID, address(usdt), address(debt), 1, address(0), false);
        p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertFalse(p.routeUsable[3].usable, "USDT backup unusable");
        assertEq(uint8(p.params.routeMode), uint8(RouteMode.PrimaryThenBackup), "primaries still usable");
        reg.setRoute(MARKET_ID, address(usdc), address(debt), 0, address(0), false);
        p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(uint8(p.params.routeMode), uint8(RouteMode.BackupOnly), "a primary unusable: backups only");
    }

    // TEST-069 verifies: REQ-LENS-016, Q-242
    function test_TEST_069_informationalFields() public {
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        swapMock.setKeeper(makeAddr("k2"), true, true);
        swapMock.setKeeper(makeAddr("k3"), true, false);
        vm.startPrank(aaveDao);
        _updatePaused(vtReserveId, true);
        vm.stopPrank();
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(uint8(p.pauseState), uint8(PauseState.Paused), "pause shown, never blocking");
        assertEq(p.activeKeeperCount, 2, "frozen operator not counted");
        assertTrue(p.vaultTokenReservePaused, "Aave paused flag");
        assertFalse(p.debtReservePaused, "debt reserve live");
    }

    // TEST-069 verifies: REQ-LENS-016, REQ-LENS-030, Q-247
    function test_TEST_069_stressValuedOtherReserveNeverBlocks() public {
        _borrow(aliceProxy, 1000e18);
        _borrowUsdc(aliceProxy, 1000e6);
        usdcOracle.set(1.05e8, PriceState.Expired, 1e8, uint64(block.timestamp));
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertTrue(p.stressValued, "USDC served above its accepted price");
        assertTrue(p.pricesUsable, "it does not block repaying GHO");
        LiquidationPreview memory q = lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE);
        assertFalse(q.stressValued, "the repaid reserve itself is not another reserve");
        assertFalse(q.pricesUsable, "repaying the Expired reserve is blocked");
    }

    // TEST-069 verifies: REQ-LENS-016, SPEC-LIQ-001, SPEC-LIQ-003
    function test_TEST_069_slippageFromBonusAndAllowance() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.6e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(p.bonusBps, 10_500, "max bonus below HF 0.95");
        assertEq(p.slippageBps, 100, "min(100, 476)");
        store.setMarketParams(MARKET_ID, _params(600));
        p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertEq(p.slippageBps, 476, "capped by the bonus: floor(1e4 x 500 / 10,500)");
    }

    // ─── expected amounts ───

    // TEST-069 verifies: REQ-LENS-029, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-009, SPEC-LIQ-010
    function test_TEST_069_expectedAmountsAtOracleValue() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        uint256 d = p.expectedDebtRepaid;
        uint256 v = p.expectedUnitsSeized * 1.8e8 * 1e18 / (1e6 * 1e8);
        uint256 u = 2 * 1e12;
        uint256 floor_ = _ceilDiv(v * 9900, 10_000) - u - 1e18;
        assertEq(p.recoveryFloor, floor_, "recovery floor");
        uint256 a = (v - d) * 2000 / 10_000;
        assertEq(p.expectedAvanaFee, a, "Avana's share of the oracle gain");
        assertEq(p.expectedBorrowerSurplus, 0, "no borrower surplus at the oracle value");
        assertEq(p.expectedPayout, p.params.debtToCover + v - d - a, "keeperOut = Kf + V - D - A");
        assertEq(p.expectedNetPayout, p.expectedPayout - p.params.debtToCover, "reward beyond the funding");
        assertEq(p.expectedCallerLoss, 0, "unwound value covers D");
    }

    // TEST-069 verifies: REQ-LENS-029
    function test_TEST_069_callerLossWhenUnwoundBelowDebt() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        lpo.setTokenPrice(0, 0.5e8);
        lpo.setTokenPrice(1, 0.5e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        uint256 c = p.expectedUnitsSeized;
        uint256 rv = (c * 800_000 / 1e6 - 1) * 0.5e8 * 1e18 / (1e6 * 1e8) + (c * 1_250_000 / 1e6 - 1) * 0.5e8 * 1e18
            / (1e6 * 1e8);
        assertEq(p.expectedCallerLoss, p.expectedDebtRepaid - rv, "D - Rv at the leg prices, each rounded down");
    }

    // TEST-069 verifies: REQ-LENS-029, SPEC-LIQ-005
    function test_TEST_069_usdcDebtCountsUsdcLegOneUnit() public {
        _borrowUsdc(aliceProxy, 15_000e6);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, usdcReserveId, DEADLINE);
        uint256 v = p.expectedUnitsSeized * 1.8e8 * 1e6 / (1e6 * 0.9999e8);
        uint256 u = 1 + 2; // USDC counts 1; one raw USDT at $1 in USDC at $0.9999 rounds up to 2.
        assertEq(p.recoveryFloor, _ceilDiv(v * 9900, 10_000) - u - 1e6, "floor in USDC base units");
    }

    // TEST-069 verifies: REQ-LENS-016, SPEC-LIQ-005
    function test_TEST_069_minOutPerWholeToken() public view {
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        uint256 v = 2e18;
        assertEq(p.minOutPerWholeToken, _ceilDiv(v * 9900, 10_000) - 2e12 - 1e18, "one whole token at $2.00");
    }

    // TEST-069 verifies: REQ-LENS-007, REQ-LENS-016
    function test_TEST_069_expiredMarketNeverReverts() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1);
        lpo.setState(PriceState.Expired, 0, true);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertFalse(p.pricesUsable, "Expired cannot be seized");
        assertTrue(p.aaveLiquidatable, "worthless collateral");
        assertEq(p.expectedUnitsSeized, UNITS, "Aave would seize everything at the served price");
    }

    // ─── helpers ───

    function _execute(
        address asset,
        uint256 reserveId,
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 repaid, uint256 seized) {
        CollPoolToken(asset).mint(lpVaultSwap, debtToCover);
        uint256 debtBefore = CollPoolToken(asset).balanceOf(lpVaultSwap);
        uint256 unitsBefore = token.balanceOf(lpVaultSwap);
        vm.startPrank(lpVaultSwap);
        CollPoolToken(asset).approve(aave.cdpSpoke, debtToCover);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, reserveId, proxy, debtToCover, false);
        vm.stopPrank();
        repaid = debtBefore - CollPoolToken(asset).balanceOf(lpVaultSwap);
        seized = token.balanceOf(lpVaultSwap) - unitsBefore;
    }

    function _bonus(
        address proxy
    ) internal view returns (uint256) {
        return IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(vtReserveId, proxy, _hf(proxy));
    }

    function _ceilDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    function _params(
        uint16 slippage
    ) internal pure returns (MarketParamsLike memory) {
        return MarketParamsLike(1800, 50, slippage, 30, 0, 10e8, 0);
    }

    function _updatePaused(
        uint256 reserveId,
        bool paused
    ) internal {
        (bool ok,) = aave.spokeConfigurator
            .call(abi.encodeWithSignature("updatePaused(address,uint256,bool)", aave.cdpSpoke, reserveId, paused));
        require(ok, "updatePaused");
    }
}
