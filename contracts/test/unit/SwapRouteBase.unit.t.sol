// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {DexHop} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {RawAnswer} from "../utils/mocks/RouteReadTargets.sol";
import {MockCurvePool} from "../utils/mocks/SwapRouteMocks.sol";

/// @title SwapRouteBaseUnitTest
/// @notice The parts every route type shares (`SwapRouteBase`), driven through a one-hop `DexPathRoute` on the real
/// Lock: the constructor's Lock-wiring reads against a Lock that has no code, reverts, answers short or answers a
/// dirty word; the token-class mask over every value; the order of the `swap` checks (caller, Lock, zero amount, zero
/// minimum) before any transfer; the measured input at exactly, one above and one below `amountIn`; and the output
/// measured as LPVaultSwap's rise, a fee on the debt asset included.
contract SwapRouteBaseUnitTest is SwapRouteFixture {
    MockCurvePool internal curve;
    DexHop[] internal oneHop;

    function setUp() public override {
        super.setUp();
        curve = _curvePool(usdt, usdc, 1, 1);
        oneHop.push(_curveHop(address(curve), address(usdc), 0, 1));
    }

    function _route() internal returns (DexPathRoute) {
        return new DexPathRoute(_config(address(usdt), address(usdc)), oneHop);
    }

    // ─── Constructor (REQ-ROUTE-045) ───

    // TEST-054 verifies: REQ-ROUTE-007, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (the Lock's members equal the route's; a read that fails fails the check)
    /// @notice A Lock address with no code, a Lock whose getters revert, answer 31 bytes or answer a word with bits
    /// above 160 are each refused with `InvalidRouteConfig`; the chain's Lock is accepted.
    function test_TEST_054_lockWiringReadsFailClosed() public {
        RouteConfig memory c = _config(address(usdt), address(usdc));
        c.lock = makeAddr("lockWithoutCode");
        _expectBad(c);
        RawAnswer bad = new RawAnswer();
        c.lock = address(bad);
        bad.setReverts(true);
        _expectBad(c);
        bad.setReverts(false);
        bad.set(new bytes(31));
        _expectBad(c);
        bad.set(abi.encode(uint256(uint160(address(swapper))) | (uint256(1) << 160)));
        _expectBad(c);
        // A Lock answering the same member for both getters is a Lock of other members.
        bad.set(abi.encode(address(swapper)));
        _expectBad(c);
        DexPathRoute ok = _route();
        assertEq(ok.LP_VAULT_SWAP(), address(swapper));
    }

    // TEST-054 verifies: REQ-ROUTE-045, REQ-ROUTE-002
    // Sources: 2.12 REQ-ROUTE-045 (bits 1 to 3 only, at least one)
    /// @notice Every mask is accepted exactly when it is non-zero and sets no bit outside 1 to 3; an accepted route
    /// supports token class `c` exactly when `1 <= c <= 3` and bit `c` is set, for every `c` of `uint8`.
    function testFuzz_TEST_054_tokenClassMask(
        uint8 mask
    ) public {
        RouteConfig memory c = _config(address(usdt), address(usdc));
        c.tokenClassMask = mask;
        bool valid = mask != 0 && mask & ~uint8(0x0E) == 0;
        if (!valid) {
            _expectBad(c);
            return;
        }
        DexPathRoute route = new DexPathRoute(c, oneHop);
        for (uint256 cls = 0; cls < 256; ++cls) {
            bool expected = cls >= 1 && cls <= 3 && (mask >> cls) & 1 == 1;
            assertEq(route.supportsTokenClass(uint8(cls)), expected, "class support");
        }
    }

    // TEST-054 verifies: REQ-ROUTE-045
    /// @notice The seven valid masks are all accepted and report their classes; the routes record no factory beyond
    /// the configured ones.
    function test_TEST_054_everyValidMaskAccepted() public {
        for (uint8 mask = 2; mask <= 14; mask += 2) {
            RouteConfig memory c = _config(address(usdt), address(usdc));
            c.tokenClassMask = mask;
            DexPathRoute route = new DexPathRoute(c, oneHop);
            assertEq(route.supportsTokenClass(1), mask & STABLE != 0);
            assertEq(route.supportsTokenClass(2), mask & CORRELATED != 0);
            assertEq(route.supportsTokenClass(3), mask & VOLATILE != 0);
            (address v3, address slip, address crv) = route.poolFactories();
            assertEq(v3, address(v3Factory));
            assertEq(slip, address(slipFactory));
            assertEq(crv, address(curveFactory));
        }
    }

    // ─── swap: check order (REQ-ROUTE-007, REQ-ROUTE-042) ───

    // TEST-046 verifies: REQ-ROUTE-007, REQ-ROUTE-042, REQ-ROUTE-008
    // Sources: 2.12 REQ-ROUTE-042 (ZeroMinOut after NotLPVaultSwap, NotLocked and the zero-amount TransferMismatch)
    /// @notice With every input wrong at once, the errors come in the specified order: a stranger gets
    /// `NotLPVaultSwap` even with the Lock free and zero amounts; LPVaultSwap with the Lock free gets `NotLocked`; under
    /// the Lock a zero amount gets `TransferMismatch` before a zero minimum's `ZeroMinOut`; no token moves.
    function test_TEST_046_swapCheckOrder() public {
        DexPathRoute route = _route();
        usdt.mint(address(swapper), 1e6);
        usdt.setRevertOnZero(true);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        route.swap(0, 0);
        vm.prank(address(adapter));
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        route.swap(0, 0);
        vm.expectRevert(ISettlementRoute.NotLocked.selector);
        swapper.swapHeld(route, 0, 0);
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 0, 0);
        vm.expectRevert(ISettlementRoute.ZeroMinOut.selector);
        swapper.swapUnderLock(route, 1e6, 0);
        assertEq(usdt.balanceOf(address(swapper)), 1e6, "nothing pulled");
        assertEq(usdt.balanceOf(address(route)), 0);
    }

    // ─── Measured input (REQ-ROUTE-008) ───

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-009, REQ-ROUTE-016
    // Sources: 2.12 REQ-ROUTE-008 (a rise below amountIn is what the legs swap)
    /// @notice A transfer that credits exactly `amountIn` swaps it all; one that credits one unit less (a rebasing
    /// token rounding down) swaps `amountIn - 1` and `minOut = amountIn` then fails `MinOutNotMet(amountIn - 1,
    /// amountIn)`; one that credits nothing reverts `TransferMismatch`. The route ends with no balance.
    function test_TEST_221_measuredInputExactAndOneBelow() public {
        DexPathRoute route = _route();
        assertEq(_swap(route, 5_000_000, 5_000_000), 5_000_000, "exact");
        usdt.setDrain(1);
        assertEq(_swap(route, 5_000_000, 4_999_999), 4_999_999, "one unit short: the legs run on what arrived");
        usdt.mint(address(swapper), 5_000_000);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 4_999_999, 5_000_000));
        swapper.swapUnderLock(route, 5_000_000, 5_000_000);
        usdt.setDrain(5_000_000);
        vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
        swapper.swapUnderLock(route, 5_000_000, 1);
        assertEq(usdt.balanceOf(address(route)), 0);
        assertEq(usdc.balanceOf(address(route)), 0);
    }

    // TEST-221 verifies: REQ-ROUTE-008
    /// @notice Any credit above the request reverts `TransferMismatch`, whatever its size; any credit at or below it
    /// that is not zero swaps exactly the credit.
    function testFuzz_TEST_221_measuredInput(
        uint256 amountIn,
        uint256 bonus,
        uint256 drain
    ) public {
        amountIn = bound(amountIn, 2, 1e15);
        DexPathRoute route = _route();
        usdt.mint(address(swapper), amountIn);
        if (bonus % 2 == 0) {
            usdt.setBonus(bound(bonus, 1, 1e15));
            vm.expectRevert(ISettlementRoute.TransferMismatch.selector);
            swapper.swapUnderLock(route, amountIn, 1);
            return;
        }
        drain = bound(drain, 0, amountIn - 1);
        usdt.setDrain(drain);
        uint256 out = swapper.swapUnderLock(route, amountIn, amountIn - drain);
        assertEq(out, amountIn - drain, "the legs swap the credit");
        assertEq(usdc.balanceOf(address(swapper)), out);
    }

    // ─── Output (REQ-ROUTE-009, REQ-ROUTE-014) ───

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-014, REQ-ROUTE-042, REQ-ROUTE-044
    // Sources: 2.12 REQ-ROUTE-009 (out is LPVaultSwap's rise; a fee on the debt asset only lowers it)
    /// @notice With a 25 bps fee on the debt asset the pool's 1,000,000 units reach the route as 997,500 and
    /// LPVaultSwap as 995,007 (each transfer pays the fee): `swap` returns 995,007, a minimum of 995,007 passes and one
    /// of 995,008 reverts `MinOutNotMet(995007, 995008)`; the route keeps nothing.
    function test_TEST_232_feeOnTheDebtAssetLowersTheMeasuredOutput() public {
        DexPathRoute route = _route();
        usdc.setFeeBps(25);
        assertEq(_swap(route, 1_000_000, 995_007), 995_007, "LPVaultSwap's rise");
        assertEq(usdc.balanceOf(address(route)), 0, "the route forwarded all it received");
        usdt.mint(address(swapper), 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 995_007, 995_008));
        swapper.swapUnderLock(route, 1_000_000, 995_008);
    }

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-042
    /// @notice The minimum is checked once, on the output: at a rate `num / den` the output is
    /// `floor(amountIn x num / den)`, a minimum equal to it passes and one unit more reverts with the exact pair.
    function testFuzz_TEST_232_minOutBoundary(
        uint256 amountIn,
        uint256 num,
        uint256 den
    ) public {
        amountIn = bound(amountIn, 1, 1e18);
        num = bound(num, 1, 1e6);
        den = bound(den, 1, 1e6);
        curve.setRate(num, den);
        DexPathRoute route = _route();
        uint256 expected = amountIn * num / den;
        usdt.mint(address(swapper), 2 * amountIn);
        if (expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
            swapper.swapUnderLock(route, amountIn, 1);
            return;
        }
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, expected, expected + 1));
        swapper.swapUnderLock(route, amountIn, expected + 1);
        assertEq(swapper.swapUnderLock(route, amountIn, expected), expected);
        assertEq(usdt.allowance(address(route), address(curve)), 0, "no allowance left");
    }

    // TEST-080 verifies: REQ-ROUTE-016, INV-021
    // Sources: 2.12 REQ-ROUTE-016 (a token sent to a route outside a call never counts)
    /// @notice Balances the route held before a call (its input and its output) stay with it and count toward neither
    /// the legs, the residue nor the output: a 1,000,000-unit swap still returns exactly 1,000,000.
    function test_TEST_080_preexistingRouteBalancesNeverCount() public {
        DexPathRoute route = _route();
        usdt.mint(address(route), 777);
        usdc.mint(address(route), 999);
        assertEq(_swap(route, 1_000_000, 1_000_000), 1_000_000);
        assertEq(usdt.balanceOf(address(route)), 777, "input donation untouched");
        assertEq(usdc.balanceOf(address(route)), 999, "output donation untouched");
        assertEq(usdt.balanceOf(address(swapper)), 0, "no residue invented");
    }

    function _expectBad(
        RouteConfig memory c
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(c, oneHop);
    }
}
