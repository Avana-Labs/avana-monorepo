// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {ILPOracleErrors} from "../../src/oracle/lp-oracle/ILPOracleErrors.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCLInitLogic} from "../../src/oracle/lp-oracle/LPOracleCLInitLogic.sol";
import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPokeLogic} from "../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {LPOracleCLViewLogic} from "../../src/oracle/lp-oracle/LPOracleCLViewLogic.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {ClPriceStateView} from "../../src/oracle/lp-oracle/types/ClPriceStateView.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {LPOracleLogicSet} from "../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A real Uniswap v3 pool behind a forwarding shim: a test can replace the raw answer of one function or make it
/// revert; every other call is forwarded to the pool unchanged.
contract ClPoolFaultShim {
    address internal immutable _POOL;
    mapping(bytes4 => bytes) internal _reply;
    mapping(bytes4 => bool) internal _reverts;

    constructor(
        address pool
    ) {
        _POOL = pool;
    }

    function setReply(
        bytes4 selector,
        bytes calldata reply
    ) external {
        _reply[selector] = reply;
    }

    function setRevert(
        bytes4 selector,
        bool reverts
    ) external {
        _reverts[selector] = reverts;
    }

    function clear(
        bytes4 selector
    ) external {
        delete _reply[selector];
        delete _reverts[selector];
    }

    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        require(!_reverts[msg.sig], "fault");
        bytes memory reply = _reply[msg.sig];
        if (reply.length != 0) return reply;
        (bool ok, bytes memory ret) = _POOL.staticcall(data);
        require(ok, "pool reverted");
        return ret;
    }
}

