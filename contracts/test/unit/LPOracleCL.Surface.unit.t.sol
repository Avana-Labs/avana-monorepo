// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {LPOracleCLInitLogic} from "../../src/oracle/lp-oracle/LPOracleCLInitLogic.sol";
import {LPOracleCLListingLogic} from "../../src/oracle/lp-oracle/LPOracleCLListingLogic.sol";
import {LPOracleCLModuleLogic} from "../../src/oracle/lp-oracle/LPOracleCLModuleLogic.sol";
import {LPOracleCLPokeLogic} from "../../src/oracle/lp-oracle/LPOracleCLPokeLogic.sol";
import {LPOracleCLViewLogic} from "../../src/oracle/lp-oracle/LPOracleCLViewLogic.sol";
import {LPOracleCodes} from "../../src/oracle/lp-oracle/LPOracleTypes.sol";
import {InitParams} from "../../src/oracle/lp-oracle/types/InitParams.sol";
import {LPOracleLogicSet} from "../../src/oracle/lp-oracle/types/LPOracleLogicSet.sol";
import {OracleConfig} from "../../src/types/OracleConfig.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {LPOracleCLDeployer, LPOracleCLFixture} from "../utils/fixtures/LPOracleCLFixture.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title LPOracleCLSurfaceTest
/// @notice The external surface of the real concentrated-liquidity LPOracle: an upgrade through the timelock keeps the
/// proxy address, the `poke()` selector and return and every view its callers read; the views read only the market's
/// own configuration, feeds, pool and tokens (never an AaveOracle); `checkConfig`'s independence, tolerance and USD-band
/// rules; the stable flags fixed at `initialize`; and the selector inventory, which holds no pause or override.
contract LPOracleCLSurfaceTest is LPOracleCLFixture {
    using BytecodeInspector for bytes;

    uint256 internal constant ONE = 1e8;
    uint256 internal constant T1 = T0 + 60;

    function _stable() internal {
        _deployClMarket(_usdcUsdt());
        vm.warp(T1);
        vm.roll(block.number + 1);
        _setPrices(ONE, ONE);
    }

    function _check(
        OracleConfig memory c
    ) internal view returns (uint256) {
        return oracle.checkConfig(c);
    }

    /// @dev Every view and the poke a caller of the LPOracle uses, encoded, in one block.
    function _views() internal returns (bytes memory) {
        (uint256[] memory prices, uint64 at, PriceState s) = oracle.getTokenPrices();
        (uint80 r, int256 a, uint256 st, uint256 up, uint80 ans) = oracle.latestRoundData();
        (uint256 accepted, uint64 acceptedAt) = oracle.lastAcceptedPrice();
        (uint256 cp, uint64 cpAt) = oracle.priceCheckpoint();
        (bool invalid, uint64 verifiedAt) = oracle.decimalsStatus();
        return bytes.concat(
            abi.encode(oracle.getPriceState(), prices, at, s),
            abi.encode(r, a, st, up, ans, oracle.latestAnswer(), oracle.decimals()),
            abi.encode(oracle.borrowPriceMaxAge(), oracle.liquidationPriceMaxAge(), accepted, acceptedAt),
            abi.encode(cp, cpAt, invalid, verifiedAt, oracle.marketId(), oracle.tokens())
        );
    }

    // ─── Upgrade keeps the address and every view ───

    // TEST-062 verifies: REQ-ORACLE-101, REQ-ORACLE-082, REQ-ORACLE-078
    /// @notice With a failure recorded (token1's aggregators reverting), an upgrade to a new implementation is refused
    /// to any caller but the timelock; through the timelock it keeps the proxy address (the Aave price source and the
    /// vault token's `lpOracle()` for life), every view the RiskModule, LPVaultSwap, the Lens and keepers read, and the
    /// `poke()` selector with its empty arguments and one-word `PriceState` return.
    function test_TEST_062_upgradeThroughTheTimelockKeepsAddressAndViews() public {
        _stable();
        oracle.poke();
        vm.mockCallRevert(address(p1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.mockCallRevert(address(a1Feed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), "down");
        vm.warp(T1 + 100);
        vm.roll(block.number + 1);
        p0Feed.push(int256(ONE), T1 + 100);
        oracle.poke();
        address before = address(oracle);
        bytes memory viewsBefore = _views();
        LPOracleCL next = LPOracleCLDeployer.deploy(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        oracle.upgradeToAndCall(address(next), "");
        vm.prank(tl);
        oracle.upgradeToAndCall(address(next), "");
        assertEq(address(oracle), before, "same proxy address");
        assertEq(_views(), viewsBefore, "every view and the stored timers are kept");
        assertEq(uint8(_state().state), uint8(PriceState.Cached), "the new implementation reads the same failure");
        assertEq(ILPOracle.poke.selector, bytes4(keccak256("poke()")), "poke() selector");
        (bool ok, bytes memory ret) = address(oracle).call(abi.encodeWithSignature("poke()"));
        assertTrue(ok, "poke() with no arguments");
        assertEq(ret.length, 32, "one word: the PriceState");
        assertEq(abi.decode(ret, (uint256)), uint256(PriceState.Cached));
        assertEq(ILPOracle.getPriceState.selector, bytes4(keccak256("getPriceState()")), "getPriceState() selector");
    }

    // TEST-062 verifies: REQ-ORACLE-101
    /// @notice No LPOracle view or poke reads anything but the market's ParameterStore, MarketRegistry, integration,
    /// feeds, pool and tokens: every external call the oracle proxy makes is to one of them, so a change of the
    /// AaveOracle's source changes neither the state nor `liquidationPaused`.
    function test_TEST_062_viewsReadNoAaveOracle() public {
        _stable();
        address[12] memory allowed = [
            address(store),
            address(registry),
            address(integration),
            address(p0Feed),
            address(a0Feed),
            address(s0Feed),
            address(p1Feed),
            address(a1Feed),
            address(s1Feed),
            address(pool),
            address(token0),
            address(token1)
        ];
        vm.startStateDiffRecording();
        oracle.getPriceState();
        oracle.latestAnswer();
        oracle.latestRoundData();
        oracle.getTokenPrices();
        oracle.liquidationPriceMaxAge();
        oracle.borrowPriceMaxAge();
        oracle.poke();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 external_ = 0;
        for (uint256 i = 0; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory x = accesses[i];
            bool call = x.kind == VmSafe.AccountAccessKind.Call || x.kind == VmSafe.AccountAccessKind.StaticCall;
            if (!call || x.accessor != address(oracle) || x.account == address(oracle)) continue;
            ++external_;
            bool known = false;
            for (uint256 k = 0; k < allowed.length; ++k) {
                if (x.account == allowed[k]) known = true;
            }
            assertTrue(known, "the oracle read a contract outside its market");
        }
        assertGt(external_, 0, "the recording saw the oracle's reads");
    }

    // ─── checkConfig: independence, tolerances, band ───

    // TEST-219 verifies: REQ-ORACLE-051
    /// @notice A token's primary and alternate sharing an aggregator, two tokens' alternates sharing one, and a second
    /// source sharing one with its token's route each set `CHECK_SHARED_FEED`; the launch configuration does not.
    function test_TEST_219_sharedAggregatorsRefused() public {
        _stable();
        assertEq(_check(_config()) & LPOracleCodes.CHECK_SHARED_FEED, 0, "independent routes");
        OracleConfig memory c = _config();
        c.tokens[0].routes[1] = c.tokens[0].routes[0];
        assertTrue(_check(c) & LPOracleCodes.CHECK_SHARED_FEED != 0, "primary and alternate share a feed");
        c = _config();
        c.tokens[1].routes[1] = c.tokens[0].routes[1];
        assertTrue(_check(c) & LPOracleCodes.CHECK_SHARED_FEED != 0, "two alternates share a feed");
        c = _config();
        c.tokens[0].secondSource.source = address(a0Feed);
        assertTrue(_check(c) & LPOracleCodes.CHECK_SHARED_FEED != 0, "second source shares a route feed");
    }

    // TEST-219 verifies: REQ-ORACLE-053
    /// @notice With legs of 25 bps and `feedAgreementMarginBps` 50: `feedAgreementToleranceBps` must be at least
    /// 25 + 25 + 50 = 100 and the second source's tolerance at least 25 + 25 (its own feed's threshold) + 50 = 100;
    /// 99 fails either, 100 passes, and raising the margin makes the same configuration fail (a hard lower bound for
    /// every later change).
    function test_TEST_219_toleranceLowerBounds() public {
        _stable();
        OracleConfig memory c = _config();
        c.tokens[0].feedAgreementToleranceBps = 100;
        c.tokens[0].secondSource.toleranceBps = 100;
        assertEq(_check(c) & LPOracleCodes.CHECK_TOLERANCE, 0, "at the bounds");
        c.tokens[0].feedAgreementToleranceBps = 99;
        assertTrue(_check(c) & LPOracleCodes.CHECK_TOLERANCE != 0, "T below 25 + 25 + 50");
        c.tokens[0].feedAgreementToleranceBps = 100;
        c.tokens[0].secondSource.toleranceBps = 99;
        assertTrue(_check(c) & LPOracleCodes.CHECK_TOLERANCE != 0, "S below 25 + 25 + 50");
        c.tokens[0].secondSource.toleranceBps = 100;
        store.setMargin(51);
        assertTrue(_check(c) & LPOracleCodes.CHECK_TOLERANCE != 0, "a larger margin raises the bound");
    }

    // TEST-219 verifies: REQ-ORACLE-056
    /// @notice For an all-stable market the band must straddle 1.00 (`usdBandLow < 10^8 < usdBandHigh`); for a market
    /// with a non-stable token it must be exactly `[0, type(uint256).max]`.
    function test_TEST_219_usdBandShape() public {
        _stable();
        OracleConfig memory c = _config();
        assertEq(_check(c) & LPOracleCodes.CHECK_USD_BAND, 0, "0.90 < 1.00 < 1.02");
        c.usdBandLow = ONE;
        assertTrue(_check(c) & LPOracleCodes.CHECK_USD_BAND != 0, "low at 1.00");
        c = _config();
        c.usdBandHigh = ONE;
        assertTrue(_check(c) & LPOracleCodes.CHECK_USD_BAND != 0, "high at 1.00");
        _deployClMarket(_ethUsdc());
        c = _config();
        assertEq(_check(c) & LPOracleCodes.CHECK_USD_BAND, 0, "WETH/USDC: no band");
        c.usdBandLow = 0.9e8;
        c.usdBandHigh = 1.02e8;
        assertTrue(_check(c) & LPOracleCodes.CHECK_USD_BAND != 0, "a band on a non-stable market");
        c = _config();
        c.usdBandHigh = type(uint256).max - 1;
        assertTrue(_check(c) & LPOracleCodes.CHECK_USD_BAND != 0, "exactly type(uint256).max");
    }

    // ─── Stable flags fixed at initialize ───

    // TEST-036 verifies: REQ-ORACLE-010, SPEC-ORC-004
    /// @notice The stable ceiling applies to the tokens flagged at `initialize`: the launch fixture flags both tokens of
    /// the USDC/USDT market, so both are valued at most $1.00; a second LPOracle of the same market initialized with
    /// token1 not flagged values token1 uncapped at $1.01 while token0 at $1.05 is valued at $1.00. The flags cannot
    /// be set again: `initialize` runs once.
    function test_TEST_036_stableFlagsSetAtInitialize() public {
        _stable();
        InitParams memory p = _params();
        p.isUsdStable[1] = false;
        p.config.usdBandLow = 0;
        p.config.usdBandHigh = type(uint256).max;
        store.setConfig(p.config);
        LPOracleCL other =
            LPOracleCL(address(new ERC1967Proxy(address(implementation), abi.encodeCall(ILPOracle.initialize, (p)))));
        vm.roll(block.number + 1);
        p0Feed.push(105_000_000, T1);
        a0Feed.push(105_000_000, T1);
        s0Feed.push(105_000_000, T1);
        p1Feed.push(101_000_000, T1);
        a1Feed.push(101_000_000, T1);
        s1Feed.push(101_000_000, T1);
        PriceStateView memory v = other.getPriceState();
        assertEq(v.tokens[0].quote, 105_000_000, "uncapped quote");
        assertEq(v.tokens[0].valuationPrice, ONE, "flagged: capped at the ceiling");
        assertEq(v.tokens[1].valuationPrice, 101_000_000, "not flagged: not capped");
        PriceStateView memory both = _state();
        assertEq(both.tokens[0].valuationPrice, ONE, "launch market: token0 flagged");
        assertEq(both.tokens[1].valuationPrice, ONE, "launch market: token1 flagged");
        vm.expectRevert();
        other.initialize(p);
    }

    // ─── Selector inventory ───

    // TEST-168 verifies: REQ-ORACLE-007
    /// @notice No code of the LPOracle (implementation and its five logic contracts) dispatches a pause, freeze,
    /// pool-broken flag, keeper suspension, quarantine, incident clock, tolerance override or route switch: the only
    /// pause state is the MarketRegistry's. `poke()` is found, so the scan reads the dispatcher.
    function test_TEST_168_noPauseOrOverrideSelector() public {
        address m = address(new LPOracleCLModuleLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7));
        address pk = address(new LPOracleCLPokeLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        address ls = address(new LPOracleCLListingLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        address it = address(new LPOracleCLInitLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        address vw = address(new LPOracleCLViewLogic(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m));
        LPOracleCL impl =
            new LPOracleCL(tl, BLOCK_TIME, POKE_FLOOR, POKE_CEILING, false, 7, m, LPOracleLogicSet(pk, it, ls, vw));
        assertTrue(address(impl).code.pushesSelector(0, address(impl).code.length, ILPOracle.poke.selector), "control");
        string[14] memory forbidden = [
            "pause()",
            "unpause()",
            "paused()",
            "pause(uint8)",
            "freeze()",
            "freezeMarket(uint256)",
            "setPoolBroken(bool)",
            "suspendKeeper(address)",
            "quarantine(address)",
            "setQuarantine(bool)",
            "incidentStartedAt()",
            "setToleranceOverride(uint256,uint16)",
            "disableRoute(uint8,uint8)",
            "setRouteEnabled(uint8,uint8,bool)"
        ];
        address[6] memory codes = [address(impl), m, pk, ls, it, vw];
        for (uint256 c = 0; c < codes.length; ++c) {
            bytes memory code = codes[c].code;
            for (uint256 i = 0; i < forbidden.length; ++i) {
                assertFalse(code.pushesSelector(0, code.length, bytes4(keccak256(bytes(forbidden[i])))), forbidden[i]);
            }
        }
    }
}
