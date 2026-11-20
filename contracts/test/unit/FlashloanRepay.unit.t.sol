// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapter} from "../../src/adapter/interfaces/IAaveAdapter.sol";
import {FlashloanRepay} from "../../src/periphery/FlashloanRepay.sol";
import {IFlashloanRepay} from "../../src/periphery/interfaces/IFlashloanRepay.sol";
import {Swap, SwapCalls} from "../../src/periphery/libraries/SwapCalls.sol";
import {FlashloanRepayTestBase} from "../utils/FlashloanRepayTestBase.sol";
import {MockSwapRouter} from "../utils/mocks/FlashloanRepayMocks.sol";

/// @notice Unit tests of the repay-with-collateral helper: partial and full repayment, leftovers to the wallet, the
/// swap guards and the callback checks.
contract FlashloanRepayUnitTest is FlashloanRepayTestBase {
    function test_constructor_readsTheAdapter() public view {
        assertEq(helper.ADAPTER(), address(adapter));
        assertEq(helper.POOL(), address(flashPool));
        assertEq(helper.LP_VAULT(), address(vault));
        assertEq(helper.RISK_MODULE(), address(rm));
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IFlashloanRepay.InvalidAddress.selector, address(0)));
        new FlashloanRepay(address(0), address(flashPool));
        vm.expectRevert(abi.encodeWithSelector(IFlashloanRepay.InvalidAddress.selector, address(0)));
        new FlashloanRepay(address(adapter), address(0));
    }

    function test_partialRepay() public {
        uint256 before = _health();
        uint256 walletUsdc = usdc.balanceOf(alice);
        // Repay 3e17: withdraw 2e17 liquidity (2e17 of each token), sell both for 4e17 USDC, owe 3e17 + 5 bps.
        uint256 premium = 3e17 * 5 / 10_000;
        vm.expectEmit(address(helper));
        emit IFlashloanRepay.RepaidWithCollateral(alice, key, address(usdc), 3e17, premium, 2e17);
        _repayWithCollateral(3e17, 2e17, _sellBoth(10_000));
        assertEq(_debt(), DEBT - 3e17);
        assertEq(_supplied(alice, FULL), 8e17);
        assertEq(usdc.balanceOf(alice) - walletUsdc, 4e17 - 3e17 - premium);
        assertGt(_health(), before);
        _assertHelperEmpty();
    }

    function test_fullRepayWithMax() public {
        _repayWithCollateral(type(uint256).max, 4e17, _sellBoth(10_000));
        assertEq(_debt(), 0);
        assertEq(_health(), type(uint256).max);
        // The rest of the position is free to withdraw whole.
        vm.prank(alice);
        adapter.withdraw(key, 0, 0, 0, alice);
        assertEq(pm.ownerOf(uint256(key)), alice);
        _assertHelperEmpty();
    }

    function test_amountAboveDebtRepaysAll() public {
        _repayWithCollateral(DEBT * 2, 4e17, _sellBoth(10_000));
        assertEq(_debt(), 0);
    }

    function test_unsoldTokenGoesBackToTheWallet() public {
        Swap[] memory s = new Swap[](1);
        s[0] = _sell(address(token0), 20_000, 0);
        _repayWithCollateral(3e17, 2e17, s);
        assertEq(token1.balanceOf(alice), 2e17);
        assertEq(_debt(), DEBT - 3e17);
        _assertHelperEmpty();
    }

    function test_insufficientProceedsReverts() public {
        uint256 premium = 3e17 * 5 / 10_000;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IFlashloanRepay.InsufficientProceeds.selector, 2e17, 3e17 + premium));
        adapter.allowWithdraw(address(helper), key, 1e17, _params(3e17, 1e17, _sellBoth(10_000)));
    }

    function test_swapSlippageBoundReverts() public {
        Swap[] memory s = new Swap[](1);
        s[0] = _sell(address(token0), 10_000, 3e17);
        bytes memory reason = abi.encodeWithSelector(MockSwapRouter.TooLittleOut.selector, 2e17, 3e17);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapCalls.SwapFailed.selector, 0, reason));
        adapter.allowWithdraw(address(helper), key, 2e17, _params(1e17, 2e17, s));
    }

    function test_swapCannotTargetTheAdapterPoolOrVault() public {
        address[4] memory targets = [address(adapter), address(flashPool), address(vault), address(helper)];
        for (uint256 i; i < targets.length; ++i) {
            Swap[] memory s = new Swap[](1);
            s[0] = Swap({tokenIn: address(token0), target: targets[i], data: hex"00000000", amountInOffset: 0});
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(SwapCalls.ForbiddenTarget.selector, targets[i]));
            adapter.allowWithdraw(address(helper), key, 2e17, _params(1e17, 2e17, s));
        }
        Swap[] memory eoa = new Swap[](1);
        eoa[0] = Swap({tokenIn: address(token0), target: bob, data: "", amountInOffset: 0});
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapCalls.ForbiddenTarget.selector, bob));
        adapter.allowWithdraw(address(helper), key, 2e17, _params(1e17, 2e17, eoa));
    }

    function test_badAmountOffsetReverts() public {
        Swap[] memory s = _sellBoth(10_000);
        s[1].amountInOffset = s[1].data.length - 31;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwapCalls.InvalidOffset.selector, 1, s[1].amountInOffset));
        adapter.allowWithdraw(address(helper), key, 2e17, _params(1e17, 2e17, s));
    }

    function test_wholePositionIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.WithdrawNotAllowed.selector, key, 1e18));
        adapter.allowWithdraw(address(helper), key, 1e18, _params(DEBT, 1e18, _sellBoth(10_000)));
    }

    function test_nothingToRepayReverts() public {
        bytes32 bobs = _mint(bob, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(bob, bobs);
        address account = adapter.accountOf(bob, FULL);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IFlashloanRepay.NothingToRepay.selector, account, DEBT_RESERVE));
        adapter.allowWithdraw(address(helper), bobs, 1e17, _params(1e17, 1e17, _sellBoth(10_000)));
    }

    function test_onlyTheAdapterCallsBack() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IFlashloanRepay.NotAdapter.selector, bob));
        helper.onWithdrawAllowed(alice, key, 1e17, _params(1e17, 1e17, _sellBoth(10_000)));
    }

    function test_flashCallbackChecks() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e17;
        uint256[] memory premiums = new uint256[](1);
        // Not the Pool.
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        helper.executeOperation(assets, amounts, premiums, address(helper), "");
        // The Pool, but no loan of this helper is open.
        vm.prank(address(flashPool));
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        helper.executeOperation(assets, amounts, premiums, address(helper), "");
        // A loan someone else opened with the helper as receiver.
        vm.prank(bob);
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        flashPool.flashLoan(address(helper), assets, amounts, new uint256[](1), bob, "", 0);
    }
}