/// @title LPOracleCLPoolReadsTest
/// @notice The concentrated-liquidity module's pool reads and listing checks on real Uniswap v3 pools: malformed
/// `slot0`, `observe` and `tickSpacing` answers, the `getClPriceState` report of a failed or unchecked market, the
/// consistency reference on uncapped quotes, the `PoolTwap` second source on an unusable deep pool, the listing bits
/// for an unobservable window, an extreme shocked ratio and unusable `PoolTwap` references, and `initialize` on
/// malformed market words, a token above 18 decimals and a listing logic that answers malformed.
contract LPOracleCLPoolReadsTest is LPOracleCLFixture {
    uint256 internal constant SHIFT = 16;
    uint256 internal constant REASON_READ = 1 << 1;
    uint256 internal constant REASON_DEVIATION = 1 << 4;
    uint256 internal constant REASON_UNAVAILABLE = 1 << 5;

    ClPoolFaultShim internal shim;
    IClPool internal realPool;

    /// @dev The ETH/USDC market initialized on its pool seen through `shim`.
    function _shimMarket() internal {
        _deployClMarket(_ethUsdc());
        realPool = pool;
        shim = new ClPoolFaultShim(address(realPool));
        pool = IClPool(address(shim));
        implementation = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        oracle = LPOracleCL(
            address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (_params()))))
        );
        _assertState(PriceState.Live);
    }

    function _slot0Words(
        uint256 cardinality,
        uint256 flag
    ) internal view returns (bytes memory) {
        (uint160 s,,,,,,) = realPool.slot0();
        return abi.encode(uint256(s), uint256(0), uint256(0), cardinality, cardinality, uint256(0), flag);
    }

    // TEST-306 verifies: REQ-ORACLE-103, REQ-AMM-V3-003
    /// @notice `slot0` answering seven words with the cardinality word at `2^16` (outside `uint16`) or the lock flag at
    /// 2 is a failed read (reason bit 1): the market fails and serves its accepted price; the same seven words with
    /// cardinality 151 and flag 1 read as an unlocked pool and the market is Live.
    function test_TEST_306_malformedSlot0IsAFailedRead() public {
        _shimMarket();
        shim.setReply(IClPool.slot0.selector, _slot0Words(151, 1));
        _assertState(PriceState.Live);
        assertEq(oracle.getClPriceState().observationCardinality, 151, "well-formed words are read");
        shim.setReply(IClPool.slot0.selector, _slot0Words(1 << 16, 1));
        PriceStateView memory v = _state();
        assertTrue(v.reasons & REASON_READ != 0, "cardinality outside uint16: read failed");
        assertGt(v.failureStart, 0, "market failed");
        assertEq(oracle.getClPriceState().observationCardinality, 0, "no cardinality reported");
        shim.setReply(IClPool.slot0.selector, _slot0Words(151, 2));
        v = _state();
        assertTrue(v.reasons & REASON_READ != 0, "lock flag 2: read failed");
        assertGt(v.failureStart, 0, "market failed");
    }

    // TEST-306 verifies: REQ-ORACLE-014, SPEC-ORC-010
    /// @notice An `observe` answer with a wrong head (first offset `0x60` instead of `0x40`) or a first cumulative of
    /// `2^60` (outside `int56`) is CONSISTENCY_UNAVAILABLE (reason bit 5): the market is Drifting, never failed; the
    /// pool's own answer restores Live.
    function test_TEST_306_malformedObserveIsUnavailable() public {
        _shimMarket();
        uint32[] memory ago = new uint32[](2);
        ago[0] = WINDOW;
        (int56[] memory cum, uint160[] memory spl) = realPool.observe(ago);
        bytes memory head = abi.encode(cum, spl);
        assembly ("memory-safe") {
            mstore(add(head, 0x20), 0x60)
        }
        shim.setReply(IClPool.observe.selector, head);
        PriceStateView memory v = _state();
        assertTrue(v.reasons & REASON_UNAVAILABLE != 0, "wrong head: unavailable");
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        assertEq(v.failureStart, 0, "not failed");
        bytes memory wide = abi.encode(cum, spl);
        assembly ("memory-safe") {
            mstore(add(wide, 0x80), shl(60, 1))
        }
        shim.setReply(IClPool.observe.selector, wide);
        v = _state();
        assertTrue(v.reasons & REASON_UNAVAILABLE != 0, "cumulative outside int56: unavailable");
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
        shim.clear(IClPool.observe.selector);
        assertEq(_state().reasons & REASON_UNAVAILABLE, 0, "pool answer: available");
        _assertState(PriceState.Live);
    }

    // TEST-306 verifies: REQ-ORACLE-105, REQ-ORACLE-046
    /// @notice The listing range check re-reads `tickSpacing()`: a revert, a two-word answer and a spacing of 60 where
    /// the market was listed at 10 each set CL_CHECK_RANGE (bit 16) alone.
    function test_TEST_306_unreadableOrChangedSpacingFailsTheRangeCheck() public {
        _shimMarket();
        assertEq(oracle.checkConfig(_config()), 0, "listed configuration passes");
        shim.setRevert(IClPool.tickSpacing.selector, true);
        assertEq(oracle.checkConfig(_config()), 1 << SHIFT, "tickSpacing reverts");
        shim.clear(IClPool.tickSpacing.selector);
        shim.setReply(IClPool.tickSpacing.selector, abi.encode(int256(10), int256(0)));
        assertEq(oracle.checkConfig(_config()), 1 << SHIFT, "two-word answer");
        shim.setReply(IClPool.tickSpacing.selector, abi.encode(int24(60)));
        assertEq(oracle.checkConfig(_config()), 1 << SHIFT, "spacing 60, listed at 10");
        shim.clear(IClPool.tickSpacing.selector);
        assertEq(oracle.checkConfig(_config()), 0, "pool answer passes");
    }

    // TEST-306 verifies: REQ-ORACLE-105, REQ-ORACLE-055, SPEC-ORC-022
    /// @notice CL_CHECK_OBSERVE (bit 19): a zero window sets it with CL_CHECK_TWAP_CONFIG (bit 17); on the listed
    /// 1,800 s window with 151 observations, an `observe` that reverts (as the pool's OLD does) sets it alone.
    function test_TEST_306_unobservableWindowSetsTheObserveBit() public {
        _shimMarket();
        OracleConfig memory c = _config();
        (c.twapWindow, c.twapMinObservations) = (0, 1);
        assertEq(oracle.checkConfig(c), (1 << (SHIFT + 1)) | (1 << (SHIFT + 3)), "zero window");
        shim.setRevert(IClPool.observe.selector, true);
        assertEq(oracle.checkConfig(_config()), 1 << (SHIFT + 3), "observe reverts");
        shim.clear(IClPool.observe.selector);
        assertEq(oracle.checkConfig(_config()), 0, "pool answer passes");
    }

    // TEST-306 verifies: REQ-ORACLE-105, SPEC-ORC-009
    /// @notice CL_CHECK_SHOCK_SQRT (bit 20): with the lower-decimals token as token0 (WBTC 8 / WETH 18, or USDC 6 /
    /// WETH 18), WETH quoted at $10^-6 (answer 100) makes the raw ratio `p0 / p1 * 10^(d1 - d0)` at least `10^18`, so
    /// the shocked ratio (times `100^2`) passes `2^64`; at the launch prices the bit is clear.
    function test_TEST_306_shockSqrtBitAtAnExtremeRatio() public {
        uint256 snap = vm.snapshotState();
        _deployClMarket(_wbtcEth());
        if (token0.decimals() > token1.decimals()) {
            vm.revertToState(snap);
            _deployClMarket(_ethUsdc());
        }
        assertLt(token0.decimals(), token1.decimals(), "lower-decimals token is token0");
        assertEq(oracle.checkConfig(_config()) & (1 << (SHIFT + 4)), 0, "launch prices: clear");
        _setPrices(price0, 100);
        uint256 raw = price0 * 10 ** token1.decimals() / (price1 * 10 ** token0.decimals());
        assertGe(raw * 100 * 100, 1 << 64, "shocked ratio reaches 2^64");
        assertTrue(oracle.checkConfig(_config()) & (1 << (SHIFT + 4)) != 0, "shocked ratio refused");
    }

    // TEST-306 verifies: REQ-ORACLE-046, REQ-ORACLE-100, REQ-ORACLE-103
    /// @notice A `PoolTwap` reference above 160 bits, or naming an address without code, sets CL_CHECK_POOL_TWAP
    /// (bit 21); a deep pool of the pair clears it.
    function test_TEST_306_unusablePoolTwapReferenceIsRefused() public {
        _deployClMarket(_ethUsdc());
        IClPool deep = _createPool(token0, token1, 3000, price0, price1, 200, 1e20);
        OracleConfig memory c = _config();
        c.tokens[1].secondSource.kind = SecondSourceKind.PoolTwap;
        c.tokens[1].secondSource.source = address(integration);
        c.tokens[1].secondSource.twapWindow = WINDOW;
        c.tokens[1].secondSource.poolRef = bytes32(uint256(uint160(address(deep))));
        assertEq(oracle.checkConfig(c) & (1 << (SHIFT + 5)), 0, "deep pool of the pair");
        c.tokens[1].secondSource.poolRef = bytes32(type(uint256).max);
        assertTrue(oracle.checkConfig(c) & (1 << (SHIFT + 5)) != 0, "reference above 160 bits");
        c.tokens[1].secondSource.poolRef = bytes32(uint256(0xDEAD));
        assertTrue(oracle.checkConfig(c) & (1 << (SHIFT + 5)) != 0, "no code");
    }

    // TEST-306 verifies: SPEC-ORC-020, REQ-ORACLE-100
    /// @notice A `PoolTwap` second source that is not a pool of the pair (token0's own contract), or a deep pool whose
    /// one-slot buffer cannot cover the 1,800 s window (`observe` reverts OLD), is unavailable for token1 (token bit 5),
    /// never a disagreement, and the market stays Live.
    function test_TEST_306_unusablePoolTwapSourceIsUnavailable() public {
        _deployClMarket(_ethUsdc());
        OracleConfig memory c = _config();
        c.tokens[1].secondSource.kind = SecondSourceKind.PoolTwap;
        c.tokens[1].secondSource.source = address(integration);
        c.tokens[1].secondSource.twapWindow = WINDOW;
        c.tokens[1].secondSource.toleranceBps = 100;
        c.tokens[1].secondSource.poolRef = bytes32(uint256(uint160(address(token0))));
        store.setConfig(c);
        PriceStateView memory v = _state();
        assertTrue(v.tokens[1].reasons & (1 << 5) != 0, "mispaired: unavailable");
        assertEq(v.tokens[1].reasons & (1 << 4), 0, "not a disagreement");
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
        IClPool young = _createPool(token0, token1, 3000, price0, price1, 1, 1e20);
        c.tokens[1].secondSource.poolRef = bytes32(uint256(uint160(address(young))));
        store.setConfig(c);
        v = _state();
        assertTrue(v.tokens[1].reasons & (1 << 5) != 0, "buffer short of the window: unavailable");
        assertEq(v.tokens[1].reasons & (1 << 4), 0, "not a disagreement");
    }

    // TEST-306 verifies: REQ-ORACLE-104, REQ-ORACLE-042
    /// @notice A failed market (every route of token0 answers 0) reports its range, tolerance and cardinality and every
    /// price field 0.
    function test_TEST_306_clPriceStateOfAFailedMarket() public {
        _deployClMarket(_ethUsdc());
        p0Feed.push(0, block.timestamp);
        a0Feed.push(0, block.timestamp);
        assertGt(_state().failureStart, 0, "market failed");
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.tickLower, tickLower, "tickLower");
        assertEq(r.tickUpper, tickUpper, "tickUpper");
        assertEq(r.twapToleranceTicks, TOLERANCE, "tolerance");
        assertGe(r.observationCardinality, 151, "cardinality");
        assertEq(r.sqrtPriceOracleX96, 0, "no oracle price");
        assertEq(r.sqrtPriceUsedX96, 0, "no used price");
        assertFalse(r.clamped, "not clamped");
        assertEq(r.meanTick, 0, "no mean tick");
        assertEq(r.tickRef, 0, "no reference");
        assertEq(r.tickDeviation, 0, "no deviation");
    }

    // TEST-306 verifies: REQ-ORACLE-104, REQ-ORACLE-014, SPEC-ORC-022
    /// @notice A priced market whose consistency check cannot run reports the oracle and used prices but no mean tick,
    /// reference or deviation: a 7,200 s window needs 601 observations against 151, and on the 1,800 s window with its
    /// 151 observations an `observe` that reverts (as the pool's OLD does) gives no mean tick.
    function test_TEST_306_clPriceStateWithoutConsistency() public {
        _shimMarket();
        OracleConfig memory c = _config();
        c.twapWindow = 7200;
        store.setConfig(c);
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.sqrtPriceOracleX96, _oracleSqrt(price0, price1), "oracle price reported");
        assertEq(r.sqrtPriceUsedX96, r.sqrtPriceOracleX96, "used price reported");
        assertEq(r.observationCardinality, 151, "151 observations, below the window's 601");
        assertEq(r.meanTick, 0, "cardinality short: no mean tick");
        assertEq(r.tickRef, 0, "no reference");
        assertEq(r.tickDeviation, 0, "no deviation");
        store.setConfig(_config());
        r = oracle.getClPriceState();
        assertEq(r.tickRef, ClPriceMath.tickAtSqrtRatio(_oracleSqrt(price0, price1)), "1,800 s: reference");
        shim.setRevert(IClPool.observe.selector, true);
        r = oracle.getClPriceState();
        assertEq(r.observationCardinality, 151, "cardinality covers the window");
        assertEq(r.sqrtPriceOracleX96, _oracleSqrt(price0, price1), "oracle price reported");
        assertEq(r.meanTick, 0, "observe reverts: no mean tick");
        assertEq(r.tickRef, 0, "no reference");
        assertEq(r.tickDeviation, 0, "no deviation");
    }

    // TEST-306 verifies: SPEC-ORC-010, REQ-ORACLE-014, REQ-ORACLE-104
    /// @notice The consistency reference is the tick of the uncapped quotes: USDC/USDT with token0 quoted at $1.05 is
    /// valued at the $1 ceiling (tick 0, the pool's own price), but its reference is about 488 ticks away, beyond the
    /// 50-tick tolerance, so the market is Drifting with CONSISTENCY_DEVIATION.
    function test_TEST_306_consistencyReferenceUsesTheUncappedQuotes() public {
        _deployClMarket(_usdcUsdt());
        OracleConfig memory c = _config();
        c.maxQuoteChangeBps = 1000;
        store.setConfig(c);
        _setPrices(1.05e8, 1e8);
        PriceStateView memory v = _state();
        assertEq(v.tokens[0].quote, 1.05e8, "uncapped quote");
        assertEq(v.tokens[0].valuationPrice, 1e8, "valued at the ceiling");
        ClPriceStateView memory r = oracle.getClPriceState();
        assertEq(r.sqrtPriceOracleX96, _oracleSqrt(1e8, 1e8), "valuation at tick 0");
        int24 ref = ClPriceMath.tickAtSqrtRatio(_oracleSqrt(1.05e8, 1e8));
        assertEq(r.tickRef, ref, "reference at the quotes");
        assertApproxEqAbs(int256(ref), 488, 1, "about 488 ticks");
        assertEq(v.consistencyDeviationBps, r.tickDeviation, "same deviation in getPriceState");
        assertGt(v.consistencyDeviationBps, TOLERANCE, "beyond tolerance");
        assertTrue(v.reasons & REASON_DEVIATION != 0, "CONSISTENCY_DEVIATION");
        assertEq(uint8(v.state), uint8(PriceState.Drifting), "Drifting");
    }

    // TEST-306 verifies: REQ-ORACLE-058, REQ-ORACLE-048, REQ-ORACLE-105
    /// @notice `initialize` refuses market words that are not `abi.encode(pool, tickLower, tickUpper)`: a fourth word,
    /// a pool word with bit 160 set, and a lower tick of `2^23` (outside `int24`).
    function test_TEST_306_initializeRefusesMalformedMarketWords() public {
        _deployClMarket(_ethUsdc());
        _expectInitRevertWith(abi.encode(address(pool), tickLower, tickUpper, uint256(0)));
        _expectInitRevertWith(abi.encode(uint256(uint160(address(pool))) | (1 << 160), tickLower, tickUpper));
        _expectInitRevertWith(abi.encode(address(pool), int256(1 << 23), tickUpper));
        _expectInitRevertWith(abi.encode(address(pool), tickLower, -int256(1 << 23) - 1));
    }

    // TEST-306 verifies: REQ-ORACLE-058, REQ-ORACLE-048
    /// @notice `initialize` refuses a pool token above 18 decimals: the same market with WETH replaced by a 19-decimal
    /// token reverts MarketMismatch, while an 18-decimal replacement initializes Live.
    function test_TEST_306_initializeRefusesATokenAbove18Decimals() public {
        _deployClMarket(_ethUsdc());
        ClTestToken usdc = token0.decimals() == 6 ? token0 : token1;
        _pairWith(usdc, 18);
        LPOracleCL impl = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        oracle = LPOracleCL(address(new ERC1967Proxy(address(impl), abi.encodeCall(ILPOracle.initialize, (_params())))));
        _assertState(PriceState.Live);
        _pairWith(usdc, 19);
        _expectInitRevertWith(abi.encode(address(pool), tickLower, tickUpper));
    }

    // TEST-306 verifies: REQ-ORACLE-058, REQ-ORACLE-080
    /// @notice An implementation whose listing slot holds the poke logic (same chain constants and module, so the
    /// constructor accepts it) cannot initialize a market: `checkConfig` there reverts NotDelegated, which the
    /// initialization logic counts as every check failing.
    function test_TEST_306_malformedListingAnswerFailsInitialize() public {
        _deployClMarket(_ethUsdc());
        address m = address(new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7));
        address poke = address(new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        address init = address(new LPOracleCLInitLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        address views = address(new LPOracleCLViewLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        LPOracleCL impl = new LPOracleCL(
            tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m, LPOracleLogicSet(poke, init, poke, views)
        );
        bytes memory initData = abi.encodeCall(ILPOracle.initialize, (_params()));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.ConfigCheckFailed.selector, type(uint256).max));
        new ERC1967Proxy(address(impl), initData);
    }

    /// @dev Replaces the non-USDC token with a new `dec`-decimal token at $3,000 on a new pool of the same fee, with
    /// its routes, feeds and a covered TWAP window.
    function _pairWith(
        ClTestToken usdc,
        uint8 dec
    ) internal {
        ClTestToken other = new ClTestToken("ALT", dec);
        bool usdcFirst = address(usdc) < address(other);
        (token0, token1) = usdcFirst ? (usdc, other) : (other, usdc);
        (price0, price1) = usdcFirst ? (uint256(1e8), uint256(3000e8)) : (uint256(3000e8), uint256(1e8));
        (stable[0], stable[1]) = (usdcFirst, !usdcFirst);
        pool = _createPool(token0, token1, 500, price0, price1, 151, 1e18);
        _touch(pool);
        vm.warp(block.timestamp + 3600);
        vm.roll(block.number + 1);
        _setPrices(price0, price1);
        registry.setRoutes(address(token0), _one(address(p0Feed)), _one(address(a0Feed)), RouteSlot.None);
        registry.setRoutes(address(token1), _one(address(p1Feed)), _one(address(a1Feed)), RouteSlot.None);
        store.setConfig(_config());
    }

    function _expectInitRevertWith(
        bytes memory market
    ) internal {
        LPOracleCL impl = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        InitParams memory p = _params();
        p.market = market;
        bytes memory init = abi.encodeCall(ILPOracle.initialize, (p));
        vm.expectRevert(abi.encodeWithSelector(ILPOracleErrors.MarketMismatch.selector, MARKET));
        new ERC1967Proxy(address(impl), init);
    }
}
