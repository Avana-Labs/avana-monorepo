// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator, MockLPOracle} from "../utils/mocks/ParameterStoreMocks.sol";

/// @notice An LPOracle whose `checkConfig` answers with fixed raw bytes, or reverts: malformed answers.
contract RawAnswerLPOracle {
    bytes internal _answer;
    bool internal _reverts;

    function set(
        bytes memory answer,
        bool reverts
    ) external {
        (_answer, _reverts) = (answer, reverts);
    }

    fallback(
        bytes calldata
    ) external returns (bytes memory) {
        require(!_reverts, "raw");
        return _answer;
    }
}

/// @notice An LPOracle failing check 32 when a token's second source in force is `bad`, and reverting when the
/// consistency tolerance falls below `revertBelow`.
contract ConfigReadingLPOracle {
    address public bad;
    uint16 public revertBelow;

    function setBad(
        address b
    ) external {
        bad = b;
    }

    function setRevertBelow(
        uint16 v
    ) external {
        revertBelow = v;
    }

    function checkConfig(
        OracleConfig calldata c
    ) external view returns (uint256 bits) {
        require(c.consistencyToleranceBps >= revertBelow, "below");
        for (uint256 i = 0; i < c.tokens.length; ++i) {
            if (bad != address(0) && c.tokens[i].secondSource.source == bad) bits |= 32;
        }
    }
}

