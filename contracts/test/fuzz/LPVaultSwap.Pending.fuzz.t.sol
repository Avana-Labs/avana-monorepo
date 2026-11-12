// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapPendingFuzzTest
/// @notice Pending settlement fuzzed (2.11 REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-070, SPEC-LIQ-014): for any size of an
/// earlier unsettled seizure, any later liquidation that reconciles it, any second seizure not yet reconciled (so
/// LPVaultSwap holds more units than are pending) and any route rate within the pending leg slippage, `settlePending`
/// by any caller burns `x = min(held, pending)` units, releases them, swaps at the pending minimums, and adds exactly
/// the measured `R` to the USDC Coverage Spoke's Hub; the caller receives nothing, a second call finds nothing pending,
/// and units beyond the pending balance stay.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapPendingFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice Any kept seizure, reconciling liquidation, donation and rate: `x = min(held, pending)`, `R` funded.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-070, REQ-SWAP-092, SPEC-LIQ-014, INV-042, Q-201, Q-211
    function testFuzz_TEST_170_settlesMinOfHeldAndPending(
        uint256 keptDebt,
        uint256 later,
        uint256 donated,
        uint256 rateBps,
        address caller
    ) public {
        keptDebt = bound(keptDebt, 50e6, 2000e6);
        later = bound(later, 50e6, 2000e6);
        donated = bound(donated, 0, 500e6); // a second unsettled seizure after the reconcile: held above pending
        rateBps = bound(rateBps, 9980, 10_050);
        vm.assume(caller != address(0) && caller.code.length == 0 && uint160(caller) > 0xffff);
        vm.assume(caller != address(lvs) && caller != bob);
        uint256 kept = _seizeAndKeep(proxy, keptDebt);
        _liquidateAs(keeper, _params(proxy, later));
        uint256 pending = coll.getPending(address(vt)).units;
        assertEq(pending, kept, "the earlier seizure is the pending balance");
        uint256 unreconciled = donated == 0 ? 0 : _seizeAndKeep(proxy, donated);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        uint256 held = vt.balanceOf(address(lvs));
        uint256 x = held < pending ? held : pending;
        uint256 hubBefore = usdc.balanceOf(aave.hub);
        uint256 callerBefore = usdc.balanceOf(caller);
        vm.prank(caller);
        (uint256 units, uint256[] memory amounts, uint256 recovered) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, x, "x = min(held, pending)");
        assertEq(vt.balanceOf(address(lvs)), held - x, "exactly x burned");
        assertEq(vt.balanceOf(address(lvs)), unreconciled, "the unreconciled seizure stays for its own reconcile");
        assertEq(recovered, amounts[0] + amounts[1] * rateBps / 10_000, "R measured over the release and the route");
        assertEq(usdc.balanceOf(aave.hub), hubBefore + recovered, "R added to the Coverage Spoke's Hub");
        assertEq(usdc.balanceOf(caller), callerBefore, "the caller receives nothing");
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
        vm.prank(caller);
        vm.expectRevert(ILPVaultSwapErrors.NothingPending.selector);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice A route paying below the pending leg minimum (`s_P = min(allowance, 30)` bps) fails the leg: with no
    /// working backup the call reverts `NoRouteAvailable` and the pending balance stays for a later call.
    // TEST-232 verifies: SPEC-LIQ-014, SPEC-LIQ-018, REQ-SWAP-071
    function testFuzz_TEST_232_pendingLegMinimum(
        uint256 rateBps
    ) public {
        rateBps = bound(rateBps, 9000, 9900);
        _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        uint256 pending = coll.getPending(address(vt)).units;
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(coll.getPending(address(vt)).units, pending, "pending kept");
        usdtUsdcPool.setRate(9995, 10_000);
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, pending, "settles once the route recovers");
    }

    /// @notice Two reconciled gaps from two accounts of the same market settle together in one call.
    // TEST-170 verifies: REQ-SWAP-066, REQ-SWAP-068, Q-201
    function testFuzz_TEST_170_twoAccountsOnePending(
        uint256 a,
        uint256 b
    ) public {
        a = bound(a, 50e6, 1000e6);
        b = bound(b, 50e6, 1000e6);
        (address carolProxy,) = _openAccount(carol, 1500e6, 2600e6, 250_000_000);
        uint256 k1 = _seizeAndKeep(proxy, a);
        uint256 k2 = _seizeAndKeep(carolProxy, b / 4);
        _liquidateAs(keeper, _params(proxy, 100e6));
        _liquidateAs(keeper, _params(carolProxy, 100e6));
        assertEq(coll.getPending(address(vt)).units, k1 + k2, "both gaps pending");
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, k1 + k2, "one call settles both");
        assertEq(vt.balanceOf(address(lvs)), 0, "nothing left");
    }
}
