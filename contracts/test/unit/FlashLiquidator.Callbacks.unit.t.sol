// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {HelperReenterer} from "../utils/mocks/hostile/HelperReenterer.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The flash liquidation helper's callback binding and single-use context (2.11 `REQ-HELPER-004`,
/// `REQ-HELPER-005`): forged `executeOperation` calls from a non-Pool or through the Pool with a foreign initiator, a
/// reshaped or replayed callback, a second callback, a Pool that never calls back, reentry into `flashLiquidate` and
/// `executeOperation` from inside the liquidation and from inside the payout transfer, and context reuse across calls.
/// @dev `isolate = false`: calls of one test share a transaction, so the transient context would carry between them if
/// it were not cleared.
/// forge-config: default.isolate = false
contract FlashLiquidatorCallbacksUnitTest is FlashLiquidatorFixture {
    function setUp() public {
        _deployHelpers();
    }

    function _liquidate(
        FlashLiquidationRequest memory request
    ) internal returns (uint256) {
        vm.prank(caller);
        return helper.flashLiquidate(request);
    }

    function _one(
        uint256 x
    ) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = x;
    }

    function _oneAsset(
        address x
    ) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = x;
    }

    function _exampleCallback(
        address initiator
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            IFlashLiquidator.executeOperation,
            (
                _oneAsset(address(usdcToken)),
                _one(1950e6),
                _one(975_000),
                initiator,
                abi.encode(_exampleRequest().params)
            )
        );
    }

    // ─── Forged callbacks (no context) ───

    /// @notice Any caller, any arguments, no open context: the callback reverts and moves nothing.
    // TEST-046 verifies: REQ-HELPER-005, REQ-HELPER-013, INV-040, INV-095, Q-045
    function testFuzz_TEST_046_helperForgedCallbackReverts(
        address from,
        address initiator,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) public {
        usdcToken.mint(address(helper), 1000e6);
        vm.prank(from);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        helper.executeOperation(_oneAsset(address(usdcToken)), _one(amount), _one(premium), initiator, params);
        assertEq(usdcToken.allowance(address(helper), from), 0);
        assertEq(usdcToken.balanceOf(address(helper)), 1000e6);
    }

    /// @notice The exact arguments of a real loan, sent by the Pool's address or by anyone with the helper as
    /// initiator, outside a call of the helper.
    // TEST-046 verifies: REQ-HELPER-005, REQ-HELPER-013, INV-040
    function test_TEST_046_helperCallbackOutsideContextReverts() public {
        bytes memory forged = _exampleCallback(address(helper));
        vm.prank(address(aavePool));
        (bool ok, bytes memory ret) = address(helper).call(forged);
        assertFalse(ok);
        assertEq(bytes4(ret), IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        vm.prank(attacker);
        (ok, ret) = address(helper).call(forged);
        assertFalse(ok);
        assertEq(bytes4(ret), IFlashLiquidatorErrors.InvalidFlashCallback.selector);
    }

    /// @notice A third party's own Pool loan naming the helper as receiver: the Pool calls the helper with the third
    /// party as initiator, and the callback reverts.
    // TEST-046 verifies: REQ-HELPER-005, REQ-HELPER-013, INV-040, Q-045
    function test_TEST_046_helperThirdPartyLoanWithHelperAsReceiverReverts() public {
        usdcToken.mint(address(helper), 10e6);
        vm.prank(attacker);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        aavePool.flashLoan(
            address(helper),
            _oneAsset(address(usdcToken)),
            _one(1950e6),
            new uint256[](1),
            attacker,
            abi.encode(_exampleRequest().params),
            0
        );
        assertEq(usdcToken.balanceOf(address(helper)), 10e6);
    }

    // ─── Callbacks inside a real call ───

    /// @notice The Pool calls back with another initiator, two assets, two amounts, two premiums, another asset,
    /// another amount or other data: each reverts `InvalidFlashCallback` before LPVaultSwap is called.
    // TEST-046 verifies: REQ-HELPER-005, REQ-HELPER-013, INV-040
    function test_TEST_046_helperCallbackPoolInitiatorAssetAmountAndHash() public {
        aavePool.setInitiatorOverride(attacker);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        _liquidate(_exampleRequest());
        aavePool.setInitiatorOverride(address(0));
        for (uint8 shape = 1; shape <= 6; ++shape) {
            aavePool.setCallbackShape(shape);
            vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
            _liquidate(_exampleRequest());
        }
        aavePool.setCallbackShape(0);
        assertEq(lvs.calls(), 0);
        _liquidate(_exampleRequest());
        assertEq(lvs.calls(), 1, "the bound callback runs");
    }

    /// @notice A second callback in the same loan reverts: the context is single-use.
    // TEST-046 verifies: REQ-HELPER-005, REQ-HELPER-004, INV-040
    function test_TEST_046_helperSecondCallbackReverts() public {
        _fund(caller, address(helper), 10_000e6);
        aavePool.setCallbackTwice(true);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        _liquidate(_request(1950e6, 1950e6, 975_000, 10_000e6, 0));
    }

    /// @notice A Pool that returns without calling back: `InvalidFlashCallback` after `flashLoan`.
    // TEST-046 verifies: REQ-HELPER-004, REQ-HELPER-013
    function test_TEST_046_helperPoolWithoutCallbackReverts() public {
        _fund(caller, address(helper), 10_000e6);
        aavePool.setSkipCallback(true);
        // It also pulls nothing, so the helper's own check is what stops the call.
        aavePool.setPullShortBy(1950e6 + 975_000);
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        _liquidate(_request(1950e6, 1950e6, 975_000, 0, 0));
    }

    /// @notice A Pool that pulls less than it is owed: the allowance it leaves is withdrawn and the payout counts what
    /// stayed.
    // TEST-174 verifies: REQ-HELPER-001, REQ-HELPER-008
    function test_TEST_174_helperShortPoolPullLeavesNoAllowance() public {
        aavePool.setPullShortBy(1);
        uint256 payout = _liquidate(_exampleRequest());
        assertEq(payout, 69.825e6 + 1);
        assertEq(usdcToken.allowance(address(helper), address(aavePool)), 0);
        assertEq(usdcToken.balanceOf(address(helper)), 0);
    }

    // ─── Reentry ───

    /// @notice From inside `liquidate` (a reentrant route or token): `flashLiquidate` reverts `ContextActive`, before
    /// the operator variant's signer check.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-013
    // TEST-046 verifies: REQ-HELPER-004, INV-040
    function test_TEST_174_helperReentrantFlashLiquidateReverts() public {
        lvs.setHook(address(helper), abi.encodeCall(IFlashLiquidator.flashLiquidate, (_exampleRequest())));
        vm.expectRevert(IFlashLiquidatorErrors.ContextActive.selector);
        _liquidate(_exampleRequest());
        lvs.setHook(address(opHelper), abi.encodeCall(IFlashLiquidator.flashLiquidate, (_exampleRequest())));
        vm.prank(signer);
        vm.expectRevert(IFlashLiquidatorErrors.ContextActive.selector);
        opHelper.flashLiquidate(_exampleRequest());
    }

    /// @notice From inside `liquidate`, a replay of the live callback arguments reverts: the context is used and the
    /// caller is not the Pool.
    // TEST-046 verifies: REQ-HELPER-005, INV-040
    function test_TEST_046_helperReentrantCallbackReverts() public {
        lvs.setHook(address(helper), _exampleCallback(address(helper)));
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        _liquidate(_exampleRequest());
    }

    /// @notice From inside the payout transfer (a token hook): the context stays open until the payout is sent, so a
    /// reentrant `flashLiquidate` reverts `ContextActive` and a replayed callback reverts `InvalidFlashCallback`.
    // TEST-174 verifies: REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-013
    // TEST-046 verifies: REQ-HELPER-005
    function test_TEST_174_helperReentryDuringPayoutReverts() public {
        HelperReenterer reenterer = new HelperReenterer();
        reenterer.arm(
            address(helper),
            abi.encodeCall(IFlashLiquidator.flashLiquidate, (_exampleRequest())),
            IERC20(address(usdcToken)),
            caller,
            0
        );
        usdcToken.setHook(address(reenterer), abi.encodeCall(HelperReenterer.poke, ()));
        uint256 payout = _liquidate(_exampleRequest());
        assertEq(payout, 69.825e6);
        assertTrue(reenterer.fired(), "hook ran inside the payout transfer");
        assertFalse(reenterer.succeeded());
        assertEq(bytes4(reenterer.returned()), IFlashLiquidatorErrors.ContextActive.selector);

        HelperReenterer replay = new HelperReenterer();
        replay.arm(address(helper), _exampleCallback(address(helper)), IERC20(address(usdcToken)), caller, 69.825e6);
        usdcToken.setHook(address(replay), abi.encodeCall(HelperReenterer.poke, ()));
        _liquidate(_exampleRequest());
        assertTrue(replay.fired());
        assertFalse(replay.succeeded());
        assertEq(bytes4(replay.returned()), IFlashLiquidatorErrors.InvalidFlashCallback.selector);
    }

    // ─── Context reuse ───

    /// @notice The context is cleared after each call: two liquidations in one transaction both run, and the Pool's
    /// replay of the first callback afterwards reverts.
    // TEST-174 verifies: REQ-HELPER-004
    // TEST-046 verifies: REQ-HELPER-005, INV-040
    function test_TEST_174_helperContextClearedAndNotReusable() public {
        _liquidate(_exampleRequest());
        _liquidate(_exampleRequest());
        assertEq(lvs.calls(), 2);
        bytes memory replay = _exampleCallback(address(helper));
        vm.prank(address(aavePool));
        (bool ok, bytes memory ret) = address(helper).call(replay);
        assertFalse(ok, "used context replayed");
        assertEq(bytes4(ret), IFlashLiquidatorErrors.InvalidFlashCallback.selector);
    }

    /// @notice A reverted call leaves no context: the next call in the same transaction runs.
    // TEST-174 verifies: REQ-HELPER-004
    function test_TEST_174_helperRevertedCallLeavesNoContext() public {
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PayoutTooLow.selector, 69.825e6, 70e6));
        _liquidate(_request(1950e6, 1950e6, 975_000, 0, 70e6));
        _liquidate(_exampleRequest());
        assertEq(usdcToken.balanceOf(caller), 69.825e6);
    }
}
