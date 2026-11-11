// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice Hard and liveness bounds of every parameter of 1.5 at its minimum, its maximum, one below the minimum and
/// one above the maximum, through every setter that writes it. Each refused write leaves the stored value unchanged.
contract ParameterStoreBoundsUnitTest is ParameterStoreFixture {
    uint256 internal constant USD_MAX = type(uint128).max;
    bytes internal oob = abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);
    bytes internal live = abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector);
    bytes internal notStricter = abi.encodeWithSelector(IParameterStoreErrors.NotStricter.selector);
    bytes internal notLooser = abi.encodeWithSelector(IParameterStoreErrors.NotLooser.selector);

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    // ─── Helpers ───

    function _accepts(
        bytes memory data
    ) internal {
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(data);
        assertTrue(ok, "refused an in-bounds value");
        assertEq(ret.length, 0, "setter returned data");
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
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
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setInitialMarketParams, (M, p)));
    }

    // ─── hardHealthFloor: 0 (off) or [1e18, 1.25e18] ───

    // TEST-064 verifies: REQ-PSTORE-031, REQ-CONFIG-050, REQ-CONFIG-067, Q-398
    function test_TEST_064_hardFloorTightenAtBothEnds() public {
        _refuses(abi.encodeCall(store.tightenHardHealthFloor, (M, 1e18 - 1)), oob);
        assertEq(store.hardHealthFloor(M), 0);
        _accepts(abi.encodeCall(store.tightenHardHealthFloor, (M, 1e18)));
        assertEq(store.hardHealthFloor(M), 1e18);
        _accepts(abi.encodeCall(store.tightenHardHealthFloor, (M, 1.25e18)));
        assertEq(store.hardHealthFloor(M), 1.25e18);
        // Above the maximum the value is stricter, so the bound is the error.
        _refuses(abi.encodeCall(store.tightenHardHealthFloor, (M, 1.25e18 + 1)), oob);
        assertEq(store.hardHealthFloor(M), 1.25e18);
    }

    // TEST-064 verifies: REQ-PSTORE-031, REQ-PSTORE-004, REQ-CONFIG-050
    function test_TEST_064_hardFloorAtListingAtBothEnds() public {
        MarketParams memory p = _params();
        uint256[4] memory accepted = [uint256(0), 1e18, 1.1e18, 1.25e18];
        for (uint256 i = 0; i < accepted.length; ++i) {
            p.hardHealthFloor = accepted[i];
            (bool ok,) = _relist(p);
            assertTrue(ok, "listing refused an in-bounds floor");
            assertEq(store.hardHealthFloor(M), accepted[i]);
        }
        uint256[3] memory refused = [uint256(1), 1e18 - 1, 1.25e18 + 1];
        for (uint256 i = 0; i < refused.length; ++i) {
            p.hardHealthFloor = refused[i];
            (bool ok, bytes memory ret) = _relist(p);
            assertFalse(ok);
            assertEq(ret, oob);
            assertEq(store.hardHealthFloor(M), 1.25e18);
        }
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

    // ─── consistencyToleranceBps: [10, 10,000] ───

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-050, REQ-CONFIG-054
    function test_TEST_064_consistencyToleranceAtBothEnds() public {
        _refuses(abi.encodeCall(store.setConsistencyToleranceBps, (M, 9)), live);
        _accepts(abi.encodeCall(store.setConsistencyToleranceBps, (M, 10)));
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 10);
        _accepts(abi.encodeCall(store.setConsistencyToleranceBps, (M, 10_000)));
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 10_000);
        _refuses(abi.encodeCall(store.setConsistencyToleranceBps, (M, 10_001)), oob);
        _refuses(abi.encodeCall(store.setConsistencyToleranceBps, (M, type(uint16).max)), oob);
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 10_000);
        // The tighten setter reaches the same floor from above.
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 10)));
        _refuses(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 10)), notStricter);
        _refuses(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 9)), live);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-PSTORE-004
    function test_TEST_064_consistencyToleranceAtListingAtBothEnds() public {
        MarketParams memory p = _params();
        p.consistencyToleranceBps = 10_000;
        (bool ok, bytes memory ret) = _relist(p);
        assertTrue(ok);
        p.consistencyToleranceBps = 10_001;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        p.consistencyToleranceBps = 10;
        (ok,) = _relist(p);
        assertTrue(ok);
        p.consistencyToleranceBps = 9;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, live);
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 10);
    }

    // ─── poolRiskFactor: [1, 4,000] ───

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-050
    function test_TEST_064_poolRiskFactorAtBothEnds() public {
        _refuses(abi.encodeCall(store.setPoolRiskFactor, (M, 0)), oob);
        _accepts(abi.encodeCall(store.setPoolRiskFactor, (M, 1)));
        assertEq(store.getMarketParams(M).poolRiskFactor, 1);
        _accepts(abi.encodeCall(store.setPoolRiskFactor, (M, 4000)));
        assertEq(store.getMarketParams(M).poolRiskFactor, 4000);
        _refuses(abi.encodeCall(store.setPoolRiskFactor, (M, 4001)), oob);
        assertEq(store.getMarketParams(M).poolRiskFactor, 4000);
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
        p.poolRiskFactor = 4001;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, oob);
        p.poolRiskFactor = 1;
        (ok,) = _relist(p);
        assertTrue(ok);
        assertEq(store.getMarketParams(M).poolRiskFactor, 1);
    }

    // ─── minPledgeUsd: [0, 100,000e8] ───

    // TEST-064 verifies: REQ-PSTORE-005, REQ-CONFIG-050
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

    // ─── gateRecoverySeconds: [600, 7,200] ───

    // TEST-064 verifies: REQ-PSTORE-030, REQ-CONFIG-050
    function test_TEST_064_gateRecoveryAtBothEnds() public {
        _accepts(abi.encodeCall(store.tightenGateRecoverySeconds, (7200)));
        assertEq(store.gateRecoverySeconds(), 7200);
        _refuses(abi.encodeCall(store.tightenGateRecoverySeconds, (7201)), oob);
        _accepts(abi.encodeCall(store.loosenGateRecoverySeconds, (600)));
        assertEq(store.gateRecoverySeconds(), 600);
        _refuses(abi.encodeCall(store.loosenGateRecoverySeconds, (599)), oob);
        _refuses(abi.encodeCall(store.loosenGateRecoverySeconds, (0)), oob);
        _refuses(abi.encodeCall(store.tightenGateRecoverySeconds, (7201)), oob);
        assertEq(store.gateRecoverySeconds(), 600);
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

    // ─── poolShareMaxBps: (0, 10,000] ───

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, Q-403
    function test_TEST_272_poolShareDefaultAtBothEnds() public {
        _refuses(abi.encodeCall(store.loosenPoolShareMaxBps, (10_001)), oob);
        _refuses(abi.encodeCall(store.loosenPoolShareMaxBps, (10_000)), notLooser);
        _accepts(abi.encodeCall(store.tightenPoolShareMaxBps, (1)));
        assertEq(store.poolShareMaxBps(), 1);
        _refuses(abi.encodeCall(store.tightenPoolShareMaxBps, (0)), oob);
        _accepts(abi.encodeCall(store.loosenPoolShareMaxBps, (10_000)));
        assertEq(store.poolShareMaxBps(), 10_000);
        _accepts(abi.encodeCall(store.tightenPoolShareMaxBps, (9999)));
        _refuses(abi.encodeCall(store.loosenPoolShareMaxBps, (10_001)), oob);
        _refuses(abi.encodeCall(store.tightenPoolShareMaxBps, (0)), oob);
        assertEq(store.poolShareMaxBps(), 9999);
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, Q-383
    function test_TEST_272_poolShareOverrideAtBothEnds() public {
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        _refuses(abi.encodeCall(store.tightenPoolShareMaxBpsOf, (M, 0)), oob);
        _accepts(abi.encodeCall(store.tightenPoolShareMaxBpsOf, (M, 1)));
        assertEq(store.poolShareMaxBpsOf(key), 1);
        // The override rises at most to the chain default.
        _refuses(abi.encodeCall(store.loosenPoolShareMaxBpsOf, (M, 10_001)), oob);
        _accepts(abi.encodeCall(store.loosenPoolShareMaxBpsOf, (M, 10_000)));
        assertEq(store.poolShareMaxBpsOf(key), 10_000);
        _accepts(abi.encodeCall(store.tightenPoolShareMaxBps, (5000)));
        assertEq(store.poolShareMaxBpsOf(key), 5000);
        _refuses(abi.encodeCall(store.loosenPoolShareMaxBpsOf, (M, 5001)), oob);
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
        _refuses(abi.encodeCall(store.setInitialHubCaps, (hub2, 0)), oob);
        _refuses(abi.encodeCall(store.setInitialHubCaps, (hub2, USD_MAX + 1)), oob);
        assertEq(store.depositorUsdCap(hub2), 0);
        _accepts(abi.encodeCall(store.setInitialHubCaps, (hub2, USD_MAX)));
        assertEq(store.depositorUsdCap(hub2), USD_MAX);
        _accepts(abi.encodeCall(store.setInitialHubCaps, (hub3, 1)));
        assertEq(store.depositorUsdCap(hub3), 1);
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
            abi.encodeWithSelector(IParameterStoreErrors.LoosenStepTooLarge.selector, tokenKey)
        );
        _refuses(abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), USD_MAX + 1)), oob);
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, USD_MAX + 1)), oob);
        // From one below the ceiling, the ceiling itself is one step away and accepted.
        _accepts(abi.encodeCall(store.setInitialMarketCaps, (M, USD_MAX - 1, 0, 1)));
        _accepts(abi.encodeCall(store.loosenMarketUsdCap, (M, USD_MAX)));
        assertEq(store.marketUsdCap(M), USD_MAX);
        address hub2 = makeAddr("hub2");
        registry.setHub(hub2, true);
        _accepts(abi.encodeCall(store.setInitialHubCaps, (hub2, USD_MAX - 1)));
        _accepts(abi.encodeCall(store.loosenDepositorUsdCap, (hub2, USD_MAX)));
        assertEq(store.depositorUsdCap(hub2), USD_MAX);
        _accepts(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, USD_MAX - 1)));
        _accepts(abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdt, USD_MAX)));
        assertEq(store.tokenUsdCap(hub2, usdt), USD_MAX);
    }

    // TEST-272 verifies: REQ-RISK-044, REQ-RISK-042
    function test_TEST_272_capTightenStopsAboveZero() public {
        _accepts(abi.encodeCall(store.tightenTopUpSliceUsd, (M, 0)));
        assertEq(store.topUpSliceUsd(M), 0);
        _accepts(abi.encodeCall(store.tightenMarketUsdCap, (M, 1)));
        assertEq(store.marketUsdCap(M), 1);
        _refuses(abi.encodeCall(store.tightenMarketUsdCap, (M, 0)), oob);
        _accepts(abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 1)));
        _refuses(abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 0)), oob);
        assertEq(store.tokenUsdCap(address(hub), usdc), 1);
        _accepts(abi.encodeCall(store.tightenDepositorUsdCap, (address(hub), 1)));
        _refuses(abi.encodeCall(store.tightenDepositorUsdCap, (address(hub), 0)), oob);
        assertEq(store.depositorUsdCap(address(hub)), 1);
    }

    // TEST-272 verifies: REQ-RISK-044, REQ-PSTORE-004
    function test_TEST_272_marketCapNeverBelowTheSlice() public {
        // Slice 500,000; the cap may fall to the slice but not one unit below it.
        _refuses(abi.encodeCall(store.tightenMarketUsdCap, (M, 500_000e8 - 1)), oob);
        _accepts(abi.encodeCall(store.tightenMarketUsdCap, (M, 500_000e8)));
        assertEq(store.marketUsdCap(M), 500_000e8);
        // And the slice may not rise above the cap.
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

    // ─── Grace, band, windows ───

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-049, INV-047
    function test_TEST_064_graceDurationAtBothEnds() public {
        _accepts(abi.encodeCall(store.setGraceDuration, (0)));
        assertEq(store.graceDuration(), 0);
        _accepts(abi.encodeCall(store.setGraceDuration, (7200)));
        assertEq(store.graceDuration(), 7200);
        _refuses(abi.encodeCall(store.setGraceDuration, (7201)), live);
        _refuses(abi.encodeCall(store.setGraceDuration, (type(uint32).max)), live);
        assertEq(store.graceDuration(), 7200);
        assertEq(store.graceDurationMax(), 7200);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-049, INV-047
    function test_TEST_064_graceHealthFactorAtBothEnds() public {
        _refuses(abi.encodeCall(store.setGraceHealthFactor, (0.9e18 - 1)), live);
        _accepts(abi.encodeCall(store.setGraceHealthFactor, (0.9e18)));
        assertEq(store.graceHealthFactor(), 0.9e18);
        _accepts(abi.encodeCall(store.setGraceHealthFactor, (1e18 - 1)));
        assertEq(store.graceHealthFactor(), 1e18 - 1);
        _refuses(abi.encodeCall(store.setGraceHealthFactor, (1e18)), live);
        _refuses(abi.encodeCall(store.setGraceHealthFactor, (0)), live);
        assertEq(store.graceHealthFactor(), 1e18 - 1);
        assertEq(store.graceHealthFactorMin(), 0.9e18);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-054, INV-047
    function test_TEST_064_disagreementPauseAtBothEnds() public {
        _accepts(abi.encodeCall(store.setDisagreementPauseMax, (0)));
        assertEq(store.disagreementPauseMax(), 0);
        _accepts(abi.encodeCall(store.setDisagreementPauseMax, (3600)));
        assertEq(store.disagreementPauseMax(), 3600);
        _refuses(abi.encodeCall(store.setDisagreementPauseMax, (3601)), live);
        assertEq(store.disagreementPauseMax(), 3600);
    }

    // TEST-064 verifies: REQ-CONFIG-050, REQ-CONFIG-054
    function test_TEST_064_cachedWindowAboveZero() public {
        _refuses(abi.encodeCall(store.setCachedWindow, (0)), oob);
        _accepts(abi.encodeCall(store.setCachedWindow, (1)));
        assertEq(store.cachedWindow(), 1);
        _accepts(abi.encodeCall(store.setCachedWindow, (type(uint32).max)));
        assertEq(store.cachedWindow(), type(uint32).max);
    }

    // TEST-064 verifies: REQ-CONFIG-055, REQ-CONFIG-049
    function test_TEST_064_usdBandAroundOneDollar() public {
        _accepts(abi.encodeCall(store.setUsdBand, (1e8 - 1, 1e8 + 1)));
        assertEq(store.usdBandLow(), 1e8 - 1);
        assertEq(store.usdBandHigh(), 1e8 + 1);
        _refuses(abi.encodeCall(store.setUsdBand, (1e8, 1.02e8)), oob);
        _refuses(abi.encodeCall(store.setUsdBand, (0.9e8, 1e8)), oob);
        _refuses(abi.encodeCall(store.setUsdBand, (1.02e8, 0.9e8)), oob);
        assertEq(store.usdBandLow(), 1e8 - 1);
        _accepts(abi.encodeCall(store.setUsdBand, (0, type(uint256).max)));
        assertEq(store.usdBandLow(), 0);
        assertEq(store.usdBandHigh(), type(uint256).max);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-CONFIG-050, REQ-CONFIG-052
    function test_TEST_250_agreementMarginAtBothEnds() public {
        // Tolerances are 150 and every route sums to 50, so margins up to 100 keep every token in bounds.
        _accepts(abi.encodeCall(store.setFeedAgreementMarginBps, (0)));
        assertEq(store.feedAgreementMarginBps(), 0);
        assertEq(store.feedAgreementToleranceMinBps(usdc), 50);
        _accepts(abi.encodeCall(store.setFeedAgreementMarginBps, (100)));
        assertEq(store.feedAgreementToleranceMinBps(usdc), 150);
        _refuses(abi.encodeCall(store.setFeedAgreementMarginBps, (101)), live);
        _refuses(abi.encodeCall(store.setFeedAgreementMarginBps, (10_001)), oob);
        assertEq(store.feedAgreementMarginBps(), 100);
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-CONFIG-050, REQ-CONFIG-052
    function test_TEST_250_agreementToleranceAtBothEnds() public {
        // Lower bound 25 + 25 + 50 = 100.
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 99)), live);
        _accepts(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 100)));
        assertEq(store.feedAgreementToleranceBps(usdc), 100);
        _accepts(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 10_000)));
        assertEq(store.feedAgreementToleranceBps(usdc), 10_000);
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 10_001)), oob);
        assertEq(store.feedAgreementToleranceBps(usdc), 10_000);
    }

    // ─── Spoke liquidation expectations ───

    // TEST-249 verifies: REQ-PSTORE-022, REQ-CONFIG-050
    function test_TEST_249_expectationsAtBothEnds() public {
        address s = address(spoke);
        _refuses(abi.encodeCall(store.setLiquidationExpectations, (s, 1e18, 200)), oob);
        _refuses(abi.encodeCall(store.setLiquidationExpectations, (s, 1.1e18, 199)), oob);
        _refuses(abi.encodeCall(store.setLiquidationExpectations, (s, 1.1e18, 10_000)), oob);
        assertEq(store.aaveTargetHealthFactor(s), 0);
        _accepts(abi.encodeCall(store.setLiquidationExpectations, (s, 1e18 + 1, 200)));
        assertEq(store.aaveTargetHealthFactor(s), 1e18 + 1);
        assertEq(store.minLiquidationBonus(s), 200);
        _accepts(abi.encodeCall(store.setLiquidationExpectations, (s, type(uint256).max, 9999)));
        assertEq(store.aaveTargetHealthFactor(s), type(uint256).max);
        assertEq(store.minLiquidationBonus(s), 9999);
    }

    // ─── Route depth thresholds ───

    // TEST-064 verifies: REQ-CONFIG-070, REQ-CONFIG-050
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
        _refuses(abi.encodeCall(store.tightenHardHealthFloor, (M, 0)), notStricter);
        _refuses(abi.encodeCall(store.tightenMinPledgeUsd, (M, 0)), notStricter);
        _refuses(abi.encodeCall(store.tightenGateRecoverySeconds, (0)), notStricter);
        _refuses(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 0)), notStricter);
        _refuses(abi.encodeCall(store.tightenMarketUsdCap, (M, USD_MAX + 1)), notStricter);
        _refuses(abi.encodeCall(store.tightenPoolShareMaxBps, (10_001)), notStricter);
        _refuses(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 100)), notStricter);
        _refuses(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 50)), notStricter);
        _refuses(abi.encodeCall(store.tightenPoolRiskFactor, (M, 4001)), notStricter);
    }

    // TEST-225 verifies: REQ-CONFIG-051, REQ-CONFIG-067, REQ-PSTORE-017
    function test_TEST_225_notLooserBeforeBoundsAndStep() public {
        _refuses(abi.encodeCall(store.loosenMaxShortfallBps, (0)), notLooser);
        _refuses(abi.encodeCall(store.loosenGateRecoverySeconds, (7201)), notLooser);
        _refuses(abi.encodeCall(store.loosenMarketUsdCap, (M, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenPoolShareMaxBps, (0)), notLooser);
        _refuses(abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenTopUpSliceUsd, (M, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenMinPledgeUsd, (M, USD_MAX)), notLooser);
        _refuses(abi.encodeCall(store.loosenHardHealthFloor, (M, 0)), notLooser);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-PSTORE-004, REQ-CONFIG-067
    function test_TEST_064_listingLivenessBeforeRange() public {
        // A consistency tolerance below 10 and a slippage of 10,000 together report the liveness failure first.
        MarketParams memory p = _params();
        p.consistencyToleranceBps = 9;
        p.slippageAllowanceBps = 10_000;
        (bool ok, bytes memory ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, live);
        p.consistencyToleranceBps = 50;
        p.slippageAllowanceMinBps = 10_001;
        (ok, ret) = _relist(p);
        assertFalse(ok);
        assertEq(ret, live);
    }
}
