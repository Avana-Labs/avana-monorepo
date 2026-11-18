// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {DebtReserveParams, MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice Hard and liveness bounds of every parameter of 1.5 at its minimum, its maximum, one below the minimum and
/// one above the maximum, through every setter that writes it. Each refused write leaves the stored value unchanged.
contract ParameterStoreBoundsUnitTest is ParameterStoreFixture {
    uint256 internal constant USD_MAX = type(uint128).max;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreBase.OutOfBounds.selector);
    bytes internal live = abi.encodeWithSelector(IParameterStoreBase.LivenessBound.selector);
    bytes internal notStricter = abi.encodeWithSelector(IParameterStoreBase.NotStricter.selector);
    bytes internal notLooser = abi.encodeWithSelector(IParameterStoreBase.NotLooser.selector);

    function setUp() public {
        _deployStore();
        _listMarket();
    }

    // ─── Helpers ───

    function _accepts(
        bytes memory data
    ) internal {
        vm.prank(governor);
        (bool ok, bytes memory ret) = address(store).call(data);
        assertTrue(ok, "refused an in-bounds value");
        assertEq(ret.length, 0, "setter returned data");
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(governor);
        (bool ok, bytes memory ret) = address(store).call(data);
        assertFalse(ok, "accepted an out-of-bounds value");
        assertEq(ret, err, "wrong error");
    }

    function _params() internal view returns (MarketParams memory p) {
        p = store.getMarketParams(M);
    }

    function _relist(
        MarketParams memory p
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(governor);
        (ok, ret) = address(store).call(abi.encodeCall(store.setInitialMarketParams, (M, p)));
    }

    // ─── slippageAllowanceBps: [slippageAllowanceMinBps, 10,000) ───

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-050, REQ-PSTORE-004, REQ-CONFIG-041
    function test_TEST_064_slippageAtListingAtBothEnds() public {
        MarketParams memory p = _params();
        p.slippageAllowanceBps = 9999;
        (bool ok,) = _relist(p);
        assertTrue(ok);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 9999);
        p.slippageAllowanceBps = 10_000;
        bytes memory ret;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        // Equal to the floor is the lowest accepted value; one below is a liveness failure.
        p.slippageAllowanceBps = p.slippageAllowanceMinBps;
        (ok,) = _relist(p);
        assertTrue(ok);
        p.slippageAllowanceBps = p.slippageAllowanceMinBps - 1;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, live);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 30);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-050, REQ-PSTORE-017, REQ-CONFIG-067
    function test_TEST_064_slippageLoosenStopsBelowTenThousand() public {
        MarketParams memory p = _params();
        p.slippageAllowanceBps = 9980;
        (bool ok,) = _relist(p);
        assertTrue(ok);
        // 10,000 is out of bounds before the step is measured; 9,999 is within one step of 9,980.
        _refuses(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 10_000)), oob);
        _accepts(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 9999)));
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 9999);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-PSTORE-015, INV-047
    function test_TEST_064_slippageTightenStopsAtTheFloor() public {
        _refuses(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 29)), live);
        _refuses(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 0)), live);
        _accepts(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 30)));
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 30);
        // At the floor, every lower value is a liveness failure and the same value is not stricter.
        _refuses(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 30)), notStricter);
    }

    // ─── slippageAllowanceMinBps: at most slippageAllowanceBps ───

    // TEST-064 verifies: REQ-CONFIG-041, REQ-CONFIG-052, REQ-PSTORE-015
    function test_TEST_064_slippageFloorNeverAboveTheAllowance() public {
        _accepts(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, 100)));
        assertEq(store.slippageAllowanceMinBps(M), 100);
        _refuses(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, 101)), live);
        _accepts(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, 0)));
        assertEq(store.slippageAllowanceMinBps(M), 0);
        // With the floor at 0 the allowance can be tightened all the way to 0.
        _accepts(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 0)));
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 0);
    }

    // ─── poolRiskFactor: [1, 9,000] ───

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-050
    function test_TEST_064_poolRiskFactorAtBothEnds() public {
        _refuses(abi.encodeCall(store.setPoolRiskFactor, (M, 0)), oob);
        _accepts(abi.encodeCall(store.setPoolRiskFactor, (M, 1)));
        assertEq(store.getMarketParams(M).poolRiskFactor, 1);
        _accepts(abi.encodeCall(store.setPoolRiskFactor, (M, 9000)));
        assertEq(store.getMarketParams(M).poolRiskFactor, 9000);
        _refuses(abi.encodeCall(store.setPoolRiskFactor, (M, 9001)), oob);
        assertEq(store.getMarketParams(M).poolRiskFactor, 9000);
        // The tighten setter keeps it above 0.
        _accepts(abi.encodeCall(store.tightenPoolRiskFactor, (M, 1)));
        _refuses(abi.encodeCall(store.tightenPoolRiskFactor, (M, 0)), oob);
        assertEq(store.getMarketParams(M).poolRiskFactor, 1);
    }

    // TEST-250 verifies: REQ-CONFIG-015, REQ-PSTORE-004
    function test_TEST_250_poolRiskFactorAtListingAtBothEnds() public {
        MarketParams memory p = _params();
        p.poolRiskFactor = 0;
        (bool ok, bytes memory ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        p.poolRiskFactor = 9001;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        p.poolRiskFactor = 1;
        (ok,) = _relist(p);
        assertTrue(ok);
        assertEq(store.getMarketParams(M).poolRiskFactor, 1);
    }

    // ─── minPledgeUsd: [0, 100,000e8] ───

    // TEST-064 verifies: REQ-PSTORE-005, REQ-CONFIG-050, REQ-ACCESS-146
    function test_TEST_064_minPledgeAtBothEnds() public {
        _accepts(abi.encodeCall(store.tightenMinPledgeUsd, (M, 100_000e8)));
        assertEq(store.minPledgeUsd(M), 100_000e8);
        _refuses(abi.encodeCall(store.tightenMinPledgeUsd, (M, 100_000e8 + 1)), oob);
        _accepts(abi.encodeCall(store.loosenMinPledgeUsd, (M, 0)));
        assertEq(store.minPledgeUsd(M), 0);
        _refuses(abi.encodeCall(store.loosenMinPledgeUsd, (M, 0)), notLooser);
        MarketParams memory p = _params();
        p.minPledgeUsd = 100_000e8 + 1;
        (bool ok, bytes memory ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        p.minPledgeUsd = 100_000e8;
        (ok,) = _relist(p);
        assertTrue(ok);
        assertEq(store.minPledgeUsd(M), 100_000e8);
    }

    // ─── tokenCollateralFactorBps: [1, 9,999] ───

    // TEST-064 verifies: REQ-CONFIG-019, REQ-CONFIG-020, REQ-CONFIG-050
    function test_TEST_064_collateralFactorAtBothEnds() public {
        _refuses(abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, 0)), oob);
        _accepts(abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, 1)));
        assertEq(store.tokenCollateralFactorBps(usdc), 1);
        _accepts(abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, 9999)));
        assertEq(store.tokenCollateralFactorBps(usdc), 9999);
        _refuses(abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, 10_000)), oob);
        assertEq(store.tokenCollateralFactorBps(usdc), 9999);
    }

    // ─── maxFlashFeeBps: [0, 100] ───

    // TEST-064 verifies: REQ-PSTORE-024, REQ-CONFIG-050
    function test_TEST_064_maxFlashFeeAtBothEnds() public {
        // No live market is on the chain, so a raise has no pair to re-check.
        _accepts(abi.encodeCall(store.setMaxFlashFeeBps, (100)));
        assertEq(store.maxFlashFeeBps(), 100);
        _refuses(abi.encodeCall(store.setMaxFlashFeeBps, (101)), oob);
        _refuses(abi.encodeCall(store.setMaxFlashFeeBps, (type(uint16).max)), oob);
        _accepts(abi.encodeCall(store.tightenMaxFlashFeeBps, (0)));
        assertEq(store.maxFlashFeeBps(), 0);
        _refuses(abi.encodeCall(store.tightenMaxFlashFeeBps, (0)), notStricter);
        _accepts(abi.encodeCall(store.setMaxFlashFeeBps, (0)));
        assertEq(store.maxFlashFeeBps(), 0);
    }

    // ─── avanaFeeShareBps: [0, 5,000] ───

    // TEST-064 verifies: REQ-PSTORE-010, REQ-CONFIG-050
    function test_TEST_064_feeShareAtBothEnds() public {
        _accepts(abi.encodeCall(store.setAvanaFeeShareBps, (0)));
        assertEq(store.avanaFeeShareBps(), 0);
        _accepts(abi.encodeCall(store.setAvanaFeeShareBps, (5000)));
        assertEq(store.avanaFeeShareBps(), 5000);
        _refuses(abi.encodeCall(store.setAvanaFeeShareBps, (5001)), oob);
        _refuses(abi.encodeCall(store.setAvanaFeeShareBps, (10_000)), oob);
        assertEq(store.avanaFeeShareBps(), 5000);
    }

    /// @notice Audit finding L-03 (fresh audit 2026-11-15): a rise of the fee share must keep LIQ-I1's fee bound
    /// `s · minLB ≤ (10⁴ − f)(minLB − 10⁴)` on every live market, as activation and `loosenSlippageAllowanceBps` do; a
    /// cut is always allowed.
    // TEST-064 verifies: REQ-PSTORE-010, REQ-CONFIG-071
    function test_TEST_064_feeShareRiseKeepsTheFeeBound() public {
        uint256 minLb = _minLbNow();
        assertGt(minLb, 10_000, "fixture bonus");
        uint256 gain = minLb - 10_000;
        // Holds at f = 0, fails at f = 5,000.
        uint256 s = 7500 * gain / minLb;
        MarketParams memory p = _params();
        p.slippageAllowanceBps = uint16(s);
        (bool ok,) = _relist(p);
        assertTrue(ok, "relist");
        _accepts(abi.encodeCall(store.setAvanaFeeShareBps, (0)));
        _activate();
        uint256 fMax = 10_000 - (s * minLb + gain - 1) / gain;
        _refuses(abi.encodeCall(store.setAvanaFeeShareBps, (5000)), oob);
        _refuses(abi.encodeCall(store.setAvanaFeeShareBps, (uint16(fMax + 1))), oob);
        _accepts(abi.encodeCall(store.setAvanaFeeShareBps, (uint16(fMax))));
        assertEq(store.avanaFeeShareBps(), fMax);
        _accepts(abi.encodeCall(store.setAvanaFeeShareBps, (0)));
    }

    /// @dev `minLB` of market M as the store derives it (latest dynamic key, liquidation bonus factor).
    function _minLbNow() internal view returns (uint256) {
        IAaveV4Spoke sp = IAaveV4Spoke(address(spoke));
        uint256 reserveId = sp.getReserveId(address(hub), IAaveV4Hub(address(hub)).getAssetId(address(vaultToken)));
        uint32 key = sp.getReserve(reserveId).dynamicConfigKey;
        uint256 bonus = sp.getDynamicReserveConfig(reserveId, key).maxLiquidationBonus;
        return 10_000 + (bonus - 10_000) * sp.getLiquidationConfig().liquidationBonusFactor / 10_000;
    }

    // ─── maxShortfallBps: [0, 5,000] ───

    // TEST-064 verifies: REQ-PSTORE-018, REQ-CONFIG-050
    function test_TEST_064_maxShortfallAtBothEnds() public {
        _accepts(abi.encodeCall(store.loosenMaxShortfallBps, (5000)));
        assertEq(store.maxShortfallBps(), 5000);
        _refuses(abi.encodeCall(store.loosenMaxShortfallBps, (5001)), oob);
        _accepts(abi.encodeCall(store.tightenMaxShortfallBps, (0)));
        assertEq(store.maxShortfallBps(), 0);
        _refuses(abi.encodeCall(store.loosenMaxShortfallBps, (5001)), oob);
        _refuses(abi.encodeCall(store.tightenMaxShortfallBps, (0)), notStricter);
        assertEq(store.maxShortfallBps(), 0);
    }

    // ─── debtStressRiseBps: [100, 5,000] once written ───

    // TEST-230 verifies: REQ-PSTORE-020, REQ-CONFIG-050
    function test_TEST_230_stressRiseAtBothEnds() public {
        _refuses(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 99)), oob);
        assertEq(store.debtStressRiseBps(usdc), 0);
        _accepts(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 100)));
        assertEq(store.debtStressRiseBps(usdc), 100);
        _accepts(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 5000)));
        assertEq(store.debtStressRiseBps(usdc), 5000);
        _refuses(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 5001)), oob);
        _accepts(abi.encodeCall(store.loosenDebtStressRiseBps, (usdc, 100)));
        assertEq(store.debtStressRiseBps(usdc), 100);
        // Once written it never returns below 100 bps, so the asset keeps its DebtOracle mark.
        _refuses(abi.encodeCall(store.loosenDebtStressRiseBps, (usdc, 99)), oob);
        _refuses(abi.encodeCall(store.loosenDebtStressRiseBps, (usdc, 0)), oob);
        assertEq(store.debtStressRiseBps(usdc), 100);
    }

    // ─── coverageRatioBps: [0, 10,000] ───

    // TEST-273 verifies: REQ-PSTORE-032, REQ-CONFIG-050
    function test_TEST_273_coverageRatioAtBothEnds() public {
        _accepts(abi.encodeCall(store.setCoverageRatioBps, (10_000)));
        assertEq(store.coverageRatioBps(), 10_000);
        _refuses(abi.encodeCall(store.setCoverageRatioBps, (10_001)), oob);
        _accepts(abi.encodeCall(store.setCoverageRatioBps, (0)));
        assertEq(store.coverageRatioBps(), 0);
        _refuses(abi.encodeCall(store.setCoverageRatioBps, (type(uint16).max)), oob);
        assertEq(store.coverageRatioBps(), 0);
    }

    // ─── USD caps and the stress floor: (0, 2^128 − 1] ───

    // TEST-272 verifies: REQ-RISK-041, REQ-RISK-044
    function test_TEST_272_initialMarketCapsAtBothEnds() public {
        _refuses(abi.encodeCall(store.setInitialMarketCaps, (M, 0, 0, 1)), oob);
        _refuses(abi.encodeCall(store.setInitialMarketCaps, (M, USD_MAX + 1, 0, 1)), oob);
        _refuses(abi.encodeCall(store.setInitialMarketCaps, (M, 100, 101, 1)), oob);
        _refuses(abi.encodeCall(store.setInitialMarketCaps, (M, 100, 0, 0)), oob);
        _refuses(abi.encodeCall(store.setInitialMarketCaps, (M, 100, 0, USD_MAX + 1)), oob);
        assertEq(store.marketUsdCap(M), 5_000_000e8);
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, USD_MAX, USD_MAX, USD_MAX)));
        assertEq(store.marketUsdCap(M), USD_MAX);
        assertEq(store.topUpSliceUsd(M), USD_MAX);
        assertEq(store.stressFloorUsd(M), USD_MAX);
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, 1, 0, 1)));
        assertEq(store.marketUsdCap(M), 1);
        assertEq(store.topUpSliceUsd(M), 0);
        assertEq(store.stressFloorUsd(M), 1);
    }

    // TEST-272 verifies: REQ-PSTORE-026, REQ-RISK-044
    function test_TEST_272_initialHubCapsAtBothEnds() public {
        address hub2 = makeAddr("hub2");
        address hub3 = makeAddr("hub3");
        registry.setHub(hub2, true);
        registry.setHub(hub3, true);
        _refuses(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, 0)), oob);
        _refuses(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, USD_MAX + 1)), oob);
        _accepts(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, USD_MAX)));
        assertEq(store.tokenUsdCap(hub2, usdt), USD_MAX);
        _accepts(abi.encodeCall(store.setInitialTokenCap, (hub3, usdt, 1)));
        assertEq(store.tokenUsdCap(hub3, usdt), 1);
    }

    // TEST-225 verifies: REQ-RISK-044, REQ-PSTORE-017, REQ-CONFIG-067
    function test_TEST_225_capLoosenStopsAtTheCeiling() public {
        // The ceiling is checked before the step: one past it is out of bounds even from far below.
        bytes32 tokenKey = keccak256(abi.encode(bytes32("tokenUsdCap"), keccak256(abi.encode(address(hub), usdc))));
        _refuses(abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, USD_MAX + 1)), oob);
        _refuses(
            abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, USD_MAX)),
            abi.encodeWithSelector(IParameterStoreBase.LoosenStepTooLarge.selector, tokenKey)
        );
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, USD_MAX + 1)), oob);
        // From one below the ceiling, the ceiling itself is one step away and accepted.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, USD_MAX - 1, 0, 1)));
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, USD_MAX)));
        assertEq(store.marketUsdCap(M), USD_MAX);
        address hub2 = makeAddr("hub2");
        registry.setHub(hub2, true);
        _accepts(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, USD_MAX - 1)));
        _accepts(abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdt, USD_MAX)));
        assertEq(store.tokenUsdCap(hub2, usdt), USD_MAX);
    }

    // TEST-272 verifies: REQ-RISK-044, REQ-RISK-042
    function test_TEST_272_capTightenStopsAboveZero() public {
        // A partial tightening stores the new value itself, not 0.
        uint256 slice = store.topUpSliceUsd(M) / 2;
        assertGt(slice, 0);
        _accepts(abi.encodeCall(store.tightenTopUpSliceUsd, (M, slice)));
        assertEq(store.topUpSliceUsd(M), slice);
        _accepts(abi.encodeCall(store.tightenTopUpSliceUsd, (M, 0)));
        assertEq(store.topUpSliceUsd(M), 0);
        _accepts(abi.encodeCall(store.tightenMarketUsdCap, (M, 10_000e8)));
        assertEq(store.marketUsdCap(M), 10_000e8);
        _accepts(abi.encodeCall(store.tightenMarketUsdCap, (M, 0)));
        assertEq(store.marketUsdCap(M), 0, "a market cap tightens to 0");
        _accepts(abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 10_000e8)));
        _accepts(abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 0)));
        assertEq(store.tokenUsdCap(address(hub), usdc), 0, "a token cap tightens to 0");
    }

    // TEST-272 verifies: REQ-RISK-044, REQ-PSTORE-004
    function test_TEST_272_marketCapMayGoBelowTheSliceButTheSliceNeverRisesAboveTheCap() public {
        // Slice 500,000: the cap may fall below it, since the slice admits only rescue top-ups.
        _accepts(abi.encodeCall(store.tightenMarketUsdCap, (M, 500_000e8 - 1)));
        assertEq(store.marketUsdCap(M), 500_000e8 - 1);
        assertEq(store.topUpSliceUsd(M), 500_000e8, "the slice is left as it was");
        // A loosening of the slice may not take it above the cap.
        _refuses(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 500_000e8 + 1)), oob);
    }

    // TEST-272 verifies: REQ-RISK-045, REQ-RISK-044
    function test_TEST_272_stressFloorAtBothEnds() public {
        _refuses(abi.encodeCall(store.setStressFloorUsd, (M, 0)), oob);
        _refuses(abi.encodeCall(store.setStressFloorUsd, (M, USD_MAX + 1)), oob);
        assertEq(store.stressFloorUsd(M), 1e8);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, USD_MAX)));
        assertEq(store.stressFloorUsd(M), USD_MAX);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 1)));
        assertEq(store.stressFloorUsd(M), 1);
    }

    // ─── Route depth thresholds ───

    // TEST-064 verifies: REQ-CONFIG-070, REQ-CONFIG-050, REQ-ROUTE-006
    function test_TEST_064_routeDepthKindAndValue() public {
        _refuses(abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, 2, 1)), oob);
        _refuses(abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, type(uint8).max, 1)), oob);
        _refuses(abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, 0, 0)), notStricter);
        _accepts(abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, 1, type(uint256).max)));
        assertEq(store.routeDepthThreshold(M, usdc, gho, 1), type(uint256).max);
        _accepts(abi.encodeCall(store.loosenRouteDepthThreshold, (M, usdc, gho, 1, 1)));
        assertEq(store.routeDepthThreshold(M, usdc, gho, 1), 1);
        _refuses(abi.encodeCall(store.loosenRouteDepthThreshold, (M, usdc, gho, 1, 0)), oob);
        // A slot of an out-of-range kind holds nothing, so there is nothing to loosen.
        _refuses(abi.encodeCall(store.loosenRouteDepthThreshold, (M, usdc, gho, 2, 1)), notLooser);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 2), 0);
    }

    // ─── Feed ages ───

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-050
    function test_TEST_250_borrowAgeAtBothEnds() public {
        address f = address(fUsdc);
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (f, 0)), oob);
        _accepts(abi.encodeCall(store.setBorrowPriceMaxAge, (f, 1)));
        assertEq(store.borrowPriceMaxAge(f), 1);
        _accepts(abi.encodeCall(store.setBorrowPriceMaxAge, (f, 88_200)));
        assertEq(store.borrowPriceMaxAge(f), 88_200);
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (f, 88_201)), oob);
        assertEq(store.borrowPriceMaxAge(f), 88_200);
        _accepts(abi.encodeCall(store.tightenBorrowPriceMaxAge, (f, 1)));
        _refuses(abi.encodeCall(store.tightenBorrowPriceMaxAge, (f, 1)), notStricter);
        _refuses(abi.encodeCall(store.tightenBorrowPriceMaxAge, (f, 0)), oob);
        assertEq(store.borrowPriceMaxAge(f), 1);
    }

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-052
    function test_TEST_250_liquidationAndFeedAgesOnlyAtTheFormula() public {
        address f = address(fUsdc);
        _refuses(abi.encodeCall(store.setLiquidationPriceMaxAge, (f, 88_199)), live);
        _refuses(abi.encodeCall(store.setLiquidationPriceMaxAge, (f, 88_201)), oob);
        _refuses(abi.encodeCall(store.setLiquidationPriceMaxAge, (f, 0)), live);
        _accepts(abi.encodeCall(store.setLiquidationPriceMaxAge, (f, 88_200)));
        assertEq(store.liquidationPriceMaxAge(f), 88_200);
        _refuses(abi.encodeCall(store.setFeedMaxAge, (f, 88_199)), oob);
        _refuses(abi.encodeCall(store.setFeedMaxAge, (f, 88_201)), oob);
        _accepts(abi.encodeCall(store.setFeedMaxAge, (f, 88_200)));
        assertEq(store.getFeed(f).feedMaxAge, 88_200);
    }

    // ─── Check order where several errors apply ───

    // TEST-064 verifies: REQ-CONFIG-051, REQ-CONFIG-067, SPEC-GOV-011
    function test_TEST_064_notStricterBeforeBounds() public {
        // A value both not stricter and out of bounds reports NotStricter: direction first, then bounds.
        _refuses(abi.encodeCall(store.tightenMinPledgeUsd, (M, 0)), notStricter);
        _refuses(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 0)), notStricter);
        _refuses(abi.encodeCall(store.tightenMarketUsdCap, (M, USD_MAX + 1)), notStricter);
        _refuses(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 100)), notStricter);
        _refuses(abi.encodeCall(store.tightenPoolRiskFactor, (M, 4001)), notStricter);
    }

    // TEST-225 verifies: REQ-CONFIG-051, REQ-CONFIG-067, REQ-PSTORE-017
    function test_TEST_225_notLooserBeforeBoundsAndStep() public {
        _refuses(abi.encodeCall(store.loosenMaxShortfallBps, (0)), notLooser);
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenMinPledgeUsd, (M, USD_MAX)), notLooser);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-PSTORE-004, REQ-CONFIG-067
    function test_TEST_064_listingLivenessBeforeRange() public {
        // A slippage floor above the allowance and an allowance of 10,000 together report the liveness failure first.
        MarketParams memory p = _params();
        p.slippageAllowanceBps = 10_000;
        (bool ok, bytes memory ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        p.slippageAllowanceMinBps = 10_001;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, live);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-050, REQ-PSTORE-004, REQ-CONFIG-041
    /// @notice A slippage allowance above 10,000 bps is refused at listing, as 10,000 is.
    function test_TEST_064_slippageAboveBpsRefusedAtListing() public {
        MarketParams memory p = _params();
        p.slippageAllowanceBps = 10_001;
        (bool ok, bytes memory ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
    }

    // TEST-246 verifies: REQ-CONFIG-050, REQ-PSTORE-006
    /// @notice A zero rounding allowance is refused at the initial write.
    function test_TEST_246_zeroRoundingAllowanceRefused() public {
        _refuses(abi.encodeCall(store.setDebtAssetParams, (gho, DebtReserveParams(0))), oob);
    }

    // TEST-272 verifies: REQ-RISK-045, SPEC-CAP-006
    /// @notice The stress floor's two direction rules: a lowering is allowed with vault-token supply outstanding, and a
    /// raise skips the Hub `addCap` check (a higher floor only lowers the required `addCap`).
    function test_TEST_272_stressFloorDirectionRules() public {
        vaultToken.setSupply(1);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 0.5e8)));
        assertEq(store.stressFloorUsd(M), 0.5e8);
        vaultToken.setSupply(0);
        _activate();
        hub.setAddCap(1);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 2e8)));
        assertEq(store.stressFloorUsd(M), 2e8);
    }

    // TEST-272 verifies: SPEC-CAP-006, REQ-RISK-044
    /// @notice An uncapped Hub `addCap` (`MAX_ALLOWED_SPOKE_CAP`) passes the sizing check whatever the ratio: on an
    /// Active market a floor of 1 would need 5.5e14 whole tokens, above 2^40 - 1, and the lowering still passes.
    function test_TEST_272_uncappedAddCapSkipsSizing() public {
        _activate();
        hub.setAddCap(type(uint40).max);
        _accepts(abi.encodeCall(store.setStressFloorUsd, (M, 1)));
        assertEq(store.stressFloorUsd(M), 1);
    }
}
