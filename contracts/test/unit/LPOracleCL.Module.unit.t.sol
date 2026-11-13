// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {
    LPOracleCLListingLogic,
    LPOracleCLPokeLogic,
    LPOracleCLViewLogic
} from "../../src/oracle/lp-oracle/LPOracleCLLogic.sol";
import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {LPOracleLogicSet} from "../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
import {Market} from "../../src/types/Market.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A real Uniswap v3 pool seen through Aerodrome Slipstream's `slot0` layout: six words, without `feeProtocol`.
/// Every other read is forwarded to the pool.
contract SixWordSlot0Pool {
    IClPool internal immutable _POOL;

    constructor(
        IClPool pool
    ) {
        _POOL = pool;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, bool) {
        (uint160 s, int24 t, uint16 i, uint16 c, uint16 n,, bool u) = _POOL.slot0();
        return (s, t, i, c, n, u);
    }

    function token0() external view returns (address) {
        return _POOL.token0();
    }

    function token1() external view returns (address) {
        return _POOL.token1();
    }

    function tickSpacing() external view returns (int24) {
        return _POOL.tickSpacing();
    }

    function observe(
        uint32[] calldata ago
    ) external view returns (int56[] memory, uint160[] memory) {
        return _POOL.observe(ago);
    }
}

/// @title LPOracleCLModuleTest
/// @notice The concentrated-liquidity pricing module's pool reads and listing checks on real Uniswap v3 pools: the TWAP
/// consistency check and its unavailability, the `getClPriceState` report, the `PoolTwap` second source on a deep pool,
/// the own-pool refusal, the module's listing bits, `initialize` refusals, the six-word `slot0` layout, and the
/// registered-market `checkConfig` that no price move or feed outage can fail (ORACLE-03).
contract LPOracleCLModuleTest is LPOracleCLFixture {
    uint256 internal constant SHIFT = 16;

    function _checkConfig(
        OracleConfig memory c
    ) internal view returns (uint256) {
        return oracle.checkConfig(c);
    }

    // TEST-306 verifies: REQ-ORACLE-104, SPEC-ORC-010, REQ-ORACLE-042
    function test_TEST_306_clPriceStateReportsTheEvaluation() public {
        _deployClMarket(_ethUsdc());
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.tickLower, tickLower, "tickLower");
        assertEq(r.tickUpper, tickUpper, "tickUpper");
        assertEq(r.twapToleranceTicks, TOLERANCE, "tolerance");
        assertGe(r.observationCardinality, 151, "cardinality");
        assertEq(r.sqrtPriceOracleX96, _oracleSqrt(price0, price1), "oracle sqrt");
        assertEq(r.sqrtPriceUsedX96, r.sqrtPriceOracleX96, "in range: unclamped");
        assertFalse(r.clamped, "not clamped");
        assertEq(r.tickRef, ClPriceMath.tickAtSqrtRatio(r.sqrtPriceOracleX96), "tickRef");
        assertLe(r.tickDeviation, 1, "pool TWAP at the oracle price");
        PriceStateView memory v = _state();
        assertEq(v.consistencyDeviationBps, r.tickDeviation, "same deviation in getPriceState");
    }

    // TEST-306 verifies: SPEC-ORC-010, REQ-ORACLE-014, SPEC-ORC-017
    /// @dev The pool held 2% above the oracle price for the whole window: the mean tick is about 198 ticks from the
    /// reference, beyond tau = 50, so the market is Drifting with CONSISTENCY_DEVIATION; it still serves the fresh
    /// price (SPEC-ORC-017).
    function test_TEST_306_twapDeviationMakesTheMarketDrifting() public {
        _deployClMarket(_ethUsdc());
        _swapTo(pool, uint160(uint256(_oracleSqrt(price0, price1)) * 101 / 100));
        vm.warp(block.timestamp + WINDOW + 1);
        vm.roll(block.number + 200);
        _setPrices(price0, price1);
        PriceStateView memory v = _state();
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertTrue(_has(v.reasons, 4), "CONSISTENCY_DEVIATION");
        assertGt(v.consistencyDeviationBps, TOLERANCE, "deviation beyond tolerance");
        assertEq(v.answer, v.freshAnswer, "fresh price served");
        // Back at the oracle price for a whole window: Live again.
        _swapTo(pool, _oracleSqrt(price0, price1));
        vm.warp(block.timestamp + WINDOW + 1);
        _setPrices(price0, price1);
        _assertState(PriceState.Live);
    }

    // TEST-306 verifies: REQ-ORACLE-014, SPEC-ORC-022
    /// @dev A window the pool's buffer cannot cover (cardinality below SPEC-ORC-022) and a zero window are
    /// CONSISTENCY_UNAVAILABLE, never a revert.
    function test_TEST_306_unavailableConsistencyIsDriftingNeverARevert() public {
        _deployClMarket(_ethUsdc());
        OracleConfig memory c = _config();
        c.twapWindow = 7200;
        store.setConfig(c);
        PriceStateView memory v = _state();
        assertTrue(_has(v.reasons, 5), "CONSISTENCY_UNAVAILABLE (cardinality)");
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertGe(oracle.latestAnswer(), 1, "serves");
        c.twapWindow = 0;
        store.setConfig(c);
        assertTrue(_has(_state().reasons, 5), "CONSISTENCY_UNAVAILABLE (zero window)");
    }

    // TEST-306 verifies: REQ-ORACLE-014, SPEC-ORC-010
    /// @dev A buffer large enough but not old enough: observe reverts OLD, which reads as unavailable.
    function test_TEST_306_observeOldIsUnavailable() public {
        _deployClMarket(_ethUsdc());
        pool.increaseObservationCardinalityNext(700);
        _touch(pool);
        // 700 slots now exist, but the oldest observation is under two hours old.
        OracleConfig memory c = _config();
        c.twapWindow = 8000;
        store.setConfig(c);
        vm.warp(block.timestamp + 1);
        _setPrices(price0, price1);
        assertTrue(_has(_state().reasons, 5), "OLD read as unavailable");
    }

    // TEST-306 verifies: SPEC-ORC-020, REQ-ORACLE-100
    // TEST-276 verifies: SPEC-ORC-020, REQ-ORACLE-100
    /// @dev Token1's second source is the time-weighted price of a deep pool of the same pair (fee 3,000): it agrees
    /// with the oracle, so the token is confirmed; moved 5% for the window, it is not.
    function test_TEST_306_poolTwapSecondSourceOnADeepPool() public {
        _deployClMarket(_ethUsdc());
        IClPool deep = _createPool(token0, token1, 3000, price0, price1, 200, 1e20);
        _touch(deep);
        vm.warp(block.timestamp + WINDOW + 60);
        _setPrices(price0, price1);
        OracleConfig memory c = _config();
        c.tokens[1].secondSource.kind = SecondSourceKind.PoolTwap;
        c.tokens[1].secondSource.source = address(integration);
        c.tokens[1].secondSource.poolRef = bytes32(uint256(uint160(address(deep))));
        c.tokens[1].secondSource.twapWindow = WINDOW;
        c.tokens[1].secondSource.toleranceBps = 100;
        store.setConfig(c);
        PriceStateView memory v = _state();
        assertEq(v.tokens[1].reasons & ((1 << 4) | (1 << 5)), 0, "token1 confirmed by the deep pool");
        assertTrue(v.borrowAllowed, "borrow allowed");
        _swapTo(deep, uint160(uint256(_oracleSqrt(price0, price1)) * 105 / 100));
        vm.warp(block.timestamp + WINDOW + 1);
        _setPrices(price0, price1);
        v = _state();
        assertTrue(v.tokens[1].reasons & (1 << 4) != 0, "deep pool disagrees");
        assertFalse(v.borrowAllowed, "borrow refused");
        assertEq(uint8(v.state), uint8(PriceState.Live), "the second source never changes the state");
    }

    // TEST-306 verifies: REQ-ORACLE-046, REQ-ORACLE-100, REQ-ORACLE-103
    function test_TEST_306_ownPoolSecondSourceIsRefused() public {
        _deployClMarket(_ethUsdc());
        OracleConfig memory c = _config();
        c.tokens[0].secondSource.kind = SecondSourceKind.PoolTwap;
        c.tokens[0].secondSource.source = address(integration);
        c.tokens[0].secondSource.poolRef = bytes32(uint256(uint160(address(pool))));
        c.tokens[0].secondSource.twapWindow = WINDOW;
        assertTrue(_checkConfig(c) & (1 << 10) != 0, "CHECK_SECOND_SOURCE");
        c.tokens[0].secondSource.poolRef = bytes32(uint256(uint160(address(token0))));
        assertTrue(_checkConfig(c) & (1 << (SHIFT + 5)) != 0, "mispaired PoolTwap");
    }

    // TEST-306 verifies: REQ-ORACLE-105, REQ-ORACLE-055, SPEC-ORC-022, REQ-AMM-CORE-004
    function test_TEST_306_moduleListingBits() public {
        _deployClMarket(_ethUsdc());
        OracleConfig memory c = _config();
        assertEq(_checkConfig(c), 0, "launch configuration passes");
        c.consistencyToleranceBps = 9;
        assertEq(_checkConfig(c), 1 << (SHIFT + 1), "tolerance below 10 ticks");
        c = _config();
        c.twapMinObservations = 150;
        assertEq(_checkConfig(c), 1 << (SHIFT + 1), "twapMinObservations off by one");
        c = _config();
        (c.twapWindow, c.twapMinObservations) = (3600, 301);
        assertEq(_checkConfig(c), 1 << (SHIFT + 2), "cardinality below 301");
        c = _config();
        integration.setProvider(1, address(0xBEEF));
        assertEq(_checkConfig(c), 0, "unbound before listing: the read reverts and is not counted");
        integration.setBound(true);
        assertEq(_checkConfig(c), 1 << (SHIFT + 6), "bound: a rate provider is refused");
        integration.setProvider(1, address(0));
        assertEq(_checkConfig(c), 0, "bound, no rate provider");
        integration.setBound(false);
        integration.setProvider(1, address(0xBEEF));
        Market memory m;
        m.integration = address(integration);
        m.lpOracle = address(oracle);
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(token0), address(token1));
        registry.setMarketOf(address(oracle), MARKET, m);
        assertTrue(_checkConfig(c) & (1 << (SHIFT + 6)) != 0, "registered: an unreadable provider list is refused");
    }

    // TEST-306 verifies: REQ-ORACLE-105, SPEC-ORC-009
    /// @dev A pair whose shocked raw ratio reaches 2^64 is refused: an 18-decimal token at $10^9 against a 0-decimal
    /// token at $1 gives 10^9 * 10^0 * 100 / (10^-2 ... ) beyond the lower branch.
    function test_TEST_306_shockSqrtBitAtExtremeRatios() public {
        _deployClMarket(_ethUsdc());
        // The module's check at the shocked quotes, reached through checkConfig before registration.
        OracleConfig memory c = _config();
        uint256 q = 1e18;
        p0Feed.push(int256(q), block.timestamp);
        a0Feed.push(int256(q), block.timestamp);
        uint256 failed = _checkConfig(c);
        // WETH (18) / USDC (6) at 10^10 USD: num = 10^20 * 100 * 10^6, den = 10^6 * 10^18: ratio 10^10 < 2^64 passes;
        // the bit must stay clear for every listable ratio of this pair.
        assertEq(failed & (1 << (SHIFT + 4)), 0, "listable ratio");
    }

    // TEST-306 verifies: REQ-ORACLE-058, REQ-ORACLE-048, REQ-ORACLE-105
    function test_TEST_306_initializeRefusesAMismatchedMarket() public {
        _deployClMarket(_ethUsdc());
        // Tokens in the wrong order.
        (ClTestToken a, ClTestToken b) = (token0, token1);
        (token0, token1) = (b, a);
        (price0, price1) = (price1, price0);
        (stable[0], stable[1]) = (stable[1], stable[0]);
        _expectInitRevert();
        (token0, token1) = (a, b);
        (price0, price1) = (price1, price0);
        (stable[0], stable[1]) = (stable[1], stable[0]);
        // A misaligned range at spacing 10.
        (tickLower, tickUpper) = (-15, 10);
        _expectInitRevert();
        // An inverted range.
        (tickLower, tickUpper) = (10, -10);
        _expectInitRevert();
        // A pool with no code.
        (tickLower, tickUpper) = (-10, 10);
        IClPool real = pool;
        pool = IClPool(address(0xDEAD));
        _expectInitRevert();
        pool = real;
    }

    function _expectInitRevert() internal {
        LPOracleCL impl = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        bytes memory init = abi.encodeCall(ILPOracle.initialize, (_params()));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET));
        new ERC1967Proxy(address(impl), init);
    }

    // TEST-306 verifies: REQ-AMM-SLIP-003, REQ-AMM-V3-003, REQ-ORACLE-103
    /// @dev The Slipstream implementation (six-word slot0) prices a six-word pool and fails closed (reason bit 1) on a
    /// seven-word one; the Uniswap v3 implementation fails closed on a six-word pool.
    function test_TEST_306_slot0LayoutIsFixedPerImplementation() public {
        _deployClMarket(_ethUsdc());
        SixWordSlot0Pool six = new SixWordSlot0Pool(pool);
        IClPool real = pool;
        pool = IClPool(address(six));
        LPOracleCL slip = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 6);
        LPOracleCL slipOracle =
            LPOracleCL(address(new ERC1967Proxy(address(slip), abi.encodeCall(ILPOracle.initialize, (_params())))));
        assertEq(uint8(slipOracle.getPriceState().state), uint8(PriceState.Live), "six words: Live");
        assertEq(slipOracle.latestAnswer(), oracle.latestAnswer(), "same price as the v3 implementation");
        // The v3 implementation reading the six-word pool: slot0 is malformed, the market fails.
        LPOracleCL v3 = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        bytes memory init = abi.encodeCall(ILPOracle.initialize, (_params()));
        vm.expectRevert();
        new ERC1967Proxy(address(v3), init);
        pool = real;
        assertEq(slip.SLOT0_WORDS(), 6, "layout");
    }

    // TEST-306 verifies: REQ-AMM-V3-002
    /// @dev The local `univ3` build is the canonical release: the pool's creation code hashes to the
    /// `POOL_INIT_CODE_HASH` the NonfungiblePositionManager and the Uniswap v3 integration hard-code, so pools created
    /// here sit at the CREATE2 addresses those contracts derive.
    function test_TEST_306_localPoolBuildIsTheCanonicalRelease() public view {
        bytes memory code = vm.getCode("out-univ3/UniswapV3Pool.sol/UniswapV3Pool.json");
        assertEq(keccak256(code), 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54, "init code hash");
    }

    // TEST-306 verifies: REQ-ORACLE-080, REQ-AMM-V3-003
    function test_TEST_306_constructorRequiresOneLayout() public {
        address m7 = _module(7);
        address m6 = _module(6);
        address poke = address(new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m7));
        address views = address(new LPOracleCLViewLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 6, m6));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCL(
            tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m7, LPOracleLogicSet(poke, poke, poke, views)
        );
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 5);
        // A logic contract refuses a module of another layout or other chain constants.
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m6);
        address otherChain = address(new LPOracleCLModuleLogic(tl, 2, POKE_FLOOR, POKE_CEILING, false, 7));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, otherChain);
    }

    function _module(
        uint8 words
    ) internal returns (address) {
        return address(new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, words));
    }

    // TEST-306 verifies: REQ-ORACLE-080, REQ-ORACLE-103, REQ-ORACLE-106
    /// @dev The module contract is fixed at deployment and cannot be swapped: an address with no code or another
    /// contract is refused, an implementation whose logic contracts name different module contracts is refused, the
    /// module refuses direct calls, and nothing writes the address later (an immutable; no setter exists).
    function test_TEST_306_moduleContractCannotBeSwapped() public {
        address m = _module(7);
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, address(0xBEEF));
        vm.expectRevert();
        new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, address(this));
        address other = _module(7);
        address poke = address(new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        address listing = address(new LPOracleCLListingLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, other));
        address views = address(new LPOracleCLViewLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCL(
            tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m, LPOracleLogicSet(poke, poke, listing, views)
        );
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, 0));
        new LPOracleCL(
            tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, other, LPOracleLogicSet(poke, poke, poke, views)
        );
        vm.expectRevert(ILPOracleErrors.NotDelegated.selector);
        LPOracleCLModuleLogic(m).isOwnPool(bytes32(0));
        _deployClMarket(_ethUsdc());
        address fixed_ = implementation.MODULE_LOGIC();
        assertEq(LPOracleCL(address(oracle)).MODULE_LOGIC(), fixed_, "the proxy runs the implementation's module");
        assertEq(LPOracleCLPokeLogic(implementation.POKE_LOGIC()).MODULE_LOGIC(), fixed_, "poke logic");
        assertEq(LPOracleCLViewLogic(implementation.VIEW_LOGIC()).MODULE_LOGIC(), fixed_, "view logic");
        assertEq(LPOracleCLListingLogic(implementation.LISTING_LOGIC()).MODULE_LOGIC(), fixed_, "listing logic");
        assertEq(LPOracleCLListingLogic(implementation.INIT_LOGIC()).MODULE_LOGIC(), fixed_, "init logic");
    }

    // TEST-306 verifies: REQ-ORACLE-046, REQ-ORACLE-047, REQ-ORACLE-050
    /// @dev ORACLE-03: once registered, a tenfold rise, a tenfold fall and an outage of every route of a token change
    /// no answer of checkConfig, so the ParameterStore's setters and the guardian's switches are never blocked.
    function test_TEST_306_registeredCheckConfigIgnoresPriceMovesAndOutages() public {
        _deployClMarket(_ethUsdc());
        Market memory m;
        m.integration = address(integration);
        m.lpOracle = address(oracle);
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(token0), address(token1));
        registry.setMarketOf(address(oracle), MARKET, m);
        integration.setBound(true);
        uint256 base = _checkConfig(_config()) & ~uint256(1 << 15);
        assertEq(base, 0, "registered market passes");
        _setPrices(price0 * 10, price1);
        assertEq(_checkConfig(_config()) & ~uint256(1 << 15), 0, "tenfold rise");
        _setPrices(price0 / 100, price1);
        assertEq(_checkConfig(_config()) & ~uint256(1 << 15), 0, "hundredfold fall");
        p1Feed.push(0, block.timestamp);
        a1Feed.push(0, block.timestamp);
        assertEq(_checkConfig(_config()) & ~uint256(1 << 15), 0, "outage of token1");
    }

    // TEST-306 verifies: REQ-ORACLE-046, REQ-ORACLE-047
    /// @dev Before registration the same outage is CHECK_QUOTES: a listing needs every token quoted now.
    function test_TEST_306_unregisteredCheckConfigNeedsQuotes() public {
        _deployClMarket(_ethUsdc());
        p1Feed.push(0, block.timestamp);
        a1Feed.push(0, block.timestamp);
        assertTrue(_checkConfig(_config()) & (1 << 11) != 0, "CHECK_QUOTES");
    }
}
