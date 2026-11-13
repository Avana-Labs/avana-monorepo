// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {OracleLeg} from "../../src/types/OracleLeg.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {TokenOracleConfig} from "../../src/types/TokenOracleConfig.sol";
import {ClPoolActor, ClTestToken, IClFactory, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {LPOracleCLDeployer} from "../utils/fixtures/LPOracleCLFixture.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title LPOracleCLRealStoreTest
/// @notice The real concentrated-liquidity LPOracle on a real Uniswap v3 USDC/USDT pool, registered for market 1 of
/// the real ParameterStore (behind its timelock): it evaluates Live on the store's configuration, and a parameter
/// change that would give it a configuration its `checkConfig` refuses is reverted by the store, leaving the old
/// value in force.
contract LPOracleCLRealStoreTest is ParameterStoreFixture {
    uint256 internal constant T0 = 1_762_650_000;
    uint32 internal constant POKE_FLOOR = 900_000;

    IClFactory internal v3;
    ClPoolActor internal actor;
    IClPool internal realPool;
    LPOracleCL internal oracle;
    MockAggregator internal ssUsdc;
    MockAggregator internal ssUsdt;

    function setUp() public {
        vm.warp(T0 - 7200);
        vm.roll(100);
        // Pool tokens in pool order, named as the store fixture names them.
        ClTestToken a = new ClTestToken("USDC", 6);
        ClTestToken b = new ClTestToken("USDT", 6);
        (ClTestToken t0, ClTestToken t1) = address(a) < address(b) ? (a, b) : (b, a);
        (usdc, usdt) = (address(t0), address(t1));
        _deployStore(false);
        realPool = _pool(t0, t1);
        Market memory m = registry.getMarket(M);
        m.pool = address(realPool);
        registry.setMarket(M, m);
        _listMarket();
        vm.warp(T0);
        vm.roll(block.number + 1);
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
        LPOracleCL impl = LPOracleCLDeployer.deploy(address(timelock), BLOCK_TIME, POKE_FLOOR, 3_000_000, false, 7);
        oracle = LPOracleCL(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (_params(_config())))))
        );
        _register();
    }

    /// @dev A real Uniswap v3 pool (0.01 %, spacing 1) at $1 / $1 with a 151-slot buffer and full-range liquidity,
    /// created two hours before `T0`.
    function _pool(
        ClTestToken t0,
        ClTestToken t1
    ) internal returns (IClPool p) {
        v3 = IClFactory(deployCode("out-univ3/UniswapV3Factory.sol/UniswapV3Factory.json"));
        v3.enableFeeAmount(100, 1);
        actor = new ClPoolActor();
        p = IClPool(v3.createPool(address(t0), address(t1), 100));
        p.initialize(ClPriceMath.oracleSqrtPrice(1e8, 1e8, 6, 6));
        p.increaseObservationCardinalityNext(151);
        t0.mint(address(actor), type(uint128).max);
        t1.mint(address(actor), type(uint128).max);
        actor.mint(p, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK, 1e15);
        vm.warp(T0 - 3600);
        vm.roll(block.number + 1);
        actor.mint(p, ClPriceMath.MIN_TICK, ClPriceMath.MAX_TICK, 1e6);
    }

    /// @dev Points market 1 at the oracle with the vault-token decimals the oracle stored at `initialize`: the one
    /// value of `decimals` for which its own market check passes.
    function _register() internal {
        Market memory m = registry.getMarket(M);
        m.lpOracle = address(oracle);
        for (uint8 d = 6; d <= 18; ++d) {
            m.decimals = d;
            registry.setMarket(M, m);
            if (oracle.checkConfig(_config()) & LPOracleCodes.CHECK_MARKET == 0) return;
        }
        revert("no vault decimals match");
    }

    function _config() internal view returns (OracleConfig memory c) {
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
        p.description = "USDC/USDT [-10,10] / USD";
        p.pokeMinGas = POKE_FLOOR;
        p.config = c;
        p.market = abi.encode(address(realPool), int24(-10), int24(10), uint256(0));
    }

    // TEST-219 verifies: REQ-ORACLE-077, REQ-ORACLE-046, REQ-PSTORE-009, Q-184, Q-191
    // Sources: 2.10 REQ-ORACLE-077 (a new oracle configuration that fails checkConfig: the ParameterStore reverts the
    // change)
    /// @notice The registered oracle is Live on the store's configuration and passes its own `checkConfig` of it.
    /// Raising `feedAgreementMarginBps` from 50 to 51 would put every second source's tolerance (100 bps) below its
    /// lower bound `25 + 25 + margin`: the LPOracle refuses that configuration with `CHECK_TOLERANCE` and the store
    /// reverts `OracleConfigRejected(oracle, CHECK_TOLERANCE)`, keeping 50. A change the LPOracle accepts (margin 45)
    /// is applied and read by the next evaluation.
    function test_TEST_219_storeRevertsAChangeTheOracleRefuses() public {
        PriceStateView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live on the store's configuration");
        assertTrue(v.borrowAllowed, "second sources from the store confirm");
        assertEq(oracle.checkConfig(_config()), 0, "the registered market passes");
        assertEq(store.feedAgreementMarginBps(), 50);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(
                IParameterStoreErrors.OracleConfigRejected.selector, address(oracle), LPOracleCodes.CHECK_TOLERANCE
            )
        );
        store.setFeedAgreementMarginBps(51);
        assertEq(store.feedAgreementMarginBps(), 50, "the refused change is not applied");
        _tl();
        store.setFeedAgreementMarginBps(45);
        assertEq(store.feedAgreementMarginBps(), 45, "an accepted change applies");
        assertEq(uint8(oracle.getPriceState().state), uint8(PriceState.Live), "and the oracle stays Live");
    }
}