/// @notice The `checkConfig` re-runs of REQ-PSTORE-009: which LPOracles a change affects (every configured market
/// for a chain value, those holding the token for a token value, those whose recorded routes or second sources use
/// the feed for a feed value), the zero bitmap structural setters require, the new-failures-only rule of the three
/// tightenings that re-run it, and malformed answers counting as every check failing.
contract ParameterStoreCheckConfigUnitTest is ParameterStoreFixture {
    uint256 internal constant M2 = 2;
    uint256 internal constant ALL = type(uint256).max;
    address internal dai = makeAddr("DAI");
    MockAggregator internal fDai;
    MockAggregator internal fDaiAlt;
    MockLPOracle internal oracle2;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        // Market 2 holds USDT and DAI: USDT is shared, USDC is only in market 1, DAI only in market 2.
        fDai = new MockAggregator(8, 1e6, 1e12);
        fDaiAlt = new MockAggregator(8, 1e6, 1e12);
        registry.setToken(dai, _one(address(fDai)), _one(address(fDaiAlt)), new address[](0));
        oracle2 = new MockLPOracle();
        _setMarket2(address(oracle2), MarketStatus.Registered);
        vm.startPrank(address(timelock));
        store.setFeedAgreementToleranceBps(dai, 150);
        store.setFeed(address(fDai), _feedDef(86_400, 1800));
        store.setFeed(address(fDaiAlt), _feedDef(86_400, 1800));
        vm.stopPrank();
    }

    function _setMarket2(
        address oracle,
        MarketStatus status
    ) internal {
        Market memory m = registry.getMarket(M);
        m.pool = makeAddr("pool2");
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (usdt, dai);
        m.vaultToken = makeAddr("vaultToken2");
        m.lpOracle = oracle;
        m.status = status;
        registry.setMarket(M2, m);
    }

    function _rejected(
        address oracle,
        uint256 bits
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, oracle, bits);
    }

    function _refuses(
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(data);
        assertFalse(ok, "change accepted against a failing configuration");
        assertEq(ret, err, "wrong rejection");
    }

    function _accepts(
        bytes memory data
    ) internal {
        vm.prank(address(timelock));
        (bool ok,) = address(store).call(data);
        assertTrue(ok, "change refused");
    }

    // ─── Affected set: chain values reach every configured market ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-013, REQ-CONFIG-054
    function test_TEST_250_chainValuesRecheckEveryConfiguredMarket() public {
        oracle2.setFailed(2);
        bytes[6] memory chain = [
            abi.encodeCall(store.setCachedWindow, (1800)),
            abi.encodeCall(store.setDisagreementPauseMax, (1800)),
            abi.encodeCall(store.setUsdBand, (0.95e8, 1.05e8)),
            abi.encodeCall(store.setGraceDuration, (900)),
            abi.encodeCall(store.setFeedAgreementMarginBps, (40)),
            abi.encodeCall(store.setSequencer, (address(0), 0))
        ];
        for (uint256 i = 0; i < chain.length; ++i) {
            _refuses(chain[i], _rejected(address(oracle2), 2));
        }
        assertEq(store.cachedWindow(), 3600);
        assertEq(store.graceDuration(), 1800);
        // With market 2 cancelled it is no longer affected and every chain value goes through.
        registry.setStatus(M2, MarketStatus.Cancelled);
        for (uint256 i = 0; i < chain.length; ++i) {
            _accepts(chain[i]);
        }
        assertEq(store.cachedWindow(), 1800);
        assertEq(store.usdBandLow(), 0.95e8);
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-011
    function test_TEST_250_affectedStatusesAreRegisteredActiveOffboarding() public {
        oracle2.setFailed(1);
        MarketStatus[3] memory configured = [MarketStatus.Registered, MarketStatus.Active, MarketStatus.Offboarding];
        for (uint256 i = 0; i < configured.length; ++i) {
            registry.setStatus(M2, configured[i]);
            _refuses(abi.encodeCall(store.setCachedWindow, (uint32(1000 + i))), _rejected(address(oracle2), 1));
        }
        MarketStatus[2] memory gone = [MarketStatus.Cancelled, MarketStatus.Closed];
        for (uint256 i = 0; i < gone.length; ++i) {
            registry.setStatus(M2, gone[i]);
            _accepts(abi.encodeCall(store.setCachedWindow, (uint32(2000 + i))));
            assertEq(store.cachedWindow(), 2000 + i);
        }
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-013
    function test_TEST_250_firstFailingMarketIsNamed() public {
        lpOracle.setFailed(4);
        oracle2.setFailed(8);
        _refuses(abi.encodeCall(store.setCachedWindow, (100)), _rejected(address(lpOracle), 4));
        lpOracle.setFailed(0);
        _refuses(abi.encodeCall(store.setCachedWindow, (100)), _rejected(address(oracle2), 8));
    }

    // ─── Token values reach the markets holding the token ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-CONFIG-024
    function test_TEST_250_tokenValuesRecheckOnlyItsMarkets() public {
        oracle2.setFailed(1);
        // USDC is only in market 1: the failing market 2 is not affected.
        _accepts(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 200)));
        assertEq(store.feedAgreementToleranceBps(usdc), 200);
        // DAI and USDT are in market 2.
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (dai, 200)), _rejected(address(oracle2), 1));
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdt, 200)), _rejected(address(oracle2), 1));
        assertEq(store.feedAgreementToleranceBps(dai), 150);
        // The same split for a failure of market 1.
        oracle2.setFailed(0);
        lpOracle.setFailed(1);
        _accepts(abi.encodeCall(store.setFeedAgreementToleranceBps, (dai, 200)));
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdt, 200)), _rejected(address(lpOracle), 1));
    }

    // ─── Feed values reach the markets whose tokens use the feed ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-CONFIG-023
    function test_TEST_250_feedValuesRecheckMarketsUsingTheFeed() public {
        oracle2.setFailed(1);
        // fUsdc is in USDC's routes only; fDai in DAI's.
        _accepts(abi.encodeCall(store.setBorrowPriceMaxAge, (address(fUsdc), 4200)));
        assertEq(store.borrowPriceMaxAge(address(fUsdc)), 4200);
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (address(fDai), 4200)), _rejected(address(oracle2), 1));
        _refuses(
            abi.encodeCall(store.setLiquidationPriceMaxAge, (address(fDai), 88_200)), _rejected(address(oracle2), 1)
        );
        _refuses(abi.encodeCall(store.setFeedMaxAge, (address(fDaiAlt), 88_200)), _rejected(address(oracle2), 1));
        _accepts(abi.encodeCall(store.setFeedMaxAge, (address(fUsdcAlt), 88_200)));
        // A feed no route uses affects no market.
        MockAggregator lone = new MockAggregator(8, 1e6, 1e12);
        _accepts(abi.encodeCall(store.setFeed, (address(lone), _feedDef(3600, 600))));
        _accepts(abi.encodeCall(store.setBorrowPriceMaxAge, (address(lone), 1)));
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-MREG-027
    function test_TEST_250_standbyRouteFeedCountsAsUsed() public {
        // A feed recorded only as USDC's standby route still affects market 1.
        MockAggregator standbyFeed = new MockAggregator(8, 1e6, 1e12);
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), _one(address(standbyFeed)));
        _tl();
        store.setFeed(address(standbyFeed), _feedDef(86_400, 1800));
        lpOracle.setFailed(2);
        _refuses(
            abi.encodeCall(store.setBorrowPriceMaxAge, (address(standbyFeed), 4200)), _rejected(address(lpOracle), 2)
        );
        assertEq(store.borrowPriceMaxAge(address(standbyFeed)), 88_200);
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-028, REQ-PSTORE-029
    function test_TEST_250_secondSourceFeedsCountAsUsed() public {
        MockAggregator recorded = new MockAggregator(8, 1e6, 1e12);
        MockAggregator standby = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(recorded), _feedDef(86_400, 1800));
        store.setFeed(address(standby), _feedDef(86_400, 1800));
        store.setSecondSource(
            dai,
            SecondSource(SecondSourceKind.OracleNetwork, address(recorded), bytes32(0), 88_200, 0, 100),
            SecondSource(SecondSourceKind.OracleNetwork, address(standby), bytes32(0), 88_200, 0, 100)
        );
        vm.stopPrank();
        oracle2.setFailed(1);
        // Both the recorded and the standby second-source feed of DAI reach market 2, whichever is in force.
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (address(recorded), 4200)), _rejected(address(oracle2), 1));
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (address(standby), 4200)), _rejected(address(oracle2), 1));
        // Market 1 holds no DAI: its failure does not block the same change.
        oracle2.setFailed(0);
        lpOracle.setFailed(1);
        _accepts(abi.encodeCall(store.setBorrowPriceMaxAge, (address(standby), 4200)));
    }

    // ─── Market values reach their own market while configured ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-CONFIG-054, REQ-PSTORE-027
    function test_TEST_250_marketValuesRecheckOnlyWhileConfigured() public {
        lpOracle.setFailed(1);
        _refuses(abi.encodeCall(store.setConsistencyToleranceBps, (M, 60)), _rejected(address(lpOracle), 1));
        _refuses(abi.encodeCall(store.setTwapWindow, (M, 1200)), _rejected(address(lpOracle), 1));
        // The failing market 1 does not affect market 2's own values.
        _accepts(abi.encodeCall(store.setConsistencyToleranceBps, (M2, 60)));
        // A cancelled market has no LPOracle to answer to.
        registry.setStatus(M, MarketStatus.Cancelled);
        _accepts(abi.encodeCall(store.setConsistencyToleranceBps, (M, 60)));
        _accepts(abi.encodeCall(store.setTwapWindow, (M, 1200)));
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 20)));
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 20);
        assertEq(store.getMarketParams(M).twapWindow, 1200);
    }

    // TEST-250 verifies: REQ-PSTORE-004, REQ-PSTORE-009, REQ-PSTORE-013
    function test_TEST_250_listingRequiresAZeroBitmap() public {
        MarketParams memory p = store.getMarketParams(M);
        lpOracle.setFailed(1 << 200);
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(abi.encodeCall(store.setInitialMarketParams, (M, p)));
        assertFalse(ok);
        assertEq(ret, _rejected(address(lpOracle), 1 << 200));
    }

    // ─── Values the LPOracle does not read run no re-check ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-CONFIG-072
    function test_TEST_250_valuesOutsideTheOracleConfigNeverRecheck() public {
        lpOracle.setFailed(ALL);
        oracle2.setFailed(ALL);
        vm.startPrank(address(timelock));
        store.setGraceHealthFactor(0.92e18);
        store.setAvanaFeeShareBps(1000);
        store.setCoverageRatioBps(2000);
        store.setMaxFlashFeeBps(20);
        store.setPoolRiskFactor(M, 3000);
        store.setTokenCollateralFactorBps(usdc, 7000);
        store.setSlippageAllowanceMinBps(M, 40);
        store.setStressFloorUsd(M, 2e8);
        store.tightenMarketUsdCap(M, 4_000_000e8);
        store.loosenMinPledgeUsd(M, 5e8);
        store.tightenMaxShortfallBps(10);
        vm.stopPrank();
        assertEq(store.graceHealthFactor(), 0.92e18);
        assertEq(store.getMarketParams(M).poolRiskFactor, 3000);
        assertEq(store.minPledgeUsd(M), 5e8);
    }

    // ─── Structural setters need a zero bitmap; tightenings only no new failure ───

    // TEST-064 verifies: REQ-PSTORE-009, REQ-CONFIG-051, SPEC-GOV-011
    // A tightening of market 2 re-runs market 2's LPOracle, the last of the two slots it lays out.
    function test_TEST_064_tighteningRechecksTheSecondMarket() public {
        _accepts(abi.encodeCall(store.setConsistencyToleranceBps, (M2, 60)));
        oracle2.setFloors(50, 0, 0);
        _refuses(abi.encodeCall(store.tightenConsistencyToleranceBps, (M2, 40)), _rejected(address(oracle2), 4));
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M2, 50)));
        assertEq(store.getMarketParams(M2).consistencyToleranceBps, 50);
    }

    // TEST-064 verifies: REQ-PSTORE-009, REQ-CONFIG-051, SPEC-GOV-011
    function test_TEST_064_structuralVersusTightenOnAnOldFailure() public {
        // Check 1 already fails at market 1 and no write breaks anything else.
        lpOracle.setFailed(1);
        _refuses(abi.encodeCall(store.setBorrowPriceMaxAge, (address(fUsdc), 4200)), _rejected(address(lpOracle), 1));
        _accepts(abi.encodeCall(store.tightenBorrowPriceMaxAge, (address(fUsdc), 4200)));
        _refuses(abi.encodeCall(store.setConsistencyToleranceBps, (M, 40)), _rejected(address(lpOracle), 1));
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 40)));
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 120)), _rejected(address(lpOracle), 1));
        _accepts(abi.encodeCall(store.tightenFeedAgreementToleranceBps, (usdc, 120)));
        assertEq(store.borrowPriceMaxAge(address(fUsdc)), 4200);
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 40);
        assertEq(store.feedAgreementToleranceBps(usdc), 120);
    }

    // TEST-064 verifies: REQ-PSTORE-009, REQ-CONFIG-051, SPEC-GOV-011
    function test_TEST_064_tightenNamesOnlyTheChecksItAdds() public {
        // Market 2 already fails 1 and 8. Market 1's check 8 reads token 0 (USDC) against a floor of 130: tightening
        // USDC to 120 newly fails it there, and market 1 alone is named with check 8 alone.
        oracle2.setFailed(1 | 8);
        lpOracle.setFloors(0, 130, 0);
        _refuses(abi.encodeCall(store.tightenFeedAgreementToleranceBps, (usdc, 120)), _rejected(address(lpOracle), 8));
        // USDT is in both markets: market 2 already failed 1 and 8, and market 1's check 8 reads USDC, which did not
        // move, so no check is new and the tightening runs.
        _accepts(abi.encodeCall(store.tightenFeedAgreementToleranceBps, (usdt, 120)));
        // Borrow age: market 1 newly fails 16, and the old 1 is not counted.
        lpOracle.setFailed(1);
        lpOracle.setFloors(0, 0, 4000);
        _refuses(
            abi.encodeCall(store.tightenBorrowPriceMaxAge, (address(fUsdc), 3999)), _rejected(address(lpOracle), 16)
        );
        _accepts(abi.encodeCall(store.tightenBorrowPriceMaxAge, (address(fUsdc), 4000)));
    }

    // TEST-064 verifies: REQ-PSTORE-009, REQ-CONFIG-051
    function test_TEST_064_tightenRevertingAfterWriteIsEveryCheck() public {
        // An LPOracle that answers before the write and reverts after it counts every check as newly failed.
        ConfigReadingLPOracle reading = new ConfigReadingLPOracle();
        reading.setRevertBelow(45);
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(reading);
        registry.setMarket(M, m);
        _refuses(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 44)), _rejected(address(reading), ALL));
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 45)));
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 45);
    }

    // ─── Malformed answers count as every check failing ───

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-013
    function test_TEST_250_malformedAnswersFailEveryCheck() public {
        RawAnswerLPOracle raw = new RawAnswerLPOracle();
        Market memory m = registry.getMarket(M2);
        m.lpOracle = address(raw);
        registry.setMarket(M2, m);
        bytes[4] memory answers =
            [bytes(""), abi.encodePacked(uint128(0)), abi.encode(uint256(0), uint256(0)), bytes(hex"00")];
        for (uint256 i = 0; i < answers.length; ++i) {
            raw.set(answers[i], false);
            _refuses(abi.encodeCall(store.setCachedWindow, (100)), _rejected(address(raw), ALL));
        }
        raw.set(abi.encode(uint256(0)), true);
        _refuses(abi.encodeCall(store.setCachedWindow, (100)), _rejected(address(raw), ALL));
        // Exactly one zero word is a pass.
        raw.set(abi.encode(uint256(0)), false);
        _accepts(abi.encodeCall(store.setCachedWindow, (100)));
        // One non-zero word is that bitmap.
        raw.set(abi.encode(uint256(64)), false);
        _refuses(abi.encodeCall(store.setCachedWindow, (200)), _rejected(address(raw), 64));
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-013, REQ-PSTORE-014
    function test_TEST_250_oracleWithoutCodeFailsEveryCheck() public {
        address eoa = makeAddr("oracleEoa");
        Market memory m = registry.getMarket(M2);
        m.lpOracle = eoa;
        registry.setMarket(M2, m);
        _refuses(abi.encodeCall(store.setCachedWindow, (100)), _rejected(eoa, ALL));
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (dai, 200)), _rejected(eoa, ALL));
        assertEq(store.cachedWindow(), 3600);
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-014
    function test_TEST_250_unbuildableConfigFailsEveryCheck() public {
        // A registry read the configuration needs reverts: the store cannot build what it would serve, so every check
        // counts as failed and the change is refused.
        vm.mockCallRevert(
            address(registry), abi.encodeWithSignature("activePriceRoutes(address)", usdc), "registry down"
        );
        _refuses(abi.encodeCall(store.setCachedWindow, (100)), _rejected(address(lpOracle), ALL));
        // Market 2 holds no USDC and is built without that read; only market 1 is named.
        _refuses(abi.encodeCall(store.setFeedAgreementToleranceBps, (usdt, 200)), _rejected(address(lpOracle), ALL));
        _accepts(abi.encodeCall(store.setFeedAgreementToleranceBps, (dai, 200)));
        // A tightening on that market is not blocked by a failure that predates it.
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 40)));
        assertEq(store.getMarketParams(M).consistencyToleranceBps, 40);
    }

    // ─── Second-source checks run with each source in force ───

    // TEST-250 verifies: REQ-PSTORE-029, REQ-PSTORE-009
    function test_TEST_250_secondSourceCheckedWithTheStandbyInForce() public {
        ConfigReadingLPOracle reading = new ConfigReadingLPOracle();
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(reading);
        registry.setMarket(M, m);
        MockAggregator a = new MockAggregator(8, 1e6, 1e12);
        MockAggregator b = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(a), _feedDef(86_400, 1800));
        store.setFeed(address(b), _feedDef(86_400, 1800));
        vm.stopPrank();
        SecondSource memory sa = SecondSource(SecondSourceKind.OracleNetwork, address(a), bytes32(0), 88_200, 0, 100);
        SecondSource memory sb = SecondSource(SecondSourceKind.OracleNetwork, address(b), bytes32(0), 88_200, 0, 100);
        // The LPOracle rejects b: a source b is refused, and so is a standby b although it is not in force.
        reading.setBad(address(b));
        _refuses(abi.encodeCall(store.setSecondSource, (usdc, sb, sa)), _rejected(address(reading), 32));
        _refuses(abi.encodeCall(store.setSecondSource, (usdc, sa, sb)), _rejected(address(reading), 32));
        assertEq(store.secondSource(usdc).source, address(0));
        reading.setBad(address(0));
        _accepts(abi.encodeCall(store.setSecondSource, (usdc, sa, sb)));
        assertFalse(store.onStandby(usdc));
        assertEq(store.secondSource(usdc).source, address(a));
    }

    // TEST-250 verifies: REQ-PSTORE-029, REQ-PSTORE-009, EMG-103
    function test_TEST_250_restoreRechecksTheRecordedSource() public {
        ConfigReadingLPOracle reading = new ConfigReadingLPOracle();
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(reading);
        registry.setMarket(M, m);
        MockAggregator a = new MockAggregator(8, 1e6, 1e12);
        MockAggregator b = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(a), _feedDef(86_400, 1800));
        store.setFeed(address(b), _feedDef(86_400, 1800));
        store.setSecondSource(
            usdc,
            SecondSource(SecondSourceKind.OracleNetwork, address(a), bytes32(0), 88_200, 0, 100),
            SecondSource(SecondSourceKind.OracleNetwork, address(b), bytes32(0), 88_200, 0, 100)
        );
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        // The recorded source has since failed the LPOracle's check: the restore is refused and the standby stays.
        reading.setBad(address(a));
        _refuses(abi.encodeCall(store.restoreSecondSource, (usdc)), _rejected(address(reading), 32));
        assertTrue(store.onStandby(usdc));
        assertEq(store.secondSource(usdc).source, address(b));
        // The guardian's switch itself runs no LPOracle check: it only puts a reviewed standby in force.
        reading.setBad(address(0));
        _accepts(abi.encodeCall(store.restoreSecondSource, (usdc)));
        assertEq(store.secondSource(usdc).source, address(a));
    }

    // TEST-250 verifies: REQ-PSTORE-009, REQ-PSTORE-029
    function test_TEST_250_guardianSwitchRunsCheckConfig() public {
        MockAggregator a = new MockAggregator(8, 1e6, 1e12);
        MockAggregator b = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(a), _feedDef(86_400, 1800));
        store.setFeed(address(b), _feedDef(86_400, 1800));
        store.setSecondSource(
            usdc,
            SecondSource(SecondSourceKind.OracleNetwork, address(a), bytes32(0), 88_200, 0, 100),
            SecondSource(SecondSourceKind.OracleNetwork, address(b), bytes32(0), 88_200, 0, 100)
        );
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
        // The switch re-runs checkConfig with the standby in force: a failing LPOracle refuses it.
        lpOracle.setFailed(ALL);
        vm.prank(emergencyGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.OracleConfigRejected.selector, address(lpOracle), ALL)
        );
        store.useStandbySecondSource(usdc);
        assertFalse(store.onStandby(usdc));
        lpOracle.setFailed(0);
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        assertTrue(store.onStandby(usdc));
    }

    // ─── Feed-agreement bound is re-checked before checkConfig ───

    // TEST-250 verifies: REQ-CONFIG-024, REQ-CONFIG-052, REQ-PSTORE-009
    function test_TEST_250_setFeedReportsTheToleranceBoundFirst() public {
        // A raise of fDai's threshold to 80 bps puts DAI's bound at 80 + 25 + 50 = 155 > 150: LivenessBound, even
        // though market 2's LPOracle also fails.
        oracle2.setFailed(1);
        _refuses(
            abi.encodeCall(store.setFeed, (address(fDai), _withDeviation(80))),
            abi.encodeWithSelector(IParameterStoreErrors.LivenessBound.selector)
        );
        // At 75 bps the bound is 150 and holds: the LPOracle's failure is then the error.
        _refuses(abi.encodeCall(store.setFeed, (address(fDai), _withDeviation(75))), _rejected(address(oracle2), 1));
        oracle2.setFailed(0);
        _accepts(abi.encodeCall(store.setFeed, (address(fDai), _withDeviation(75))));
        assertEq(store.feedAgreementToleranceMinBps(dai), 150);
    }

    function _withDeviation(
        uint16 dev
    ) internal pure returns (FeedDef memory d) {
        d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = dev;
    }
}
