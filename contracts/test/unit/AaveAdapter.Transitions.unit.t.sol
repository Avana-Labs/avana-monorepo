// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../src/vault/interfaces/ILPVault.sol";
import {AaveAdapterTestBase} from "../utils/AaveAdapterTestBase.sol";
import {AdapterTestSpoke} from "../utils/mocks/AaveAdapterTestMocks.sol";

/// @notice Transition and accounting tests for adapter-backed LP positions.
contract AaveAdapterTransitionsUnitTest is AaveAdapterTestBase {
    /// @dev A full Spoke supply cap fails after the adapter has predicted and created an account and LPVault has taken
    /// custody. The failed pledge must leave no deployable account, custody record, credit, or vault-token balance.
    function test_pledgeSupplyFailureRollsBackNewAccountCustodyAndCredit() public {
        spoke.setSupplyCap(5e17);
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        address predicted = adapter.predictAccount(alice, FULL);

        vm.expectRevert(AdapterTestSpoke.SupplyCapExceeded.selector);
        _pledge(alice, key);

        ILPVault.Position memory position = vault.getPosition(key);
        assertEq(adapter.accountOf(alice, FULL), address(0));
        assertEq(predicted.code.length, 0);
        assertEq(pm.ownerOf(uint256(key)), alice);
        assertEq(position.account, address(0));
        assertEq(position.liquidity, 0);
        assertEq(position.credit, 0);
        assertEq(vault.getMarket(FULL).totalCredit, 0);
        assertEq(vtFull.totalSupply(), 0);
        assertEq(vtFull.balanceOf(address(hub)), 0);
    }

    /// @dev A borrower attempts a whole-NFT release that would make the account unhealthy. A reverted health check
    /// must restore the NFT, LPVault credit, supplied vault tokens, debt, and the proposed recipient's balances.
    function test_failedWithdrawalLeavesCustodyCreditSupplyAndDebtUnchanged() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 7e17, bob);
        address account = adapter.accountOf(alice, FULL);

        vm.prank(alice);
        vm.expectRevert(AdapterTestSpoke.HealthFactorBelowOne.selector);
        adapter.withdraw(key, 0, 0, 0, carol);

        ILPVault.Position memory position = vault.getPosition(key);
        assertEq(pm.ownerOf(uint256(key)), address(vault));
        assertEq(position.account, account);
        assertEq(position.liquidity, 1e18);
        assertEq(position.credit, 1e18);
        assertEq(vault.accountCredit(account, FULL), 1e18);
        assertEq(vault.getMarket(FULL).totalCredit, 1e18);
        assertEq(_supplied(alice, FULL), 1e18);
        assertEq(vtFull.totalSupply(), 1e18);
        assertEq(vtFull.balanceOf(address(hub)), 1e18);
        assertEq(spoke.debt(account, DEBT_RESERVE), 7e17);
        assertEq(token0.balanceOf(carol), 0);
        assertEq(token1.balanceOf(carol), 0);
    }

    /// @dev A third party repays between a borrow and the owner's partial withdrawal, then the owner collects fees.
    /// The interleaving must preserve outstanding debt, Hub debt-asset balance, remaining LP credit and supply, while
    /// paying principal and fees only to their intended recipients.
    function test_borrowRepayWithdrawAndFeesConserveEachLedger() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        address account = adapter.accountOf(alice, FULL);
        uint256 hubDebtAssetBefore = usdc.balanceOf(address(hub));

        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 6e17, bob);
        usdc.mint(carol, 2e17);
        vm.prank(carol);
        assertEq(adapter.repay(FULL, DEBT_RESERVE, 2e17, alice), 2e17);
        vm.prank(alice);
        assertEq(adapter.withdraw(key, 2e17, 0, 0, alice), 2e17);
        pm.accrue(uint256(key), 11, 13);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(alice);
        adapter.collectFees(FULL, keys);

        ILPVault.Position memory position = vault.getPosition(key);
        assertEq(pm.ownerOf(uint256(key)), address(vault));
        assertEq(position.account, account);
        assertEq(position.liquidity, 8e17);
        assertEq(position.credit, 8e17);
        assertEq(vault.accountCredit(account, FULL), 8e17);
        assertEq(vault.getMarket(FULL).totalCredit, 8e17);
        assertEq(_supplied(alice, FULL), 8e17);
        assertEq(vtFull.totalSupply(), 8e17);
        assertEq(vtFull.balanceOf(address(hub)), 8e17);
        assertEq(spoke.debt(account, DEBT_RESERVE), 4e17);
        assertEq(usdc.balanceOf(address(hub)), hubDebtAssetBefore - 4e17);
        assertEq(usdc.balanceOf(bob), 6e17);
        assertEq(usdc.balanceOf(carol), 0);
        assertEq(token0.balanceOf(alice), 2e17 + 11);
        assertEq(token1.balanceOf(alice), 2e17 + 13);
        (uint256 fees0, uint256 fees1) = vault.feesOf(key);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
        assertEq(vtFull.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }
}
