// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {IDebtOracleErrors} from "../../src/oracle/debt-oracle/IDebtOracleErrors.sol";
import {IDebtOracleEvents} from "../../src/oracle/debt-oracle/IDebtOracleEvents.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {HostileConfig} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DebtOracleInitializeUnitTest
/// @notice What `initialize` seeds and refuses (REQ-ORACLE-059, REQ-ORACLE-091, REQ-ORACLE-092): a seed from the
/// alternate when the primary is invalid, with the route, version, window and stress rise it read stored so the first
/// poke changes nothing it already knew; `NotLive(state, reasons)` with the exact state and reasons for each way the
/// first evaluation is not Live; and the gas guard, which makes a starved read revert `InsufficientGas` and never
/// report a healthy asset as failed (REQ-ORACLE-102).
contract DebtOracleInitializeUnitTest is DebtOracleFixture {
    bytes32 internal constant ROUTE_CHANGED = keccak256("DebtRouteChanged(uint8,uint8)");
    bytes32 internal constant VERSION_OBSERVED = keccak256("DebtRouteVersionObserved(uint64,uint64)");

    function setUp() public {
        _deployDebtOracle();
    }

    function _deploy() internal returns (IDebtOracle) {
        return
            IDebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(IDebtOracle.initialize, (_params())))));
    }

    // TEST-231 verifies: REQ-ORACLE-059, REQ-ORACLE-091, REQ-ORACLE-005, REQ-ORACLE-092, REQ-ORACLE-095
    // Sources: 2.10 REQ-ORACLE-059 (initialize seeds from a Live evaluation, alternate included)
    /// @notice With the primary invalid, and the route version at 3 after a standby switch and its restore, `initialize`
    /// seeds the alternate's quote with the alternate's timestamp and stores route Alternate and version 3: the first
    /// poke emits no route change and no version observation.
    function test_TEST_231_seedFromTheAlternateAndNoFirstPokeNoise() public {
        vm.warp(T0 + 50);
        pUsd.push(0, T0 + 50);
        aEth.push(USDC_ETH, T0 + 40);
        ethUsd.push(ETH_USD, T0 + 45);
        reg.useStandby(usdc, RouteSlot.Primary);
        reg.restore(usdc);
        vm.expectEmit(true, true, true, true);
        emit IDebtOracleEvents.DebtPriceSeeded(99_990_000, uint64(T0 + 40));
        IDebtOracle fresh = _deploy();
        (uint256 price, uint64 at) = fresh.lastAcceptedPrice();
        assertEq(price, 99_990_000);
        assertEq(at, T0 + 40, "the alternate's oldest leg");
        DebtPriceView memory v = fresh.getPriceState();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Alternate));
        assertEq(v.routeVersion, 3);
        vm.recordLogs();
        fresh.poke{gas: 5_000_000}();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ROUTE_CHANGED, "route already Alternate");
            assertTrue(logs[i].topics[0] != VERSION_OBSERVED, "version already 3");
        }
    }

    // TEST-231 verifies: REQ-ORACLE-059, REQ-ORACLE-076, REQ-ORACLE-017, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-076 (initialize reverts unless the first evaluation is Live)
    /// @notice `initialize` reverts `NotLive(2, 1)` (Cached, NO_ROUTE) when both routes are invalid, and `NotLive(2, 4)`
    /// (Cached, CONFIG_UNAVAILABLE) when a configuration read fails.
    function test_TEST_231_notLiveCarriesTheExactStateAndReasons() public {
        pUsd.push(0, block.timestamp);
        aEth.push(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.NotLive.selector, uint8(2), uint256(1)));
        _deploy();
        pUsd.push(USDC_USD, block.timestamp);
        aEth.push(USDC_ETH, block.timestamp);
        store.setMode(store.graceDuration.selector, HostileConfig.Mode.Revert);
        vm.expectRevert(abi.encodeWithSelector(IDebtOracleErrors.NotLive.selector, uint8(2), uint256(1 << 2)));
        _deploy();
    }

    // TEST-219 verifies: REQ-ORACLE-092, SPEC-ORC-013, SPEC-ORC-018
    // Sources: 2.10 SPEC-ORC-013 (lastCachedWindow is the window initialize read until a poke reads another)
    /// @notice A DebtOracle initialized with a 100-second window and a 300 bps rise keeps both as its fallbacks before
    /// any poke: with the store later answering 5,000 s and 900 bps but both reads failing, a failure is Expired after
    /// 100 s and served at the 300 bps rise.
    function test_TEST_219_initializeStoresTheFallbackWindowAndRise() public {
        store.setTimers(100, 3600, 1800);
        store.setStressRise(usdc, 300);
        IDebtOracle fresh = _deploy();
        store.setTimers(5000, 3600, 1800);
        store.setStressRise(usdc, 900);
        store.setMode(store.cachedWindow.selector, HostileConfig.Mode.Revert);
        store.setMode(store.debtStressRiseBps.selector, HostileConfig.Mode.Revert);
        uint256 t = block.timestamp;
        // A poke records the failure start; it reads neither value, so it stores neither.
        fresh.poke{gas: 5_000_000}();
        DebtPriceView memory v = fresh.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Cached));
        assertEq(v.cachedUntil, t + 100, "initialize's window");
        vm.warp(t + 100);
        v = fresh.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        assertEq(v.debtStressRiseBps, 300, "initialize's rise");
        assertEq(uint256(v.answer), 102_989_700, "ceil(99,990,000 x 10,300 / 10,000)");
    }

    // TEST-042 verifies: REQ-ORACLE-102, SPEC-ORC-023, REQ-ORACLE-039, REQ-ORACLE-092
    // Sources: 2.10 REQ-ORACLE-102 (no caller can make a healthy feed look failed)
    /// @notice For any gas a caller gives a view, the healthy asset is either reported Live at its quote or the view
    /// reverts `InsufficientGas(gasLeft, required)` with `gasLeft < required`; it is never reported failed.
    function testFuzz_TEST_042_starvedViewNeverReportsFailure(
        uint256 gas
    ) public view {
        gas = bound(gas, 30_000, 1_500_000);
        (bool ok, bytes memory ret) =
            address(oracle).staticcall{gas: gas}(abi.encodeCall(IDebtOracle.getPriceState, ()));
        if (ok) {
            DebtPriceView memory v = abi.decode(ret, (DebtPriceView));
            assertEq(uint8(v.state), uint8(PriceState.Live), "a healthy asset");
            assertEq(uint256(v.answer), 99_990_000);
            assertTrue(v.borrowAllowed);
        } else if (ret.length != 0) {
            assertEq(bytes4(ret), IDebtOracleErrors.InsufficientGas.selector, "only the gas guard reverts");
            (uint256 left, uint256 required) = abi.decode(_tail(ret), (uint256, uint256));
            assertLt(left, required);
        }
    }

    function _tail(
        bytes memory ret
    ) internal pure returns (bytes memory t) {
        t = new bytes(ret.length - 4);
        for (uint256 i = 0; i < t.length; ++i) {
            t[i] = ret[i + 4];
        }
    }
}
