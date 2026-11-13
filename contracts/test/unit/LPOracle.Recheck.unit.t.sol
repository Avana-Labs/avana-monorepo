// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../src/types/OracleLeg.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../src/types/TokenOracleConfig.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {LPOracleHarness, LPOracleHarnessDeployer} from "../utils/harness/LPOracleHarness.sol";
import {OracleRegistryMock, OracleStoreMock, OracleTokenMock} from "../utils/mocks/LPOracleMocks.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title LPOracleRecheckRealStoreTest
/// @notice `checkConfig` derives the vault-token decimals `d` from the listing price vector stored at `initialize`
/// (REQ-ORACLE-047), so a depeg that takes one whole vault token out of the [$1, $10) window it had at listing changes
/// no answer of the re-check, and every ParameterStore oracle setter that re-runs it still succeeds: a global timer
/// (SCOPE_ALL), the depegged token's agreement tolerance and its second source.
/// @dev Core `checkConfig` logic with the real ParameterStore; the market is priced by the base's test module.
contract LPOracleRecheckRealStoreTest is ParameterStoreFixture {
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
        _deployOracle();
        _register();
    }

    function _deployOracle() internal {
        LPOracleHarness impl = LPOracleHarnessDeployer.deploy(address(timelock), BLOCK_TIME, 556_588, 3_000_000, false);
        bytes memory init = _init();
        oracle = LPOracleHarness(address(new ERC1967Proxy(address(impl), init)));
    }

    function _init() internal view returns (bytes memory) {
        InitParams memory p = _params(_cfg());
        return abi.encodeCall(ILPOracle.initialize, (p));
    }

    function _register() internal {
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(oracle);
        m.decimals = oracle.vaultDecimals();
        registry.setMarket(M, m);
    }

    function _cfg() internal view returns (OracleConfig memory c) {
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
        t.routes[0].legs[0] = OracleLeg(primary, 8, 86_400, 1800, 25, 1e6, 1e12, 88_200, 88_200);
        t.routes[1].legCount = 1;
        t.routes[1].legs[0] = OracleLeg(alternate, 8, 86_400, 1800, 25, 1e6, 1e12, 88_200, 88_200);
        t.feedAgreementToleranceBps = 150;
        t.secondSource = _second(second);
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
        // One whole vault token (10^6 units) holds 0.6 USDC + 0.6 USDT: $1.20 at peg, so d = 6.
        (k[0], k[1]) = (6e17, 6e17);
        p.market = abi.encode(k);
    }

    function _checkConfig() internal view returns (uint256) {
        (bool ok, bytes memory raw) =
            address(store).staticcall(abi.encodeCall(store.getOracleConfig, (address(oracle))));
        assertTrue(ok);
        (bool done, bytes memory ret) = address(oracle).staticcall(bytes.concat(ILPOracle.checkConfig.selector, raw));
        assertTrue(done);
        return abi.decode(ret, (uint256));
    }

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-047, REQ-PSTORE-009
    function test_TEST_219_depegLeavesEveryOracleSetterUsable() public {
        assertEq(oracle.vaultDecimals(), 6);
        assertEq(_checkConfig(), 0, "passes at listing");
        _tl();
        store.setCachedWindow(3000);

        // USDT trades at $0.60; every route and the second source agree. One vault token is now worth $0.96.
        fUsdt.setRound(0.6e8, block.timestamp);
        fUsdtAlt.setRound(0.6e8, block.timestamp);
        ssUsdt.setRound(0.6e8, block.timestamp);
        assertEq(uint8(oracle.getPriceState().state), uint8(PriceState.Drifting), "USD band: Drifting, liquidations on");
        assertEq(_checkConfig() & LPOracleCodes.CHECK_VAULT_DECIMALS, 0, "d is the listing value");
        assertEq(_checkConfig(), 0, "the re-check passes");

        _tl();
        store.setCachedWindow(7200);
        _tl();
        store.setFeedAgreementToleranceBps(usdt, 200);
        SecondSource memory empty;
        _tl();
        store.setSecondSource(usdt, _second(address(ssUsdc)), empty);
        assertEq(store.cachedWindow(), 7200, "global timer changed");
    }
}

/// @title LPOracleRecheckVolatileTest
/// @notice A plain +20 % ETH move, which makes `d = 6` qualify at the new prices, leaves `checkConfig` at 0: `d` is
/// derived from the listing price vector (REQ-ORACLE-047). Core logic on the mock store.
contract LPOracleRecheckVolatileTest is LPOracleFixture {
    function setUp() public {
        vm.warp(T0);
        vm.roll(100);
        registry = new OracleRegistryMock();
        store = new OracleStoreMock();
        store.setRegistry(registry);
        tokenA = new OracleTokenMock(6);
        tokenB = new OracleTokenMock(18);
        pA = _feed("USDC/USD");
        aA = _feed("USDC/USD alt");
        pB = _feed("ETH/USD");
        aB = _feed("ETH/USD alt");
        sA = _feed("USDC 2nd");
        sB = _feed("ETH 2nd");
        pB.push(3000e8, T0);
        aB.push(3000e8, T0);
        sB.push(3000e8, T0);
        registry.setRoutes(address(tokenA), _one(address(pA)), _one(address(aA)), RouteSlot.None);
        registry.setRoutes(address(tokenB), _one(address(pB)), _one(address(aB)), RouteSlot.None);
        OracleConfig memory c = _config();
        (c.usdBandLow, c.usdBandHigh) = (0, type(uint256).max);
        store.setConfig(c);
        implementation = LPOracleHarnessDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false);
        InitParams memory p = _params();
        p.config = c;
        p.isUsdStable[1] = false;
        uint256[] memory k = new uint256[](2);
        // 10^6 units: 0.01 USDC + 0.0003 WETH = $0.91, so d = 7 ($9.10).
        (k[0], k[1]) = (1e16, 3e26);
        p.market = abi.encode(k);
        oracle = LPOracleHarness(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p))))
        );
    }

    /// @dev `checkConfig` on the configuration the store serves, passed as its raw return bytes.
    function _recheck() internal view returns (uint256) {
        (bool ok, bytes memory raw) =
            address(store).staticcall(abi.encodeWithSignature("getOracleConfig(address)", address(oracle)));
        assertTrue(ok);
        (bool done, bytes memory ret) = address(oracle).staticcall(bytes.concat(ILPOracle.checkConfig.selector, raw));
        assertTrue(done);
        return abi.decode(ret, (uint256));
    }

    // TEST-219 verifies: REQ-ORACLE-046, REQ-ORACLE-047
    function test_TEST_219_plainRallyKeepsTheRecheckPassing() public {
        assertEq(oracle.vaultDecimals(), 7);
        assertEq(_recheck(), 0, "passes at listing");
        vm.warp(T0 + 3600);
        vm.roll(block.number + 300);
        pB.push(3600e8, T0 + 3600);
        aB.push(3600e8, T0 + 3600);
        sB.push(3600e8, T0 + 3600);
        assertEq(uint8(_state().state), uint8(PriceState.Live), "healthy Live market");
        assertEq(_recheck(), 0, "d stays the listing value");
    }
}
