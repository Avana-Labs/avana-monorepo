// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "../../src/policy/parameter-store/IParameterStoreBreakers.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreLiquidation} from "../../src/policy/parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreLoosen} from "../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice Setters reached through real AvanaTimelock operations: tightenings at the short delay, loosenings and
/// structural changes at the normal delay, and the predicates evaluated at execution.
contract ParameterStoreTimelockUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    // TEST-063 verifies: REQ-PSTORE-002, REQ-CONFIG-051, REQ-CONFIG-053, REQ-ACCESS-155
    function test_TEST_063_tightenSelectorsTakeTheShortDelay() public {
        bytes[8] memory data = [
            abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (M, 4_000_000e8)),
            abi.encodeCall(IParameterStoreTighten.tightenHardHealthFloor, (M, 1.1e18)),
            abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 40)),
            abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (M, 20e8)),
            abi.encodeCall(IParameterStoreBreakers.tightenGateRecoverySeconds, (3600)),
            abi.encodeCall(IParameterStoreLiquidation.tightenMaxShortfallBps, (50)),
            abi.encodeCall(IParameterStoreAdmin.tightenMaxFlashFeeBps, (0)),
            abi.encodeCall(IParameterStoreTighten.tightenPoolShareMaxBpsOf, (M, 1000))
        ];
        for (uint256 i = 0; i < data.length; ++i) {
            Call[] memory calls = _one(address(store), data[i]);
            assertEq(_required(calls), SHORT_DELAY, "tighten not short");
            _run(calls, bytes32(i));
        }
        assertEq(store.marketUsdCap(M), 4_000_000e8);
        assertEq(store.hardHealthFloor(M), 1.1e18);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 40);
        assertEq(store.maxFlashFeeBps(), 0);
    }

    // TEST-063 verifies: REQ-CONFIG-053, REQ-CONFIG-054, REQ-PSTORE-002, REQ-CONFIG-071
    function test_TEST_063_loosenAndStructuralTakeTheNormalDelay() public {
        bytes[5] memory data = [
            abi.encodeCall(IParameterStoreLoosen.loosenMarketUsdCap, (M, 6_000_000e8)),
            abi.encodeCall(IParameterStoreLoosen.loosenPoolShareMaxBpsOf, (M, 10_000)),
            abi.encodeCall(IParameterStoreAdmin.setGraceDuration, (3600)),
            abi.encodeCall(IParameterStoreAdmin.setMaxFlashFeeBps, (20)),
            abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 125))
        ];
        for (uint256 i = 0; i < data.length; ++i) {
            assertEq(_required(_one(address(store), data[i])), NORMAL_DELAY, "loosen or set not normal");
        }
        // One loosening in a batch of tightenings makes the whole batch wait the normal delay.
        Call[] memory mixed = _two(
            Call(address(store), abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (M, 20e8))),
            Call(address(store), data[0])
        );
        assertEq(_required(mixed), NORMAL_DELAY);
        // A short-delay schedule of a loosening is refused by the timelock.
        Call[] memory one = _one(address(store), data[0]);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(one);
        vm.prank(governanceMultisig);
        vm.expectRevert();
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32("short"), SHORT_DELAY);
        _run(one, bytes32("loosen"));
        assertEq(store.marketUsdCap(M), 6_000_000e8);
    }

    // TEST-063 verifies: REQ-PSTORE-017, REQ-CONFIG-071, SPEC-GOV-011
    function test_TEST_063_spacingEvaluatedAtExecution() public {
        // Two loosenings scheduled together still execute one normal delay apart.
        Call[] memory first =
            _one(address(store), abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 125)));
        Call[] memory second =
            _one(address(store), abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 150)));
        _schedule(governanceMultisig, first, NORMAL_DELAY, bytes32("a"));
        _schedule(governanceMultisig, second, NORMAL_DELAY, bytes32("b"));
        vm.warp(block.timestamp + NORMAL_DELAY);
        _execute(attacker, first, bytes32("a"));
        uint256 executedAt = block.timestamp;
        bytes32 key = keccak256(abi.encode(bytes32("slippageAllowanceBps"), bytes32(M)));
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(second);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.LoosenTooSoon.selector, key, executedAt + NORMAL_DELAY)
        );
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("b"));
        vm.warp(executedAt + NORMAL_DELAY);
        _execute(attacker, second, bytes32("b"));
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 150);
    }

    // TEST-063 verifies: REQ-CONFIG-071, REQ-CONFIG-051
    function test_TEST_063_tightenPredicateAtExecution() public {
        // A tightening scheduled against 100 bps that a later tightening overtakes fails NotStricter at execution.
        Call[] memory to60 =
            _one(address(store), abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 60)));
        _schedule(governanceMultisig, to60, SHORT_DELAY, bytes32("60"));
        _tl();
        store.tightenSlippageAllowanceBps(M, 40);
        vm.warp(block.timestamp + SHORT_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(to60);
        vm.prank(attacker);
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("60"));
    }
}
