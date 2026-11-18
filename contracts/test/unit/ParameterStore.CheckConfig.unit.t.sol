// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {FeedDef, MarketParams} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {Market} from "../../src/types/MarketTypes.sol";
import {OracleConfig, SecondSource, SecondSourceKind} from "../../src/types/OracleTypes.sol";
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
        return abi.encodeWithSelector(IParameterStoreBase.OracleConfigRejected.selector, oracle, bits);
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

    // ─── Token values reach the markets holding the token ───

    // ─── Feed values reach the markets whose tokens use the feed ───

    // ─── Market values reach their own market while configured ───

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

    // ─── Malformed answers count as every check failing ───

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

    // ─── Second-source checks run with each source in force ───

    // ─── Feed-agreement bound is re-checked before checkConfig ───

    function _withDeviation(
        uint16 dev
    ) internal pure returns (FeedDef memory d) {
        d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = dev;
    }

    // TEST-064 verifies: REQ-PSTORE-009, REQ-CONFIG-051, SPEC-GOV-011
    /// @notice A tightening of a cancelled market re-runs no LPOracle: its oracle's refusal of the new tolerance does
    /// not block the write.
    function test_TEST_064_tighteningACancelledMarketRechecksNothing() public {
        _accepts(abi.encodeCall(store.setConsistencyToleranceBps, (M2, 60)));
        oracle2.setFloors(50, 0, 0);
        registry.setStatus(M2, MarketStatus.Cancelled);
        _accepts(abi.encodeCall(store.tightenConsistencyToleranceBps, (M2, 40)));
        assertEq(store.getMarketParams(M2).consistencyToleranceBps, 40);
    }
}
