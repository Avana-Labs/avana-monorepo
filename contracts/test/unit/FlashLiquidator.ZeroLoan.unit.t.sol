// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "../../src/periphery/flash-liquidator/IFlashLiquidatorEvents.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";

/// @notice The operator helper with `F = 0` (2.11 `REQ-HELPER-003`, `REQ-HELPER-011`): no loan is taken, the funding
/// Safe pays `X + maxShortfall`, `liquidate` runs directly, and `minPayout`, the outlay bound and the single-use context
/// hold as with a loan. The public helper still refuses `F = 0`.
contract FlashLiquidatorZeroLoanUnitTest is FlashLiquidatorFixture {
    uint256 internal constant X_FLOOR = 12_000e6;
    uint256 internal constant MIN_REC = 12_297.373998e6;
    uint256 internal constant R_FLOOR = 12_174e6;

    function setUp() public {
        _deployHelpers();
    }

    function _signerLiquidates(
        FlashLiquidationRequest memory request
    ) internal returns (uint256) {
        vm.prank(signer);
        return opHelper.flashLiquidate(request);
    }

    function _assertHelperEmpty() internal view {
        assertEq(usdcToken.balanceOf(address(opHelper)), 0, "helper holds no debt asset");
        assertEq(usdcToken.allowance(address(opHelper), address(lvs)), 0, "no LPVaultSwap allowance");
        assertEq(usdcToken.allowance(address(opHelper), address(aavePool)), 0, "no Pool allowance");
    }

    /// @notice Bob's 1,950 USDC liquidation with `F = 0`: the Safe pays 1,950 USDC, LPVaultSwap pays the helper
    /// `keeperOut = 2,020.8` USDC, no lender is called and the whole `keeperOut` returns to the Safe.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-008, REQ-HELPER-011
    function test_TEST_174_operatorZeroLoanFundedBySafe() public {
        _fund(safe, address(opHelper), 1950e6);
        uint256 poolBefore = usdcToken.balanceOf(aUsdc);
        vm.expectEmit(true, true, true, true, address(opHelper));
        emit IFlashLiquidatorEvents.FlashLiquidated(signer, safe, address(usdcToken), 0, 0, 2020.8e6, 0, 2020.8e6);
        uint256 payout = _signerLiquidates(_request(1950e6, 0, 0, 0, 2020.8e6));
        assertEq(payout, 2020.8e6);
        assertEq(usdcToken.balanceOf(safe), 2020.8e6, "Safe paid X and received keeperOut");
        assertEq(aavePool.flashLoanCalls(), 0, "no loan");
        assertEq(usdcToken.balanceOf(aUsdc), poolBefore, "Pool liquidity untouched");
        assertEq(lvs.lastCaller(), address(opHelper));
        assertEq(lvs.lastKf(), 1950e6);
        _assertHelperEmpty();
    }

    /// @notice With no flash liquidity at all (the Pool's reserve paused and empty, the Pool even recorded as a Hub and
    /// `maxFlashFeeBps = 0`) an `F = 0` call still settles: no lender is read or called. The same state refuses any
    /// `F > 0` call.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-011, REQ-HELPER-013
    function test_TEST_174_operatorZeroLoanNeedsNoLender() public {
        aavePool.setFlags(address(usdcToken), true, false, true, true);
        aavePool.setVirtualBalance(address(usdcToken), 0);
        registry.setHub(address(aavePool), true);
        _setCap(0);
        _fund(safe, address(opHelper), 1950e6);
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        opHelper.flashLiquidate(_request(1950e6, 1, 0, 0, 0));
        assertEq(_signerLiquidates(_request(1950e6, 0, 0, 0, 0)), 2020.8e6);
        assertEq(aavePool.flashLoanCalls(), 0);
    }

    /// @notice The public helper keeps `0 < F`: `F = 0` reverts `InvalidFlashAmount` before any read.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-010, REQ-HELPER-013
    function test_TEST_174_publicHelperRefusesZeroLoan() public {
        _fund(caller, address(helper), 1950e6);
        vm.prank(caller);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashAmount.selector);
        helper.flashLiquidate(_request(1950e6, 0, 0, 0, 0));
        assertEq(lvs.calls(), 0);
    }

    /// @notice `F = 0` still needs `F <= X`-style bounds on X and `maxShortfall`, and only the signer may call.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-011, REQ-HELPER-013
    function test_TEST_174_operatorZeroLoanRequestChecks() public {
        FlashLiquidationRequest memory r = _request(uint256(type(uint128).max) + 1, 0, 0, 0, 0);
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashAmount.selector);
        opHelper.flashLiquidate(r);
        r = _request(1950e6, 0, 0, 0, 0);
        r.params.maxShortfall = uint256(type(uint128).max) + 1;
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashAmount.selector);
        opHelper.flashLiquidate(r);
        r.params.maxShortfall = 0;
        vm.prank(caller);
        vm.expectRevert(IFlashLiquidatorErrors.NotSigner.selector);
        opHelper.flashLiquidate(r);
        assertEq(lvs.calls(), 0);
    }

    /// @notice `minPayout` binds the whole payout with `F = 0`: 2,020.8 USDC returned, a 2,020.800001 USDC minimum
    /// reverts and the Safe keeps its 1,950 USDC.
    // TEST-174 verifies: REQ-HELPER-008, REQ-HELPER-011, REQ-HELPER-014
    function test_TEST_174_operatorZeroLoanMinPayout() public {
        _fund(safe, address(opHelper), 1950e6);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PayoutTooLow.selector, 2020.8e6, 2020.800001e6));
        opHelper.flashLiquidate(_request(1950e6, 0, 0, 0, 2020.800001e6));
        assertEq(usdcToken.balanceOf(safe), 1950e6);
    }

    /// @notice The outlay bound with `F = 0`: the Safe's net outlay is `X + shortfall - keeperOut = D + A - R`. With
    /// `D = 1,950`, `R = 1,900` and `A = 0` it is 50 USDC above the 19.5 USDC bound and reverts; `R = 1,940` costs it
    /// 10 USDC and settles.
    // TEST-174 verifies: REQ-HELPER-011, REQ-HELPER-016
    function test_TEST_174_operatorZeroLoanOutlayBound() public {
        _fund(safe, address(opHelper), 1950e6);
        lvs.setOutcome(D_EXAMPLE, 1900e6, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.OutlayExceeded.selector, 50e6, 19.5e6));
        opHelper.flashLiquidate(_request(1950e6, 0, 0, 0, 0));
        lvs.setOutcome(D_EXAMPLE, 1940e6, 0);
        assertEq(_signerLiquidates(_request(1950e6, 0, 0, 0, 0)), 1940e6);
        assertEq(usdcToken.balanceOf(safe), 1940e6, "the Safe lost 10 USDC, within 19.5");
        _assertHelperEmpty();
    }

    /// @notice The `SPEC-LIQ-019` floor case with `F = 0`: the Safe pays 12,000 USDC and the 200 USDC budget,
    /// LPVaultSwap pulls the 123.373998 USDC gap, and the Safe receives `keeperOut + u = 12,297.373998 + 76.626002 =
    /// 12,374` USDC, a net 174 USDC.
    // TEST-174 verifies: REQ-HELPER-006, REQ-HELPER-008, REQ-HELPER-011, SPEC-LIQ-019
    function test_TEST_174_operatorZeroLoanShortfall() public {
        lvs.setOutcome(X_FLOOR, R_FLOOR, 0);
        lvs.setFloor(MIN_REC);
        _fund(safe, address(opHelper), X_FLOOR + 200e6);
        FlashLiquidationRequest memory r = _request(X_FLOOR, 0, 0, 0, 12_374e6);
        r.params.maxShortfall = 200e6;
        assertEq(_signerLiquidates(r), 12_374e6);
        assertEq(lvs.lastShortfall(), 123.373998e6);
        assertEq(usdcToken.balanceOf(safe), 12_374e6);
        _assertHelperEmpty();
    }

    /// @notice The single-use context holds with `F = 0`: it is marked used before `liquidate` is called and records no
    /// lender, so a callback forged from inside `liquidate` reverts `InvalidFlashCallback` and a nested
    /// `flashLiquidate` reverts `ContextActive`.
    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-005, REQ-HELPER-013
    function test_TEST_174_operatorZeroLoanContextSingleUse() public {
        _fund(safe, address(opHelper), 3900e6);
        bytes memory callback = abi.encodeCall(
            IFlashLiquidator.executeOperation,
            (_list(address(usdcToken)), _amounts(0), _amounts(0), address(opHelper), abi.encode(_params(1950e6)))
        );
        lvs.setHook(address(opHelper), callback);
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        opHelper.flashLiquidate(_request(1950e6, 0, 0, 0, 0));
        bytes memory gho = abi.encodeCall(
            IFlashLiquidator.onFlashLoan, (address(opHelper), address(usdcToken), 0, 0, abi.encode(_params(1950e6)))
        );
        lvs.setHook(address(opHelper), gho);
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        opHelper.flashLiquidate(_request(1950e6, 0, 0, 0, 0));
        lvs.setHook(address(opHelper), abi.encodeCall(IFlashLiquidator.flashLiquidate, (_request(1950e6, 0, 0, 0, 0))));
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.ContextActive.selector);
        opHelper.flashLiquidate(_request(1950e6, 0, 0, 0, 0));
        assertEq(usdcToken.balanceOf(safe), 3900e6, "every refused call left the Safe whole");
    }

    /// @notice Even the Pool itself, calling `executeOperation` from inside an `F = 0` liquidation with arguments that
    /// match the context (`T`, `F = 0`, the `params` hash, the helper as initiator), is refused: the context records
    /// no lender and is already used. The Pool's address runs a relay here; this call takes no loan, so the Pool's own
    /// code is not needed.
    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-005
    function test_TEST_174_operatorZeroLoanPoolCallbackRefused() public {
        _fund(safe, address(opHelper), 1950e6);
        vm.etch(address(aavePool), address(new CallbackRelay(address(opHelper))).code);
        bytes memory callback = abi.encodeCall(
            IFlashLiquidator.executeOperation,
            (_list(address(usdcToken)), _amounts(0), _amounts(0), address(opHelper), abi.encode(_params(1950e6)))
        );
        lvs.setHook(address(aavePool), abi.encodeCall(CallbackRelay.relay, (callback)));
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        opHelper.flashLiquidate(_request(1950e6, 0, 0, 0, 0));
    }

    /// @notice For every recovery, fee and shortfall budget, an `F = 0` call either reverts with the Safe untouched
    /// or leaves it at most `floor(D x MAX_TOP_UP_BPS / 1e4)` poorer, with payout `keeperOut + u` and no loan.
    // TEST-174 verifies: REQ-HELPER-008, REQ-HELPER-011, REQ-HELPER-016
    function testFuzz_TEST_174_operatorZeroLoanBounded(
        uint256 x,
        uint256 d,
        uint256 rec,
        uint256 fee,
        uint256 maxShortfall
    ) public {
        x = bound(x, 1e6, 1_000_000e6);
        d = bound(d, 1, x);
        rec = bound(rec, 0, 2 * d);
        fee = bound(fee, 0, rec / 10);
        maxShortfall = bound(maxShortfall, 0, 10_000e6);
        lvs.setOutcome(d, rec, fee);
        _fund(safe, address(opHelper), x + maxShortfall);
        uint256 before = usdcToken.balanceOf(safe);
        FlashLiquidationRequest memory r = _request(x, 0, 0, 0, 0);
        r.params.maxShortfall = maxShortfall;
        vm.prank(signer);
        try opHelper.flashLiquidate(r) returns (uint256 payout) {
            uint256 after_ = usdcToken.balanceOf(safe);
            assertEq(after_, before - x - maxShortfall + payout, "payout is all that returned");
            assertEq(payout, lvs.lastKeeperOut() + maxShortfall - lvs.lastShortfall(), "payout = keeperOut + u");
            uint256 loss = before > after_ ? before - after_ : 0;
            assertLe(loss, (d * OPERATOR_TOP_UP_BPS) / 10_000, "Safe loss within MAX_TOP_UP_BPS of D");
            _assertHelperEmpty();
        } catch {
            assertEq(usdcToken.balanceOf(safe), before, "a refused call leaves the Safe whole");
        }
        assertEq(aavePool.flashLoanCalls(), 0, "never a loan");
    }

    function _list(
        address a
    ) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _amounts(
        uint256 a
    ) internal pure returns (uint256[] memory l) {
        l = new uint256[](1);
        l[0] = a;
    }
}

/// @notice Relays one call to a fixed target and bubbles its revert; etched at the Pool's address so a callback
/// arrives with `msg.sender == POOL`.
contract CallbackRelay {
    address internal immutable TARGET;

    constructor(
        address target
    ) {
        TARGET = target;
    }

    function relay(
        bytes calldata data
    ) external {
        (bool ok, bytes memory ret) = TARGET.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
