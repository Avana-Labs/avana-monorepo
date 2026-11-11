// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../src/types/OracleLeg.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../src/types/TokenOracleConfig.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {OracleTokenMock} from "../utils/mocks/LPOracleMocks.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice The LPOracle base against the real ParameterStore: it decodes the store's `getOracleConfig` return data,
/// evaluates Live, and passes the store's own `checkConfig` re-checks when a parameter of its market changes.
contract LPOracleRealStoreUnitTest is ParameterStoreFixture {
    LPOracleHarness internal oracle;
    MockAggregator internal ssUsdc;
    MockAggregator internal ssUsdt;

    function setUp() public {
        _deployStore(false);
        _listMarket();
        fUsdc.setRound(1e8, 1);
        fUsdcAlt.setRound(1e8, 1);
        fUsdt.setRound(1e8, 1);
        fUsdtAlt.setRound(1e8, 1);
        ssUsdc = new MockAggregator(8, 1e6, 1e12);
        ssUsdt = new MockAggregator(8, 1e6, 1e12);
        ssUsdc.setRound(1e8, 1);
        ssUsdt.setRound(1e8, 1);
        vm.startPrank(address(timelock));
        store.setFeed(address(ssUsdc), _feedDef(86_400, 1800));
        store.setFeed(address(ssUsdt), _feedDef(86_400, 1800));
        SecondSource memory empty;
        store.setSecondSource(usdc, _second(address(ssUsdc)), empty);
        store.setSecondSource(usdt, _second(address(ssUsdt)), empty);
        vm.stopPrank();
        _etchToken(usdc);
        _etchToken(usdt);
        // The listing operators initialise the feed with the configuration the store serves for the market (built
        // here field by field: decoding the store's return into memory exceeds the legacy pipeline's stack).
        OracleConfig memory c = _expectedConfig();
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(address(timelock), BLOCK_TIME, 556_588, 3_000_000, false);
        oracle = LPOracleHarness(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (_params(c)))))
        );
        // Registration points the market at the new feed.
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(oracle);
        registry.setMarket(M, m);
    }

    function _expectedConfig() internal view returns (OracleConfig memory c) {
        c.marketId = M;
        c.twapWindow = 1800;
        c.twapMinObservations = 151;
        c.consistencyToleranceBps = 50;
        c.maxQuoteChangeBps = 100;
        c.usdBandLow = 0.9e8;
        c.usdBandHigh = 1.02e8;
        c.cachedWindow = 3600;
        c.disagreementPauseMax = 3600;
        c.graceDuration = 1800;
        c.tokens = new TokenOracleConfig[](2);
        c.tokens[0] = _token(usdc, address(fUsdc), address(fUsdcAlt), address(ssUsdc));
        c.tokens[1] = _token(usdt, address(fUsdt), address(fUsdtAlt), address(ssUsdt));
    }

    function _token(
        address token,
        address primary,
        address alternate,
        address second
    ) internal pure returns (TokenOracleConfig memory t) {
        t.token = token;
        t.routes[0].legCount = 1;
        t.routes[0].legs[0] = _leg(primary);
        t.routes[1].legCount = 1;
        t.routes[1].legs[0] = _leg(alternate);
        t.feedAgreementToleranceBps = 150;
        t.secondSource = _second(second);
    }

    function _leg(
        address feed
    ) internal pure returns (OracleLeg memory l) {
        l = OracleLeg(feed, 8, 86_400, 1800, 25, 1e6, 1e12, 88_200, 88_200);
    }

    function _second(
        address source
    ) internal pure returns (SecondSource memory s) {
        s = SecondSource(SecondSourceKind.OracleNetwork, source, bytes32(0), 88_200, 0, 100);
    }

    function _etchToken(
        address token
    ) internal {
        vm.etch(token, address(new OracleTokenMock(6)).code);
        // OracleTokenMock: slot 0 the misbehaviour map, slot 1 the decimals.
        vm.store(token, bytes32(uint256(1)), bytes32(uint256(6)));
    }

    function _params(
        OracleConfig memory c
    ) internal view returns (InitParams memory p) {
        p.timelock = address(timelock);
        p.parameterStore = address(store);
        p.marketRegistry = address(registry);
        p.marketId = M;
        p.integration = address(integration);
        p.isUsdStable = new bool[](2);
        (p.isUsdStable[0], p.isUsdStable[1]) = (true, true);
        p.description = "USDC/USDT / USD";
        p.pokeMinGas = 556_588;
        p.config = c;
        uint256[] memory k = new uint256[](2);
        (k[0], k[1]) = (1e18, 1e18);
        p.market = abi.encode(k);
    }

    // TEST-250 verifies: REQ-ORACLE-017, REQ-ORACLE-083, REQ-ORACLE-094, REQ-ORACLE-100, REQ-CONFIG-072, Q-240, Q-323
    // Sources: 5.1 TEST-250 (LPOracle part: the configuration read from the ParameterStore on every evaluation)
    function test_TEST_250_liveOnTheStoreConfiguration() public {
        uint256 g = gasleft();
        PriceStateView memory v = oracle.getPriceState();
        emit log_named_uint("getPriceState gas, 2 tokens, one-leg routes", g - gasleft());
        assertEq(uint8(v.state), uint8(PriceState.Live), "the store's configuration decodes and evaluates Live");
        assertEq(v.reasons & (1 << 1), 0, "no configuration failure");
        assertTrue(v.borrowAllowed, "second sources from the store confirm");
        assertEq(v.tokens[0].feedAgreementToleranceBps, 150);
        assertEq(v.consistencyToleranceBps, 50);
        assertEq(v.answer, int256(2 * 99_999_900));
        g = gasleft();
        oracle.latestAnswer();
        emit log_named_uint("latestAnswer gas", g - gasleft());
    }

    // TEST-250 verifies: REQ-ORACLE-083, REQ-ORACLE-046, REQ-ORACLE-077, REQ-PSTORE-009, Q-227, Q-228
    function test_TEST_250_storeRecheckPassesAndAppliesExactly() public {
        // The store's return data is passed through undecoded, as the store and registry do.
        (bool ok, bytes memory raw) =
            address(store).staticcall(abi.encodeCall(store.getOracleConfig, (address(oracle))));
        assertTrue(ok);
        (bool done, bytes memory ret) = address(oracle).staticcall(bytes.concat(ILPOracle.checkConfig.selector, raw));
        assertTrue(done);
        assertEq(abi.decode(ret, (uint256)), 0, "the store's configuration passes, registered market included");
        _tl();
        store.setFeedAgreementToleranceBps(usdc, 160);
        assertEq(oracle.getPriceState().tokens[0].feedAgreementToleranceBps, 160, "applied on the next read");
    }
}
