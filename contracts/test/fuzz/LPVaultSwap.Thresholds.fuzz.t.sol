// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapThresholdsFuzzTest
/// @notice The exact boundaries of every caller parameter of `liquidate` (2.11 REQ-SWAP-030, REQ-SWAP-073,
/// REQ-SWAP-074, SPEC-LIQ-019): `deadline` (now settles, one second earlier reverts `DeadlineExpired(deadline)`),
/// `minPayout` (equal to `keeperOut` settles, one more reverts `PayoutTooLow(keeperOut, minPayout)`), `maxShortfall`
/// (equal to the gap settles, one less reverts `RecoveryBelowFloor`), `debtToCover` (0 reverts `InvalidAmount`) and
/// `minAmounts` (empty or one entry per pool token; any other length reverts). Each boundary is found from a probe of
/// the same liquidation, so the test fails if a comparison is moved by one or inverted.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapThresholdsFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _probe(
        LiquidationParams memory p
    ) internal returns (LiquidationResult memory r) {
        uint256 snapshot = vm.snapshotState();
        r = _liquidateAs(keeper, p);
        vm.revertToState(snapshot);
    }

    /// @notice `deadline ≥ block.timestamp` settles; `deadline < block.timestamp` reverts with the deadline.
    // TEST-174 verifies: REQ-SWAP-030, REQ-SWAP-074
    function testFuzz_TEST_174_deadlineBoundary(
        uint256 back,
        uint256 ahead
    ) public {
        vm.warp(1_800_000_000);
        back = bound(back, 1, 1_000_000);
        ahead = bound(ahead, 0, 1_000_000);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.deadline = block.timestamp - back;
        _expectLiquidateRevert(
            keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.DeadlineExpired.selector, p.deadline)
        );
        p.deadline = block.timestamp + ahead;
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertGt(r.unitsSeized, 0, "a deadline at or after now settles");
    }

    /// @notice `minPayout = keeperOut` settles with exactly that payout; `keeperOut + k` reverts `PayoutTooLow`.
    // TEST-174 verifies: REQ-SWAP-073, SPEC-LIQ-010
    function testFuzz_TEST_174_minPayoutBoundary(
        uint256 debtToCover,
        uint256 extra
    ) public {
        debtToCover = bound(debtToCover, 50e6, 6000e6);
        extra = bound(extra, 1, 1e12);
        LiquidationParams memory p = _params(proxy, debtToCover);
        LiquidationResult memory probe = _probe(p);
        p.minPayout = probe.keeperOut + extra;
        _expectLiquidateRevert(
            keeper,
            p,
            abi.encodeWithSelector(ILPVaultSwapErrors.PayoutTooLow.selector, probe.keeperOut, probe.keeperOut + extra)
        );
        p.minPayout = probe.keeperOut;
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertEq(r.keeperOut, probe.keeperOut, "same payout at the boundary");
    }

    /// @notice With the vault priced at $2.15 while its released tokens are worth $2.09 a unit at the legs' prices,
    /// every leg meets its minimum and the recovery falls below the floor by a gap `g`: `maxShortfall = g` settles with
    /// `shortfall = g` pulled from the caller and `R + shortfall = minRec`; `g − 1` reverts `RecoveryBelowFloor`.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-026, REQ-SWAP-111
    function testFuzz_TEST_233_maxShortfallBoundary(
        uint256 debtToCover
    ) public {
        debtToCover = bound(debtToCover, 500e6, 6000e6);
        lpOracle.setAnswer(215_000_000);
        LiquidationParams memory p = _params(proxy, debtToCover);
        p.maxShortfall = type(uint128).max;
        _fund(usdc, keeper, debtToCover + type(uint128).max);
        uint256 snapshot = vm.snapshotState();
        vm.prank(keeper);
        LiquidationResult memory probe = lvs.liquidate(p);
        vm.revertToState(snapshot);
        uint256 gap = probe.shortfall;
        if (gap == 0) return;
        assertEq(probe.recovered + gap, probe.minOut, "the top-up closes the floor exactly");
        p.maxShortfall = gap - 1;
        vm.prank(keeper);
        vm.expectRevert(ILPVaultSwapErrors.RecoveryBelowFloor.selector);
        lvs.liquidate(p);
        p.maxShortfall = gap;
        uint256 before = usdc.balanceOf(keeper);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.shortfall, gap, "shortfall = g");
        assertEq(usdc.balanceOf(keeper), before - r.callerFunds - gap + r.keeperOut, "gap pulled from the caller");
    }

    /// @notice `debtToCover = 0` reverts `InvalidAmount`; a `minAmounts` vector of any length other than 0 or the
    /// market's two tokens reverts before any state changes.
    // TEST-174 verifies: REQ-SWAP-030, REQ-SWAP-077
    function testFuzz_TEST_174_amountAndMinAmountsShape(
        uint8 length
    ) public {
        LiquidationParams memory p = _params(proxy, 0);
        _expectLiquidateRevert(keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.InvalidAmount.selector));
        p.debtToCover = 1950e6;
        uint256 n = bound(length, 0, 8);
        p.minAmounts = new uint256[](n);
        if (n == 0 || n == 2) {
            LiquidationResult memory r = _liquidateAs(keeper, p);
            assertGt(r.unitsSeized, 0, "an empty or full vector settles");
        } else {
            _fund(usdc, keeper, 1950e6);
            uint256 debt = _debtOf(proxy, usdcReserveId);
            vm.prank(keeper);
            vm.expectRevert();
            lvs.liquidate(p);
            assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
        }
    }

    /// @notice Per-token minimums at the release are honoured exactly: the amounts the unwind returns settle, one more
    /// on either token reverts in the release.
    // TEST-047 verifies: REQ-SWAP-016, REQ-SWAP-045
    function testFuzz_TEST_047_minAmountsAtTheRelease(
        uint256 debtToCover,
        bool second
    ) public {
        debtToCover = bound(debtToCover, 50e6, 6000e6);
        LiquidationParams memory p = _params(proxy, debtToCover);
        LiquidationResult memory probe = _probe(p);
        p.minAmounts = new uint256[](2);
        (p.minAmounts[0], p.minAmounts[1]) = (probe.amountsOut[0], probe.amountsOut[1]);
        if (second) p.minAmounts[1] += 1;
        else p.minAmounts[0] += 1;
        _fund(usdc, keeper, debtToCover);
        vm.prank(keeper);
        vm.expectRevert();
        lvs.liquidate(p);
        (p.minAmounts[0], p.minAmounts[1]) = (probe.amountsOut[0], probe.amountsOut[1]);
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertEq(r.amountsOut[0], probe.amountsOut[0], "USDC at its minimum");
        assertEq(r.amountsOut[1], probe.amountsOut[1], "USDT at its minimum");
    }

    /// @notice A frozen caller is refused with its own address whatever the parameters; unfreezing restores it.
    // TEST-229 verifies: REQ-SWAP-105, REQ-SWAP-109
    function testFuzz_TEST_229_frozenCaller(
        address caller
    ) public {
        vm.assume(caller != address(0) && caller.code.length == 0 && uint160(caller) > 0xffff);
        vm.assume(caller != address(lvs) && caller != bob && caller != aave.cdpSpoke);
        registry.setFrozen(caller, true);
        _expectLiquidateRevert(
            caller, _params(proxy, 1950e6), abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, caller)
        );
        registry.setFrozen(caller, false);
        LiquidationResult memory r = _liquidateAs(caller, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "unfrozen caller settles");
    }
}
