// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, OracleConfigReader, OracleConfigSummary} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Fuzz twins of the ParameterStore's rules: each setter's outcome (accepted, or refused with its exact
/// error) against an independent model of its bounds, step and liveness rules over the whole input range, and the
/// view formulas against their integer definitions.
contract ParameterStoreFuzzTest is ParameterStoreFixture {
    uint256 internal constant USD_MAX = type(uint128).max;

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _oob() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.OutOfBounds.selector);
    }

    function _live() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector);
    }

    function _notStricter() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.NotStricter.selector);
    }

    function _notLooser() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.NotLooser.selector);
    }

    function _call(
        bytes memory data
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(data);
    }

    /// @dev Asserts the call's outcome equals the model's: success, or failure with exactly `err`.
    function _expect(
        bytes memory data,
        bytes memory err
    ) internal {
        (bool ok, bytes memory ret) = _call(data);
        if (err.length == 0) {
            assertTrue(ok, "model accepts, store refused");
        } else {
            assertFalse(ok, "model refuses, store accepted");
            assertEq(ret, err, "wrong error");
        }
    }

    function _key(
        bytes32 name,
        bytes32 scope
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(name, scope));
    }

    // ─── Tighten setters ───

    // TEST-064 verifies: REQ-PSTORE-031, REQ-CONFIG-050, REQ-CONFIG-051, REQ-CONFIG-067
    function testFuzz_TEST_064_tightenHardFloorModel(
        uint256 start,
        uint256 v
    ) public {
        start = bound(start, 0, 2);
        uint256 old = start == 0 ? 0 : (start == 1 ? 1e18 : 1.2e18);
        if (old != 0) assertTrue(_ok(abi.encodeCall(store.tightenHardHealthFloor, (M, old))));
        v = bound(v, 0, 2e18);
        bytes memory err = v <= old ? _notStricter() : (v < 1e18 || v > 1.25e18 ? _oob() : bytes(""));
        _expect(abi.encodeCall(store.tightenHardHealthFloor, (M, v)), err);
        assertEq(store.hardHealthFloor(M), err.length == 0 ? v : old);
    }

    // TEST-064 verifies: REQ-CONFIG-052, REQ-PSTORE-015, INV-047
    function testFuzz_TEST_064_tightenSlippageModel(
        uint16 minBps,
        uint16 v
    ) public {
        minBps = uint16(bound(minBps, 0, 100));
        assertTrue(_ok(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, minBps))));
        bytes memory err = v >= 100 ? _notStricter() : (v < minBps ? _live() : bytes(""));
        _expect(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, v)), err);
        uint16 stored = store.getMarketParams(M).slippageAllowanceBps;
        assertGe(stored, store.slippageAllowanceMinBps(M), "allowance below its floor");
    }

    // TEST-064 verifies: REQ-CONFIG-052, SPEC-GOV-009, INV-047
    function testFuzz_TEST_064_consistencyModel(
        uint16 v,
        bool tighten
    ) public {
        bytes memory err;
        if (tighten) {
            err = v >= 50 ? _notStricter() : (v < 10 ? _live() : bytes(""));
            _expect(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, v)), err);
        } else {
            err = v < 10 ? _live() : (v > 10_000 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.setConsistencyToleranceBps, (M, v)), err);
        }
        uint16 stored = store.getMarketParams(M).consistencyToleranceBps;
        assertGe(stored, 10);
        assertLe(stored, 10_000);
        assertEq(stored, err.length == 0 ? v : 50);
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, PROP-042
    function testFuzz_TEST_272_tightenMarketCapModel(
        uint256 v
    ) public {
        uint256 old = store.marketUsdCap(M);
        uint256 slice = store.topUpSliceUsd(M);
        bytes memory err = v >= old ? _notStricter() : (v == 0 || v < slice ? _oob() : bytes(""));
        _expect(abi.encodeCall(store.tightenMarketUsdCap, (M, v)), err);
        assertGe(store.marketUsdCap(M), store.topUpSliceUsd(M), "cap below slice");
        assertGt(store.marketUsdCap(M), 0);
    }

    // TEST-272 verifies: REQ-RISK-042, REQ-RISK-044, REQ-PSTORE-026
    function testFuzz_TEST_272_tightenHubCapsModel(
        uint256 v,
        bool depositor
    ) public {
        address h = address(hub);
        uint256 old = depositor ? store.depositorUsdCap(h) : store.tokenUsdCap(h, usdc);
        bytes memory err = v >= old ? _notStricter() : (v == 0 ? _oob() : bytes(""));
        bytes memory data = depositor
            ? abi.encodeCall(store.tightenDepositorUsdCap, (h, v))
            : abi.encodeCall(store.tightenTokenUsdCap, (h, usdc, v));
        _expect(data, err);
        uint256 now_ = depositor ? store.depositorUsdCap(h) : store.tokenUsdCap(h, usdc);
        assertEq(now_, err.length == 0 ? v : old);
    }

    // TEST-064 verifies: REQ-PSTORE-005, REQ-CONFIG-051, PROP-042
    function testFuzz_TEST_064_minPledgeBothWaysModel(
        uint256 v,
        bool tighten
    ) public {
        uint256 old = store.minPledgeUsd(M);
        bytes memory err;
        if (tighten) {
            err = v <= old ? _notStricter() : (v > 100_000e8 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.tightenMinPledgeUsd, (M, v)), err);
        } else {
            err = v >= old ? _notLooser() : bytes("");
            _expect(abi.encodeCall(store.loosenMinPledgeUsd, (M, v)), err);
        }
        assertLe(store.minPledgeUsd(M), 100_000e8);
        assertEq(store.minPledgeUsd(M), err.length == 0 ? v : old);
    }

    // TEST-064 verifies: REQ-PSTORE-030, REQ-PSTORE-018, REQ-PSTORE-024, PROP-042
    function testFuzz_TEST_064_chainScalarsModel(
        uint64 gate,
        uint16 shortfall,
        uint16 flash,
        uint8 which
    ) public {
        which = uint8(bound(which, 0, 5));
        bytes memory err;
        if (which == 0) {
            err = gate <= 1800 ? _notStricter() : (gate > 7200 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.tightenGateRecoverySeconds, (gate)), err);
        } else if (which == 1) {
            err = gate >= 1800 ? _notLooser() : (gate < 600 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.loosenGateRecoverySeconds, (gate)), err);
        } else if (which == 2) {
            err = shortfall >= 1000 ? _notStricter() : bytes("");
            _expect(abi.encodeCall(store.tightenMaxShortfallBps, (shortfall)), err);
        } else if (which == 3) {
            err = shortfall <= 1000 ? _notLooser() : (shortfall > 5000 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.loosenMaxShortfallBps, (shortfall)), err);
        } else if (which == 4) {
            err = flash >= 10 ? _notStricter() : bytes("");
            _expect(abi.encodeCall(store.tightenMaxFlashFeeBps, (flash)), err);
        } else {
            // No _live() market: a raise has no pair to re-check.
            err = flash > 100 ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setMaxFlashFeeBps, (flash)), err);
        }
        assertGe(store.gateRecoverySeconds(), 600);
        assertLe(store.gateRecoverySeconds(), 7200);
        assertLe(store.maxShortfallBps(), 5000);
        assertLe(store.maxFlashFeeBps(), 100);
    }

    // TEST-230 verifies: REQ-PSTORE-020, REQ-CONFIG-050
    function testFuzz_TEST_230_stressRiseModel(
        uint16 first,
        uint16 next,
        bool tighten
    ) public {
        bytes memory err = first == 0 ? _notStricter() : (first < 100 || first > 5000 ? _oob() : bytes(""));
        _expect(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, first)), err);
        uint16 old = store.debtStressRiseBps(usdc);
        if (tighten) {
            err = next <= old ? _notStricter() : (next < 100 || next > 5000 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, next)), err);
        } else {
            err = next >= old ? _notLooser() : (next < 100 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.loosenDebtStressRiseBps, (usdc, next)), err);
        }
        uint16 stored = store.debtStressRiseBps(usdc);
        assertTrue(stored == 0 || (stored >= 100 && stored <= 5000), "stress rise out of range");
    }

    // TEST-272 verifies: REQ-RISK-042, SPEC-CAP-005, Q-383
    function testFuzz_TEST_272_poolShareOfIsMinOfOverrideAndDefault(
        uint16 dflt,
        uint16 over
    ) public {
        dflt = uint16(bound(dflt, 1, 10_000));
        over = uint16(bound(over, 1, 10_000));
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        if (over < 10_000) assertTrue(_ok(abi.encodeCall(store.tightenPoolShareMaxBpsOf, (M, over))));
        if (dflt < 10_000) assertTrue(_ok(abi.encodeCall(store.tightenPoolShareMaxBps, (dflt))));
        uint256 expected = over < 10_000 && over < dflt ? over : dflt;
        assertEq(store.poolShareMaxBpsOf(key), expected);
        assertLe(store.poolShareMaxBpsOf(key), store.poolShareMaxBps(), "pool above the default");
    }

    // ─── Loosen setters: step, ceiling ───

    // TEST-225 verifies: REQ-PSTORE-017, REQ-RISK-043, REQ-RISK-044
    function testFuzz_TEST_225_capLoosenModel(
        uint256 old,
        uint256 v,
        uint8 which
    ) public {
        which = uint8(bound(which, 0, 2));
        old = bound(old, 1, USD_MAX);
        address hub2 = makeAddr("hub2");
        registry.setHub(hub2, true);
        bytes memory data;
        bytes32 key;
        if (which == 0) {
            assertTrue(_ok(abi.encodeCall(store.setInitialMarketCaps, (M, old, 0, 1))));
            data = abi.encodeCall(store.loosenMarketUsdCap, (M, v));
            key = _key("marketUsdCap", bytes32(M));
        } else if (which == 1) {
            assertTrue(_ok(abi.encodeCall(store.setInitialHubCaps, (hub2, old))));
            data = abi.encodeCall(store.loosenDepositorUsdCap, (hub2, v));
            key = _key("depositorUsdCap", bytes32(uint256(uint160(hub2))));
        } else {
            assertTrue(_ok(abi.encodeCall(store.setInitialTokenCap, (hub2, usdt, old))));
            data = abi.encodeCall(store.loosenTokenUsdCap, (hub2, usdt, v));
            key = _key("tokenUsdCap", keccak256(abi.encode(hub2, usdt)));
        }
        bytes memory err;
        if (v <= old) {
            err = _notLooser();
        } else if (v > USD_MAX) {
            err = _oob();
        } else if (v * 10_000 > old * 15_000) {
            err = abi.encodeWithSelector(IParameterStoreErrors.LoosenStepTooLarge.selector, key);
        }
        _expect(data, err);
    }

    // TEST-225 verifies: REQ-PSTORE-017
    function testFuzz_TEST_225_sliceLoosenModel(
        uint256 cap,
        uint256 slice,
        uint256 v
    ) public {
        cap = bound(cap, 1, USD_MAX);
        slice = bound(slice, 0, cap);
        assertTrue(_ok(abi.encodeCall(store.setInitialMarketCaps, (M, cap, slice, 1))));
        v = bound(v, 0, USD_MAX + 1);
        uint256 base = cap / 10 > slice ? cap / 10 : slice;
        bytes memory err;
        if (v <= slice) {
            err = _notLooser();
        } else if (v > cap) {
            err = _oob();
        } else if (v * 10_000 > base * 15_000) {
            err = abi.encodeWithSelector(
                IParameterStoreErrors.LoosenStepTooLarge.selector, _key("topUpSliceUsd", bytes32(M))
            );
        }
        _expect(abi.encodeCall(store.loosenTopUpSliceUsd, (M, v)), err);
        assertLe(store.topUpSliceUsd(M), store.marketUsdCap(M));
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-PSTORE-031, Q-398
    function testFuzz_TEST_225_hardFloorLoosenModel(
        uint256 old,
        uint256 v
    ) public {
        old = bound(old, 1e18, 1.25e18);
        assertTrue(_ok(abi.encodeCall(store.tightenHardHealthFloor, (M, old))));
        v = bound(v, 0, 1.3e18);
        uint256 stored = v < 1e18 ? 0 : v;
        uint256 effective = stored == 0 ? 1e18 : stored;
        bytes memory err;
        if (v >= old) {
            err = _notLooser();
        } else if (old - effective > 0.03e18) {
            err = abi.encodeWithSelector(
                IParameterStoreErrors.LoosenStepTooLarge.selector, _key("hardHealthFloor", bytes32(M))
            );
        }
        _expect(abi.encodeCall(store.loosenHardHealthFloor, (M, v)), err);
        uint256 got = store.hardHealthFloor(M);
        assertEq(got, err.length == 0 ? stored : old);
        assertTrue(got == 0 || (got >= 1e18 && got <= 1.25e18), "floor out of range");
    }

    // TEST-225 verifies: REQ-PSTORE-017, REQ-CONFIG-071
    function testFuzz_TEST_225_slippageLoosenModel(
        uint16 v
    ) public {
        bytes memory err;
        if (v <= 100) {
            err = _notLooser();
        } else if (v >= 10_000) {
            err = _oob();
        } else if (v > 125) {
            err = abi.encodeWithSelector(
                IParameterStoreErrors.LoosenStepTooLarge.selector, _key("slippageAllowanceBps", bytes32(M))
            );
        }
        _expect(abi.encodeCall(store.loosenSlippageAllowanceBps, (M, v)), err);
    }

    // ─── Structural setters ───

    // TEST-064 verifies: REQ-CONFIG-052, REQ-CONFIG-055, PROP-042
    function testFuzz_TEST_064_graceBandWindowsModel(
        uint256 hf,
        uint32 duration,
        uint32 pause,
        uint256 low,
        uint256 high
    ) public {
        _expect(abi.encodeCall(store.setGraceHealthFactor, (hf)), hf < 0.9e18 || hf >= 1e18 ? _live() : bytes(""));
        _expect(abi.encodeCall(store.setGraceDuration, (duration)), duration > 7200 ? _live() : bytes(""));
        _expect(abi.encodeCall(store.setDisagreementPauseMax, (pause)), pause > 3600 ? _live() : bytes(""));
        _expect(abi.encodeCall(store.setUsdBand, (low, high)), low >= 1e8 || high <= 1e8 ? _oob() : bytes(""));
        assertGe(store.graceHealthFactor(), 0.9e18);
        assertLt(store.graceHealthFactor(), 1e18);
        assertLe(store.graceDuration(), 7200);
        assertLe(store.disagreementPauseMax(), 3600);
        assertLt(store.usdBandLow(), 1e8);
        assertGt(store.usdBandHigh(), 1e8);
    }

    // TEST-064 verifies: REQ-CONFIG-015, REQ-CONFIG-019, REQ-PSTORE-010, REQ-PSTORE-032
    function testFuzz_TEST_064_bpsSettersModel(
        uint16 v,
        uint8 which
    ) public {
        which = uint8(bound(which, 0, 4));
        bytes memory err;
        if (which == 0) {
            err = v > 5000 ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setAvanaFeeShareBps, (v)), err);
            assertLe(store.avanaFeeShareBps(), 5000);
        } else if (which == 1) {
            err = v > 10_000 ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setCoverageRatioBps, (v)), err);
            assertLe(store.coverageRatioBps(), 10_000);
        } else if (which == 2) {
            // Lowering never re-runs the margin; a raise keeps a wide margin with these routes (sum 50 bps).
            err = v == 0 || v > 4000 ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setPoolRiskFactor, (M, v)), err);
        } else if (which == 3) {
            err = v == 0 || v > 9999 ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, v)), err);
        } else {
            uint256 min = store.feedAgreementToleranceMinBps(usdc);
            err = v < min ? _live() : (v > 10_000 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, v)), err);
            assertGe(store.feedAgreementToleranceBps(usdc), min);
        }
    }

    // TEST-250 verifies: REQ-CONFIG-023, REQ-CONFIG-052
    function testFuzz_TEST_250_feedAgeSettersModel(
        uint32 v,
        uint8 which
    ) public {
        which = uint8(bound(which, 0, 3));
        address f = address(fUsdc);
        uint32 formula = 88_200;
        bytes memory err;
        if (which == 0) {
            err = v == 0 || v > formula ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setBorrowPriceMaxAge, (f, v)), err);
        } else if (which == 1) {
            err = v >= formula ? _notStricter() : (v == 0 ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.tightenBorrowPriceMaxAge, (f, v)), err);
        } else if (which == 2) {
            err = v < formula ? _live() : (v > formula ? _oob() : bytes(""));
            _expect(abi.encodeCall(store.setLiquidationPriceMaxAge, (f, v)), err);
        } else {
            err = v != formula ? _oob() : bytes("");
            _expect(abi.encodeCall(store.setFeedMaxAge, (f, v)), err);
        }
        FeedDef memory d = store.getFeed(f);
        assertLe(d.borrowPriceMaxAge, d.liquidationPriceMaxAge, "borrow age above liquidation age");
        assertGt(d.borrowPriceMaxAge, 0);
        assertEq(d.liquidationPriceMaxAge, uint256(d.feedHeartbeat) + d.heartbeatMargin);
        assertEq(d.feedMaxAge, uint256(d.feedHeartbeat) + d.heartbeatMargin);
    }

    // TEST-249 verifies: REQ-PSTORE-022
    function testFuzz_TEST_249_expectationsModel(
        uint256 target,
        uint16 bonus
    ) public {
        bytes memory err = target <= 1e18 || bonus < 200 || bonus >= 10_000 ? _oob() : bytes("");
        _expect(abi.encodeCall(store.setLiquidationExpectations, (address(spoke), target, bonus)), err);
        if (err.length == 0) {
            assertEq(store.aaveTargetHealthFactor(address(spoke)), target);
            assertEq(store.minLiquidationBonus(address(spoke)), bonus);
        }
    }

    // TEST-246 verifies: REQ-CONFIG-050, Q-397
    function testFuzz_TEST_246_roundingAllowanceWorthAtMostOneDollar(
        int256 price,
        uint8 decimals,
        uint256 v
    ) public {
        decimals = uint8(bound(decimals, 0, 40));
        price = bound(price, -1, 1e20);
        ghoPrice.setAnswer(price);
        DebtReserveDef memory d = registry.getDebtReserve(address(spoke), 1);
        d.decimals = decimals;
        registry.setDebtReserve(address(spoke), d);
        v = bound(v, 0, 1e40);
        uint256 p = price > 0 ? uint256(price) : type(uint256).max;
        bool ok = v != 0 && decimals <= 36 && v <= (1e8 * 10 ** uint256(decimals)) / p;
        // Direction first: 0 is never looser than the unwritten 0.
        bytes memory err = v == 0 ? _notLooser() : (ok ? bytes("") : _oob());
        _expect(abi.encodeCall(store.loosenFloorRoundingAllowance, (gho, v)), err);
        if (ok) {
            // Exact integer form of "worth at most $1": v × price ≤ 10⁸ × 10^decimals.
            assertLe(v * p, 1e8 * 10 ** uint256(decimals));
        }
    }

    // TEST-246 verifies: REQ-CONFIG-050
    function testFuzz_TEST_246_highestReservePriceBindsTheAllowance(
        uint256 p1,
        uint256 p2
    ) public {
        p1 = bound(p1, 1, 1e12);
        p2 = bound(p2, 1, 1e12);
        // A second approved GHO reserve on another Spoke prices the asset with its own source.
        address spoke2 = makeAddr("spoke2");
        registry.setSpoke(spoke2, address(hub));
        ghoPrice.setAnswer(int256(p1));
        DebtReserveDef memory d = registry.getDebtReserve(address(spoke), 1);
        d.priceSource = address(new PriceAnswer(int256(p2)));
        registry.setDebtReserve(spoke2, d);
        uint256 maxP = p1 > p2 ? p1 : p2;
        uint256 limit = 1e26 / maxP;
        if (limit == 0) return;
        _expect(abi.encodeCall(store.loosenFloorRoundingAllowance, (gho, limit)), bytes(""));
        assertEq(store.floorRoundingAllowance(gho), limit);
        assertTrue(!_ok(abi.encodeCall(store.loosenFloorRoundingAllowance, (gho, limit + 1))));
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-024, REQ-CONFIG-052
    function testFuzz_TEST_245_flashRaiseOnALiveMarketModel(
        uint32 maxLb,
        uint16 factor,
        uint16 sMin,
        uint16 f
    ) public {
        maxLb = uint32(bound(maxLb, 9000, 12_000));
        factor = uint16(bound(factor, 0, 10_000));
        sMin = uint16(bound(sMin, 0, 100));
        f = uint16(bound(f, 11, 100));
        assertTrue(_ok(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, sMin))));
        spoke.setBonus(maxLb, factor);
        _activate();
        uint256 minLb = maxLb < 10_000 ? 0 : 10_000 + ((uint256(maxLb) - 10_000) * factor) / 10_000;
        bool holds = minLb * (10_000 - uint256(sMin)) >= 10_000 * (10_000 + uint256(f));
        _expect(abi.encodeCall(store.setMaxFlashFeeBps, (f)), holds ? bytes("") : _live());
        assertEq(store.liquidationLivenessHolds(address(spoke), M, 1), holds || _inequality(minLb, sMin, 10));
        // A lowering never re-checks.
        assertTrue(_ok(abi.encodeCall(store.tightenMaxFlashFeeBps, (0))));
    }

    // TEST-245 verifies: REQ-PSTORE-021, REQ-PSTORE-015, REQ-CONFIG-041
    function testFuzz_TEST_245_floorRaiseOnALiveMarketModel(
        uint32 maxLb,
        uint16 v
    ) public {
        maxLb = uint32(bound(maxLb, 10_000, 11_000));
        spoke.setBonus(maxLb, 4000);
        _activate();
        uint256 minLb = 10_000 + ((uint256(maxLb) - 10_000) * 4000) / 10_000;
        bytes memory err;
        if (v > 100) err = _live();
        else if (v > 30 && !_inequality(minLb, v, 10)) err = _live();
        _expect(abi.encodeCall(store.setSlippageAllowanceMinBps, (M, v)), err);
        // Whatever the outcome, a _live() market with an enabled reserve never holds a raised floor that fails.
        uint16 stored = store.slippageAllowanceMinBps(M);
        if (stored > 30) assertTrue(_inequality(minLb, stored, 10));
    }

    function _inequality(
        uint256 minLb,
        uint256 sMin,
        uint256 f
    ) internal pure returns (bool) {
        if (sMin >= 10_000 || f >= 10_000) return false;
        return minLb * (10_000 - sMin) >= 10_000 * (10_000 + f);
    }

    // ─── Views against their definitions ───

    // TEST-250 verifies: REQ-PSTORE-027, SPEC-ORC-022
    function testFuzz_TEST_250_twapMinObservationsFormula(
        uint32 window
    ) public {
        window = uint32(bound(window, 1, 786_408));
        pool.setCardinality(type(uint16).max);
        assertTrue(_ok(abi.encodeCall(store.setTwapWindow, (M, window))));
        uint256 expected = (uint256(window) + 11) / 12 + 1;
        assertEq(store.twapMinObservations(M), expected);
        // The pool must hold exactly that many: one fewer is refused.
        pool.setCardinality(uint16(expected - 1));
        _expect(abi.encodeCall(store.setTwapWindow, (M, window)), _oob());
    }

    // TEST-250 verifies: REQ-CONFIG-024, REQ-MREG-027
    function testFuzz_TEST_250_toleranceMinFormula(
        uint16 p,
        uint16 a,
        uint16 s,
        uint16 margin
    ) public {
        p = uint16(bound(p, 1, 3000));
        a = uint16(bound(a, 1, 3000));
        s = uint16(bound(s, 1, 3000));
        margin = uint16(bound(margin, 0, 1000));
        MockAggregator fp = new MockAggregator(8, 1e6, 1e12);
        MockAggregator fa = new MockAggregator(8, 1e6, 1e12);
        MockAggregator fs = new MockAggregator(8, 1e6, 1e12);
        address tok = makeAddr("fuzzToken");
        registry.setToken(tok, _one(address(fp)), _one(address(fa)), _one(address(fs)));
        vm.startPrank(address(timelock));
        store.setFeedAgreementToleranceBps(tok, 10_000);
        // The market's own tokens keep their bound under any margin up to 1,000.
        store.setFeedAgreementToleranceBps(usdc, 10_000);
        store.setFeedAgreementToleranceBps(usdt, 10_000);
        store.setFeedAgreementMarginBps(margin);
        store.setFeed(address(fp), _dev(p));
        store.setFeed(address(fa), _dev(a));
        store.setFeed(address(fs), _dev(s));
        vm.stopPrank();
        uint256 pair = uint256(p) + a;
        if (uint256(s) + a > pair) pair = uint256(s) + a;
        if (uint256(p) + s > pair) pair = uint256(p) + s;
        assertEq(store.feedAgreementToleranceMinBps(tok), pair + margin);
    }

    function _dev(
        uint16 dev
    ) internal pure returns (FeedDef memory d) {
        d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = dev;
        d.heartbeatDriftBps = 0;
    }

    // TEST-250 verifies: REQ-PSTORE-033
    function testFuzz_TEST_250_oracleInputsLength(
        uint8 n,
        bool withSecond
    ) public view {
        n = uint8(bound(n, 0, 8));
        address[] memory toks = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            toks[i] = i % 2 == 0 ? usdc : usdt;
        }
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, withSecond);
        assertEq(w.length, 10 + uint256(n) * (37 + (withSecond ? 9 : 0)));
        assertEq(OracleInputsLayout.TOKEN_WORDS, 37);
        if (n > 0) assertEq(w[OracleInputsLayout.HEAD_WORDS], 150);
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-CONFIG-072, REQ-ORACLE-049
    function testFuzz_TEST_250_pinnedAndSaturatedMaxAnswer(
        int192 aggMax,
        int256 cap
    ) public {
        aggMax = int192(bound(aggMax, 1e6 + 1, type(int192).max));
        cap = bound(cap, 1e6 + 1, type(int256).max);
        fUsdc.setBounds(8, 1e6, aggMax);
        FeedDef memory d = _feedDef(86_400, 1800);
        d.maxAnswerCap = cap;
        assertTrue(_ok(abi.encodeCall(store.setFeed, (address(fUsdc), d))));
        int256 pinned = cap < aggMax ? cap : int256(aggMax);
        assertEq(store.getFeed(address(fUsdc)).maxAnswer, pinned);
        // The OracleConfig leg saturates into int128; the inputs word keeps the full value.
        OracleConfigReader reader = new OracleConfigReader();
        (bool ok, bytes memory raw) =
            address(store).staticcall(abi.encodeCall(store.getOracleConfig, (address(lpOracle))));
        assertTrue(ok);
        (bool done, bytes memory out) = address(reader).staticcall(bytes.concat(reader.summary.selector, raw));
        assertTrue(done);
        OracleConfigSummary memory s = abi.decode(out, (OracleConfigSummary));
        assertEq(int256(s.maxAnswer00), pinned > type(int128).max ? int256(type(int128).max) : pinned);
        address[] memory toks = new address[](1);
        toks[0] = usdc;
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, false);
        assertEq(int256(w[OracleInputsLayout.HEAD_WORDS + 5 + 3]), pinned);
    }

    // TEST-250 verifies: REQ-CONFIG-022, Q-191
    function testFuzz_TEST_250_minAnswerNormalisationModel(
        uint8 decimals,
        int192 minAnswer
    ) public {
        decimals = uint8(bound(decimals, 1, 18));
        minAnswer = int192(bound(minAnswer, -1e20, 1e30));
        MockAggregator f = new MockAggregator(decimals, minAnswer, type(int192).max);
        bytes memory err;
        if (minAnswer <= 0) {
            err = abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, address(f), bytes32("minAnswer"));
        } else {
            uint256 m = uint256(int256(minAnswer));
            uint256 normalised = decimals >= 8 ? (m * 1e8) / 10 ** decimals : m * 10 ** (8 - decimals);
            if (normalised == 0) {
                err = abi.encodeWithSelector(
                    IParameterStoreErrors.InvalidFeed.selector, address(f), bytes32("minAnswer")
                );
            }
        }
        _expect(abi.encodeCall(store.setFeed, (address(f), _feedDef(3600, 600))), err);
    }

    // TEST-225 verifies: REQ-PSTORE-017, SPEC-GOV-011
    function testFuzz_TEST_225_spacingForAnyGap(
        uint256 gap
    ) public {
        gap = bound(gap, 0, 2 * NORMAL_DELAY);
        bytes32 key = _key("depositorUsdCap", bytes32(uint256(uint160(address(hub)))));
        uint256 t = block.timestamp;
        assertTrue(_ok(abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_100_000e8))));
        vm.warp(t + gap);
        bytes memory err = gap < NORMAL_DELAY
            ? abi.encodeWithSelector(IParameterStoreErrors.LoosenTooSoon.selector, key, t + NORMAL_DELAY)
            : bytes("");
        _expect(abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_200_000e8)), err);
        assertEq(store.lastLoosenedAt(key), gap < NORMAL_DELAY ? t : t + gap);
    }

    function _ok(
        bytes memory data
    ) internal returns (bool ok) {
        (ok,) = _call(data);
    }
}

/// @notice An Aave price source answering a fixed value.
contract PriceAnswer {
    int256 public latestAnswer;

    constructor(
        int256 a
    ) {
        latestAnswer = a;
    }
}
