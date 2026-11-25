// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapter} from "../../src/interfaces/IAaveAdapter.sol";
import {AaveAdapterTestBase} from "../utils/AaveAdapterTestBase.sol";
import {MockWithdrawOperator} from "../utils/mocks/FlashloanRepayMocks.sol";

/// @notice Unit tests of `allowWithdraw`: a one-call, one-position withdrawal allowance whose account may not end less
/// healthy than it started.
contract AaveAdapterAllowWithdrawTest is AaveAdapterTestBase {
    MockWithdrawOperator internal op;
    bytes32 internal key;

    function setUp() public override {
        super.setUp();
        op = new MockWithdrawOperator();
        key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        usdc.mint(address(op), 1e24);
        op.approve(address(usdc), address(adapter));
    }

    function _calls(
        bytes memory a
    ) internal view returns (bytes memory) {
        address[] memory t = new address[](1);
        bytes[] memory c = new bytes[](1);
        (t[0], c[0]) = (address(adapter), a);
        return abi.encode(t, c);
    }

    function _calls(
        bytes memory a,
        bytes memory b
    ) internal view returns (bytes memory) {
        address[] memory t = new address[](2);
        bytes[] memory c = new bytes[](2);
        (t[0], c[0], t[1], c[1]) = (address(adapter), a, address(adapter), b);
        return abi.encode(t, c);
    }

    function _withdraw(
        bytes32 k,
        uint128 liquidity
    ) internal view returns (bytes memory) {
        return abi.encodeCall(IAaveAdapter.withdraw, (k, liquidity, 0, 0, address(op)));
    }

    function _repay(
        uint256 amount
    ) internal view returns (bytes memory) {
        return abi.encodeCall(IAaveAdapter.repay, (FULL, DEBT_RESERVE, amount, alice));
    }

    function test_operatorWithdrawsPartWithinTheAllowance() public {
        vm.prank(alice);
        adapter.allowWithdraw(address(op), key, 3e17, _calls(_withdraw(key, 1e17), _withdraw(key, 2e17)));
        assertEq(token0.balanceOf(address(op)), 3e17);
        assertEq(_supplied(alice, FULL), 7e17);
    }

    function test_withdrawnEventNamesTheWallet() public {
        vm.expectEmit(address(adapter));
        emit IAaveAdapter.Withdrawn(alice, key, address(op), 1e17, 1e17);
        vm.prank(alice);
        adapter.allowWithdraw(address(op), key, 1e17, _calls(_withdraw(key, 1e17)));
    }

    function test_operatorCannotExceedTheAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.WithdrawNotAllowed.selector, key, 2e17));
        adapter.allowWithdraw(address(op), key, 3e17, _calls(_withdraw(key, 2e17), _withdraw(key, 2e17)));
    }

    function test_operatorCannotTakeTheWholeNft() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.WithdrawNotAllowed.selector, key, 0));
        adapter.allowWithdraw(address(op), key, 1e18, _calls(_withdraw(key, 0)));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.WithdrawNotAllowed.selector, key, 1e18));
        adapter.allowWithdraw(address(op), key, 1e18, _calls(_withdraw(key, 1e18)));
        vm.stopPrank();
    }

    function test_operatorCannotTouchAnotherPosition() public {
        bytes32 other = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, other);
        bytes32 bobs = _mint(bob, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(bob, bobs);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.WithdrawNotAllowed.selector, other, 1e17));
        adapter.allowWithdraw(address(op), key, 1e17, _calls(_withdraw(other, 1e17)));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.WithdrawNotAllowed.selector, bobs, 1e17));
        adapter.allowWithdraw(address(op), key, 1e17, _calls(_withdraw(bobs, 1e17)));
        vm.stopPrank();
    }

    function test_allowanceEndsWithTheCall() public {
        vm.prank(alice);
        adapter.allowWithdraw(address(op), key, 3e17, _calls(_withdraw(key, 1e17)));
        vm.prank(address(op));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NotPositionOwner.selector, key, address(op)));
        adapter.withdraw(key, 1e17, 0, 0, address(op));
    }

    function test_onlyTheOwnerOpensAnAllowance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NotPositionOwner.selector, key, bob));
        adapter.allowWithdraw(address(op), key, 1e17, _calls(_withdraw(key, 1e17)));
    }

    function test_rejectsBadArguments() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.InvalidAddress.selector, address(0)));
        adapter.allowWithdraw(address(0), key, 1, "");
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.InvalidAddress.selector, address(adapter)));
        adapter.allowWithdraw(address(adapter), key, 1, "");
        vm.expectRevert(IAaveAdapter.InvalidAmount.selector);
        adapter.allowWithdraw(address(op), key, 0, "");
        vm.stopPrank();
    }

    function test_nestedAllowanceReverts() public {
        // The operator, holding an allowance, tries to open another one for its own position.
        bytes32 opKey = _mint(address(op), FULL_LOWER, FULL_UPPER, 1e18);
        vm.prank(alice);
        vm.expectRevert(IAaveAdapter.AllowanceOpen.selector);
        adapter.allowWithdraw(
            address(op),
            key,
            1e17,
            _calls(abi.encodeCall(IAaveAdapter.allowWithdraw, (address(op), opKey, 1e17, bytes(""))))
        );
    }

    function test_withdrawWithoutRepayIsRefusedWhenItLowersHealth() public {
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 4e17, alice);
        // Health 8e17 / 4e17 = 2.0 before; 7.2e17 / 4e17 = 1.8 after a withdrawal with no repayment.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.HealthFactorDecreased.selector, 2e18, 18e17));
        adapter.allowWithdraw(address(op), key, 1e17, _calls(_withdraw(key, 1e17)));
    }

    function test_repayThenWithdrawRaisesHealth() public {
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 7e17, alice);
        // Health 8e17 / 7e17 before; repay 2e17 and withdraw 2e17: 6.4e17 / 5e17 = 1.28 after.
        vm.prank(alice);
        adapter.allowWithdraw(address(op), key, 2e17, _calls(_repay(2e17), _withdraw(key, 2e17)));
        assertEq(spoke.debt(adapter.accountOf(alice, FULL), DEBT_RESERVE), 5e17);
        assertEq(_supplied(alice, FULL), 8e17);
    }

    function test_walletKeepsItsOwnWithdrawOutsideTheAllowance() public {
        vm.prank(alice);
        adapter.withdraw(key, 1e17, 0, 0, alice);
        assertEq(token0.balanceOf(alice), 1e17);
    }
}
