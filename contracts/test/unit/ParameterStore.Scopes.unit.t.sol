// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {OracleInputsLayout} from "../../src/policy/parameter-store/types/OracleInputsLayout.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, OracleConfigReader, OracleConfigSummary} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice Scope checks of every keyed setter (market, Hub, token, feed, Spoke, debt reserve), the listing-only
/// setters against every market status, and the zero answers of every view for an unknown key (REQ-PSTORE-011).
contract ParameterStoreScopesUnitTest is ParameterStoreFixture {
    uint256 internal constant UNKNOWN = 77;
    address internal stray = makeAddr("strayHub");
    address internal unlisted = makeAddr("unlistedToken");
    address internal noFeed = makeAddr("noFeed");

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(data);
        assertFalse(ok, "unscoped write accepted");
        assertEq(ret, err, "wrong scope error");
    }

    function _unknownMarket() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.UnknownMarket.selector, UNKNOWN);
    }

    // ─── Markets ───

    // TEST-250 verifies: REQ-PSTORE-011
    function test_TEST_250_everyMarketSetterRefusesAnUnassignedId() public {
        bytes memory err = _unknownMarket();
        bytes[21] memory calls = [
            abi.encodeCall(store.tightenHardHealthFloor, (UNKNOWN, 1.1e18)),
            abi.encodeCall(store.tightenSlippageAllowanceBps, (UNKNOWN, 1)),
            abi.encodeCall(store.tightenConsistencyToleranceBps, (UNKNOWN, 10)),
            abi.encodeCall(store.tightenPoolRiskFactor, (UNKNOWN, 1)),
            abi.encodeCall(store.tightenRouteDepthThreshold, (UNKNOWN, usdc, gho, 0, 1)),
            abi.encodeCall(store.tightenMarketUsdCap, (UNKNOWN, 1)),
            abi.encodeCall(store.tightenTopUpSliceUsd, (UNKNOWN, 0)),
            abi.encodeCall(store.tightenMinPledgeUsd, (UNKNOWN, 1)),
            abi.encodeCall(store.tightenPoolShareMaxBpsOf, (UNKNOWN, 1)),
            abi.encodeCall(store.loosenHardHealthFloor, (UNKNOWN, 0)),
            abi.encodeCall(store.loosenSlippageAllowanceBps, (UNKNOWN, 1)),
            abi.encodeCall(store.loosenRouteDepthThreshold, (UNKNOWN, usdc, gho, 0, 1)),
            abi.encodeCall(store.loosenMarketUsdCap, (UNKNOWN, 1)),
            abi.encodeCall(store.loosenTopUpSliceUsd, (UNKNOWN, 1)),
            abi.encodeCall(store.loosenMinPledgeUsd, (UNKNOWN, 0)),
            abi.encodeCall(store.loosenPoolShareMaxBpsOf, (UNKNOWN, 1)),
            abi.encodeCall(store.setConsistencyToleranceBps, (UNKNOWN, 50)),
            abi.encodeCall(store.setTwapWindow, (UNKNOWN, 1800)),
            abi.encodeCall(store.setPoolRiskFactor, (UNKNOWN, 100)),
            abi.encodeCall(store.setSlippageAllowanceMinBps, (UNKNOWN, 0)),
            abi.encodeCall(store.setStressFloorUsd, (UNKNOWN, 1))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            _refuses(calls[i], err);
        }
        // Nothing was written under the unassigned id.
        MarketParams memory p = store.getMarketParams(UNKNOWN);
        assertEq(p.poolRiskFactor, 0);
        assertEq(p.hardHealthFloor, 0);
        assertEq(store.marketUsdCap(UNKNOWN), 0);
        assertEq(store.stressFloorUsd(UNKNOWN), 0);
        assertEq(store.routeDepthThreshold(UNKNOWN, usdc, gho, 0), 0);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-012, REQ-RISK-041, REQ-ACCESS-135
    function test_TEST_250_listingSettersOnlyWhileRegistered() public {
        MarketParams memory p = store.getMarketParams(M);
        bytes memory notInListing = abi.encodeWithSelector(IParameterStoreErrors.NotInListing.selector);
        MarketStatus[5] memory others = [
            MarketStatus.None,
            MarketStatus.Active,
            MarketStatus.Offboarding,
            MarketStatus.Cancelled,
            MarketStatus.Closed
        ];
        for (uint256 i = 0; i < others.length; ++i) {
            registry.setStatus(M, others[i]);
            _refuses(abi.encodeCall(store.setInitialMarketParams, (M, p)), notInListing);
            _refuses(abi.encodeCall(store.setInitialMarketCaps, (M, 1e8, 0, 1e8)), notInListing);
        }
        assertEq(store.marketUsdCap(M), 5_000_000e8);
        // Back to Registered, both run again.
        registry.setStatus(M, MarketStatus.Registered);
        vm.startPrank(address(timelock));
        store.setInitialMarketParams(M, p);
        store.setInitialMarketCaps(M, 1e8, 0, 1e8);
        vm.stopPrank();
        assertEq(store.marketUsdCap(M), 1e8);
    }

    // TEST-064 verifies: REQ-PSTORE-011, REQ-CONFIG-049
    function test_TEST_064_settersScopeEveryRecordedStatus() public {
        // A market that exists in any status other than None keeps its scope: values can still be tightened.
        MarketStatus[4] memory statuses =
            [MarketStatus.Active, MarketStatus.Offboarding, MarketStatus.Cancelled, MarketStatus.Closed];
        uint256 pledge = store.minPledgeUsd(M);
        for (uint256 i = 0; i < statuses.length; ++i) {
            registry.setStatus(M, statuses[i]);
            _tl();
            store.tightenMinPledgeUsd(M, pledge + 1);
            pledge += 1;
            assertEq(store.minPledgeUsd(M), pledge);
        }
    }

    // ─── Hubs ───

    // TEST-272 verifies: REQ-RISK-044, REQ-PSTORE-026, REQ-PSTORE-016
    function test_TEST_272_everyHubSetterRefusesAnUnrecordedHub() public {
        address[2] memory bad = [address(0), stray];
        for (uint256 j = 0; j < bad.length; ++j) {
            address h = bad[j];
            bytes memory err = abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, h);
            _refuses(abi.encodeCall(store.tightenTokenUsdCap, (h, usdc, 1)), err);
            _refuses(abi.encodeCall(store.tightenDepositorUsdCap, (h, 1)), err);
            _refuses(abi.encodeCall(store.loosenTokenUsdCap, (h, usdc, 1)), err);
            _refuses(abi.encodeCall(store.loosenDepositorUsdCap, (h, 1)), err);
            _refuses(abi.encodeCall(store.setInitialHubCaps, (h, 1)), err);
            _refuses(abi.encodeCall(store.setInitialTokenCap, (h, usdt, 1)), err);
            _refuses(abi.encodeCall(store.tightenBreakerDeficitMax, (h, gho, 0)), err);
            _refuses(abi.encodeCall(store.loosenBreakerDeficitMax, (h, gho, 1)), err);
            assertEq(store.depositorUsdCap(h), 0);
            assertEq(store.tokenUsdCap(h, usdt), 0);
        }
    }

    // TEST-272 verifies: REQ-RISK-044, REQ-PSTORE-026
    function test_TEST_272_hubForgottenByTheRegistryLosesItsSetters() public {
        registry.setHub(address(hub), false);
        bytes memory err = abi.encodeWithSelector(IParameterStoreErrors.UnknownHub.selector, address(hub));
        _refuses(abi.encodeCall(store.tightenDepositorUsdCap, (address(hub), 1)), err);
        _refuses(abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 1)), err);
        // Its stored caps are kept and still served.
        assertEq(store.depositorUsdCap(address(hub)), 1_000_000e8);
        assertEq(store.tokenUsdCap(address(hub), usdc), 20_000_000e8);
    }

    // TEST-272 verifies: REQ-RISK-041, REQ-PSTORE-012, REQ-PSTORE-026, REQ-ACCESS-135
    function test_TEST_272_initialTokenCapChecksTokenThenHubThenSlot() public {
        // Unlisted token first, even under an unrecorded Hub.
        _refuses(
            abi.encodeCall(store.setInitialTokenCap, (stray, unlisted, 1)),
            abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, unlisted)
        );
        // A pair that already has a cap is no longer in listing.
        _refuses(
            abi.encodeCall(store.setInitialTokenCap, (address(hub), usdc, 1)),
            abi.encodeWithSelector(IParameterStoreErrors.NotInListing.selector)
        );
        // An already-capped Hub refuses a second depositor cap.
        _refuses(
            abi.encodeCall(store.setInitialHubCaps, (address(hub), 1)),
            abi.encodeWithSelector(IParameterStoreErrors.NotInListing.selector)
        );
        assertEq(store.tokenUsdCap(address(hub), usdc), 20_000_000e8);
        assertEq(store.depositorUsdCap(address(hub)), 1_000_000e8);
    }

    // ─── Tokens ───

    // TEST-250 verifies: REQ-CONFIG-019, REQ-PSTORE-028, REQ-PSTORE-020, REQ-CONFIG-050
    function test_TEST_250_everyTokenSetterRefusesAnUnlistedToken() public {
        bytes memory err = abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, unlisted);
        SecondSource memory none;
        DebtReserveParams memory dp = DebtReserveParams(1);
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (unlisted, 500)), err);
        _refuses(abi.encodeCall(store.setTokenCollateralFactorBps, (unlisted, 5000)), err);
        _refuses(abi.encodeCall(store.setSecondSource, (unlisted, none, none)), err);
        _refuses(abi.encodeCall(store.tightenDebtStressRiseBps, (unlisted, 500)), err);
        _refuses(abi.encodeCall(store.setInitialTokenCap, (address(hub), unlisted, 1)), err);
        // No approved debt reserve uses the asset either.
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (unlisted, 1)), err);
        _refuses(abi.encodeCall(store.setDebtAssetParams, (unlisted, dp)), err);
        assertEq(store.tokenCollateralFactorBps(unlisted), 0);
        assertEq(store.feedAgreementToleranceBps(unlisted), 0);
        assertEq(store.debtStressRiseBps(unlisted), 0);
        assertEq(store.floorRoundingAllowance(unlisted), 0);
    }

    // TEST-246 verifies: REQ-CONFIG-050, REQ-PSTORE-006
    function test_TEST_246_allowanceNeedsAnApprovedReserveOfTheAsset() public {
        // usdt is listed but no approved debt reserve lends it.
        bytes memory err = abi.encodeWithSelector(IParameterStoreErrors.TokenNotListed.selector, usdt);
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (usdt, 1)), err);
        _refuses(abi.encodeCall(store.setDebtAssetParams, (usdt, DebtReserveParams(1))), err);
        // A reserve of the asset that is recorded but not approved does not count.
        DebtReserveDef memory d = registry.getDebtReserve(address(spoke), 1);
        d.reserveId = 2;
        d.asset = usdt;
        d.decimals = 6;
        d.approved = false;
        registry.setDebtReserve(address(spoke), d);
        _refuses(abi.encodeCall(store.loosenFloorRoundingAllowance, (usdt, 1)), err);
        d.approved = true;
        registry.setDebtReserve(address(spoke), d);
        _tl();
        store.loosenFloorRoundingAllowance(usdt, 1e6);
        assertEq(store.floorRoundingAllowance(usdt), 1e6);
    }

    // TEST-064 verifies: REQ-CONFIG-051, REQ-CONFIG-067
    function test_TEST_064_unwrittenAssetValuesHaveNoDirectionToMove() public {
        // An asset with no allowance or stress rise has nothing to tighten (allowance) or loosen (stress rise).
        bytes memory notStricter = abi.encodeWithSelector(IParameterStoreErrors.NotStricter.selector);
        bytes memory notLooser = abi.encodeWithSelector(IParameterStoreErrors.NotLooser.selector);
        _refuses(abi.encodeCall(store.tightenFloorRoundingAllowance, (unlisted, 0)), notStricter);
        _refuses(abi.encodeCall(store.tightenFloorRoundingAllowance, (unlisted, 1)), notStricter);
        _refuses(abi.encodeCall(store.loosenDebtStressRiseBps, (unlisted, 0)), notLooser);
        _refuses(abi.encodeCall(store.loosenDebtStressRiseBps, (unlisted, 100)), notLooser);
        _refuses(abi.encodeCall(store.tightenBreakerDeficitMax, (address(hub), unlisted, 0)), notStricter);
    }

    // ─── Feeds ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-CONFIG-023
    function test_TEST_250_everyFeedSetterRefusesAnUndefinedFeed() public {
        bytes memory err = abi.encodeWithSelector(IParameterStoreErrors.UnknownFeed.selector, noFeed);
        _refuses(abi.encodeCall(store.tightenBorrowPriceMaxAge, (noFeed, 1)), err);
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (noFeed, 1)), err);
        _refuses(abi.encodeCall(store.setLiquidationPriceMaxAge, (noFeed, 88_200)), err);
        _refuses(abi.encodeCall(store.setFeedMaxAge, (noFeed, 88_200)), err);
        FeedDef memory d = store.getFeed(noFeed);
        assertEq(d.feedHeartbeat, 0);
        assertEq(d.borrowPriceMaxAge, 0);
        assertEq(store.heartbeatMargin(noFeed), 0);
    }

    // ─── Spokes and debt reserves ───

    // TEST-249 verifies: REQ-PSTORE-022
    function test_TEST_249_expectationsNeedAnApprovedSpoke() public {
        address[2] memory bad = [address(0), makeAddr("unapprovedSpoke")];
        for (uint256 i = 0; i < bad.length; ++i) {
            _refuses(
                abi.encodeCall(store.setLiquidationExpectations, (bad[i], 1.1e18, 200)),
                abi.encodeWithSelector(IParameterStoreErrors.UnknownSpoke.selector, bad[i])
            );
            assertEq(store.aaveTargetHealthFactor(bad[i]), 0);
        }
    }

    // TEST-228 verifies: REQ-PSTORE-016
    function test_TEST_228_deficitLoosenNeedsAReserveFundedByTheHub() public {
        bytes memory err = abi.encodeWithSelector(IParameterStoreErrors.UnknownDebtReserve.selector, address(0), 0);
        address hub2 = makeAddr("hub2");
        registry.setHub(hub2, true);
        // The GHO reserve is funded by `hub`, not `hub2`.
        _refuses(abi.encodeCall(store.loosenBreakerDeficitMax, (hub2, gho, 1)), err);
        // No reserve lends USDT.
        _refuses(abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), usdt, 1)), err);
        // An unapproved reserve does not count.
        DebtReserveDef memory d = registry.getDebtReserve(address(spoke), 1);
        d.approved = false;
        registry.setDebtReserve(address(spoke), d);
        _refuses(abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), gho, 1)), err);
        d.approved = true;
        registry.setDebtReserve(address(spoke), d);
        _tl();
        store.loosenBreakerDeficitMax(address(hub), gho, 1);
        assertEq(store.breakerDeficitMax(address(hub), gho), 1);
        assertEq(store.breakerDeficitMax(hub2, gho), 0);
    }

    // ─── Views for unknown keys ───

    // TEST-250 verifies: REQ-PSTORE-011, REQ-CONFIG-072, REQ-PSTORE-033
    function test_TEST_250_viewsAnswerZeroForUnknownKeys() public view {
        assertEq(store.marketUsdCap(UNKNOWN), 0);
        assertEq(store.topUpSliceUsd(UNKNOWN), 0);
        assertEq(store.stressFloorUsd(UNKNOWN), 0);
        assertEq(store.minPledgeUsd(UNKNOWN), 0);
        assertEq(store.hardHealthFloor(UNKNOWN), 0);
        assertEq(store.slippageAllowanceMinBps(UNKNOWN), 0);
        assertEq(store.twapMinObservations(UNKNOWN), 0);
        assertEq(store.tokenUsdCap(stray, unlisted), 0);
        assertEq(store.depositorUsdCap(stray), 0);
        assertEq(store.tokenCollateralFactorBps(unlisted), 0);
        assertEq(store.feedAgreementToleranceBps(unlisted), 0);
        assertEq(store.borrowPriceMaxAge(noFeed), 0);
        assertEq(store.liquidationPriceMaxAge(noFeed), 0);
        assertEq(store.floorRoundingAllowance(unlisted), 0);
        assertEq(store.debtAssetParams(unlisted).floorRoundingAllowance, 0);
        assertEq(store.breakerDeficitMax(stray, unlisted), 0);
        assertEq(store.debtStressRiseBps(unlisted), 0);
        assertEq(store.aaveTargetHealthFactor(stray), 0);
        assertEq(store.minLiquidationBonus(stray), 0);
        assertEq(store.lastLoosenedAt(keccak256("unknown")), 0);
        assertFalse(store.onStandby(unlisted));
        SecondSource memory s = store.secondSource(unlisted);
        assertEq(uint8(s.kind), uint8(SecondSourceKind.None));
        assertEq(s.source, address(0));
        assertEq(store.standbySecondSource(unlisted).toleranceBps, 0);
        // An unknown pool key falls back to the chain default; no key can exceed it.
        assertEq(store.poolShareMaxBpsOf(keccak256("unknown pool")), store.poolShareMaxBps());
        // The bound of an unlisted token is the bare margin: no route feeds into it.
        assertEq(store.feedAgreementToleranceMinBps(unlisted), store.feedAgreementMarginBps());
        assertFalse(store.liquidationLivenessHolds(address(spoke), UNKNOWN, 1));
    }

    // TEST-250 verifies: REQ-PSTORE-011, REQ-CONFIG-072
    function test_TEST_250_oracleConfigOfAnUnknownOracleIsEmpty() public {
        OracleConfigReader reader = new OracleConfigReader();
        (bool ok, bytes memory raw) =
            address(store).staticcall(abi.encodeCall(store.getOracleConfig, (makeAddr("notAnOracle"))));
        assertTrue(ok);
        (bool done, bytes memory ret) = address(reader).staticcall(bytes.concat(reader.summary.selector, raw));
        assertTrue(done);
        OracleConfigSummary memory s = abi.decode(ret, (OracleConfigSummary));
        assertEq(s.marketId, 0);
        assertEq(s.tokenCount, 0);
        assertEq(s.maxQuoteChangeBps, 0);
        assertEq(s.usdBandLow, 0);
        assertEq(s.cachedWindow, 0);
    }

    // TEST-250 verifies: REQ-PSTORE-033, REQ-PSTORE-011
    function test_TEST_250_oracleInputsOfAnUnknownOracleAreZeroWords() public view {
        address[] memory toks = new address[](3);
        (toks[0], toks[1], toks[2]) = (usdc, usdt, unlisted);
        uint256[] memory w = store.getOracleInputs(address(0xdead), toks, true);
        uint256 stride = OracleInputsLayout.TOKEN_WORDS + OracleInputsLayout.SECOND_WORDS;
        assertEq(w.length, OracleInputsLayout.HEAD_WORDS + 3 * stride);
        for (uint256 i = 0; i < w.length; ++i) {
            assertEq(w[i], 0, "unknown oracle served a word");
        }
        uint256[] memory bare = store.getOracleInputs(address(0xdead), new address[](0), false);
        assertEq(bare.length, OracleInputsLayout.HEAD_WORDS);
    }

    // TEST-250 verifies: REQ-PSTORE-011, REQ-PSTORE-033
    function test_TEST_250_oracleInputsServeUnlistedTokensAsZeroLegs() public view {
        // A token the market does not hold gets its stored values (none) and no legs, never a revert.
        address[] memory toks = new address[](1);
        toks[0] = unlisted;
        uint256[] memory w = store.getOracleInputs(address(lpOracle), toks, true);
        assertEq(w[0], M);
        uint256 k = OracleInputsLayout.HEAD_WORDS;
        for (uint256 i = k; i < w.length; ++i) {
            assertEq(w[i], 0, "unlisted token served a word");
        }
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-PSTORE-011
    function test_TEST_250_feedViewsAfterDefinition() public {
        MockAggregator f = new MockAggregator(8, 1e6, 1e12);
        _tl();
        store.setFeed(address(f), _feedDef(3600, 600));
        assertEq(store.heartbeatMargin(address(f)), 600);
        assertEq(store.borrowPriceMaxAge(address(f)), 4200);
        assertEq(store.liquidationPriceMaxAge(address(f)), 4200);
        FeedDef memory d = store.getFeed(address(f));
        assertEq(d.feedMaxAge, 4200);
        assertEq(d.decimals, 8);
        assertEq(d.minAnswer, 1e6);
        assertEq(d.maxAnswer, 1e12);
    }
}
