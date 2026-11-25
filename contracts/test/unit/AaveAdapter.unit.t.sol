// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/AaveAdapter.sol";
import {AccountProxy} from "../../src/AccountProxy.sol";
import {IAaveAdapter} from "../../src/interfaces/IAaveAdapter.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {IRiskModule} from "../../src/interfaces/IRiskModule.sol";
import {AaveAdapterTestBase} from "../utils/AaveAdapterTestBase.sol";
import {AdapterTestRiskModule, AdapterTestSpoke} from "../utils/mocks/AaveAdapterTestMocks.sol";

/// @notice Unit tests of the AaveAdapter: routing, accounts, pledge, add liquidity, withdraw, borrow, repay, fees.
contract AaveAdapterUnitTest is AaveAdapterTestBase {
    // ─── Deployment ───

    function test_constructor_readsTheLPVault() public view {
        assertEq(adapter.RISK_MODULE(), address(rm));
        assertEq(adapter.LP_VAULT(), address(vault));
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.InvalidAddress.selector, address(0)));
        new AaveAdapter(address(0));
        AdapterTestRiskModule empty = new AdapterTestRiskModule(address(0));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.InvalidAddress.selector, address(0)));
        new AaveAdapter(address(empty));
    }

    // ─── Routing ───

    function test_pledge_fullRangeGoesToFullRange() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        (uint256 marketId, uint128 credit) = _pledge(alice, key);
        assertEq(marketId, FULL);
        assertEq(credit, 1e18, "a full-range position is credited its liquidity");
        assertEq(_supplied(alice, FULL), 1e18);
    }

    function test_pledge_customInsideBandGoesToCustomRange() public {
        bytes32 key = _mint(alice, -500, 500, 1e18);
        (uint256 marketId, uint128 credit) = _pledge(alice, key);
        assertEq(marketId, CUSTOM);
        assertGt(credit, 0);
        assertLt(credit, 1e18, "a narrower position earns less than its liquidity");
        assertEq(_supplied(alice, CUSTOM), credit);
    }

    function test_pledge_exactBandIsCreditedItsLiquidity() public {
        (, uint128 credit) = _pledge(alice, _mint(alice, BAND_LOWER, BAND_UPPER, 5e17));
        assertEq(credit, 5e17);
    }

    function test_pledge_outsideBandIsRejected() public {
        bytes32 key = _mint(alice, -2000, 500, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NoMarketFits.selector, POOL, int24(-2000), int24(500)));
        _pledge(alice, key);
        assertEq(pm.ownerOf(uint256(key)), alice);
    }

    function test_pledge_unlistedPoolIsRejected() public {
        bytes32 key = bytes32(pm.mint(alice, POOL_UNLISTED, FULL_LOWER, FULL_UPPER, 1e18));
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapter.NoMarketFits.selector, POOL_UNLISTED, FULL_LOWER, FULL_UPPER)
        );
        _pledge(alice, key);
    }

    function test_pledge_inactiveMarketIsRejected() public {
        IRiskModule.Market memory m = rm.getMarket(CUSTOM);
        m.active = false;
        rm.setMarket(CUSTOM, m);
        bytes32 key = _mint(alice, -500, 500, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.MarketNotActive.selector, CUSTOM));
        _pledge(alice, key);
    }

    // ─── Accounts ───

    function test_account_deployedAtThePredictedAddress() public {
        address predicted = adapter.predictAccount(alice, FULL);
        assertEq(adapter.accountOf(alice, FULL), address(0));
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit IAaveAdapter.AccountCreated(alice, FULL, predicted);
        _pledge(alice, key);
        address account = adapter.accountOf(alice, FULL);
        assertEq(account, predicted);
        assertEq(adapter.predictAccount(alice, FULL), account);
        AccountProxy proxy = AccountProxy(account);
        assertEq(proxy.ADAPTER(), address(adapter));
        assertEq(proxy.OWNER(), alice);
        assertEq(proxy.MARKET_ID(), FULL);
        assertTrue(spoke.approval(address(adapter), account), "the account approves the adapter in its constructor");
        assertTrue(spoke.usingAsCollateral(account, FULL));
        assertLt(account.code.length, 600, "the account is thin");
    }

    function test_account_onePerWalletAndMarket() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 2e18));
        _pledge(alice, _mint(alice, -100, 100, 1e18));
        _pledge(bob, _mint(bob, FULL_LOWER, FULL_UPPER, 1e18));
        address aFull = adapter.accountOf(alice, FULL);
        address aCustom = adapter.accountOf(alice, CUSTOM);
        address bFull = adapter.accountOf(bob, FULL);
        assertTrue(aFull != aCustom && aFull != bFull && aCustom != bFull);
        assertEq(vault.positionsOf(aFull).length, 2);
        assertEq(_supplied(alice, FULL), 3e18);
        assertEq(_supplied(bob, FULL), 1e18);
    }

    function test_account_notCallableByOthers() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        address account = adapter.accountOf(alice, FULL);
        vm.prank(bob);
        vm.expectRevert(AdapterTestSpoke.Unauthorized.selector);
        spoke.withdraw(FULL, 1, account);
    }

    // ─── Pledge ───

    function test_pledge_supplyCapRevertsTheWholePledge() public {
        spoke.setSupplyCap(1e18);
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 2e18);
        vm.expectRevert(AdapterTestSpoke.SupplyCapExceeded.selector);
        _pledge(alice, key);
        assertEq(pm.ownerOf(uint256(key)), alice);
        assertEq(vtFull.totalSupply(), 0);
    }

    function test_pledge_onlyTheOwnerCanPledge() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, key));
        _pledge(bob, key);
    }

    function test_pledge_vaultTokensSitInTheHub() public {
        (, uint128 c1) = _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        (, uint128 c2) = _pledge(bob, _mint(bob, FULL_LOWER, FULL_UPPER, 3e18));
        assertEq(vtFull.balanceOf(address(hub)), uint256(c1) + c2);
        assertEq(vtFull.balanceOf(address(adapter)), 0);
        assertEq(vtFull.totalSupply(), vault.getMarket(FULL).totalCredit);
        assertTrue(vtFull.isValidProxy(address(adapter)));
    }

    function test_multicall_pledgesSeveralNfts() public {
        bytes[] memory calls = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            calls[i] = abi.encodeCall(IAaveAdapter.pledge, (_mint(alice, -500, 500, 1e18)));
        }
        vm.prank(alice);
        adapter.multicall(calls);
        assertEq(vault.positionsOf(adapter.accountOf(alice, CUSTOM)).length, 3);
        assertEq(_supplied(alice, CUSTOM), vault.accountCredit(adapter.accountOf(alice, CUSTOM), CUSTOM));
    }

    // ─── Add liquidity ───

    function test_addLiquidity_suppliesTheNewCredit() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        token0.mint(alice, 5e17);
        token1.mint(alice, 6e17);
        vm.prank(alice);
        (uint128 liquidity, uint128 credit,,) = adapter.addLiquidity(key, 5e17, 6e17, 0, 0);
        assertEq(liquidity, 5e17);
        assertEq(credit, 5e17);
        assertEq(_supplied(alice, FULL), 15e17);
        assertEq(token1.balanceOf(alice), 1e17, "unused token1 refunded");
    }

    function test_addLiquidity_rejectsOtherWallets() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        _pledge(bob, _mint(bob, FULL_LOWER, FULL_UPPER, 1e18));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NotPositionOwner.selector, key, bob));
        adapter.addLiquidity(key, 1, 1, 0, 0);
    }

    // ─── Withdraw ───

    function test_withdraw_wholeNft() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(alice);
        uint256 burned = adapter.withdraw(key, 0, 0, 0, carol);
        assertEq(burned, 1e18);
        assertEq(pm.ownerOf(uint256(key)), carol);
        assertEq(_supplied(alice, FULL), 0);
        assertEq(vtFull.totalSupply(), 0);
    }

    function test_withdraw_liquidityAtRecordIsWholeNft() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        // The event reports a whole-NFT release as liquidity 0 (IAaveAdapter.Withdrawn), so an indexer does not book
        // the release of the NFT as a partial removal that leaves a position behind.
        vm.expectEmit(address(adapter));
        emit IAaveAdapter.Withdrawn(alice, key, alice, 0, 1e18);
        vm.prank(alice);
        adapter.withdraw(key, 1e18, 0, 0, alice);
        assertEq(pm.ownerOf(uint256(key)), alice);
    }

    function test_withdraw_part() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(alice);
        uint256 burned = adapter.withdraw(key, 4e17, 0, 0, alice);
        assertEq(burned, 4e17);
        assertEq(token0.balanceOf(alice), 4e17);
        assertEq(token1.balanceOf(alice), 4e17);
        assertEq(pm.ownerOf(uint256(key)), address(vault));
        assertEq(_supplied(alice, FULL), 6e17);
    }

    function test_withdraw_blockedByHealth() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 7e17, alice);
        vm.startPrank(alice);
        vm.expectRevert(AdapterTestSpoke.HealthFactorBelowOne.selector);
        adapter.withdraw(key, 0, 0, 0, alice);
        // 1e18 * 0.8 = 8e17 power; removing 1.25e17 leaves 7e17 power, just enough.
        adapter.withdraw(key, 125e15, 0, 0, alice);
        vm.expectRevert(AdapterTestSpoke.HealthFactorBelowOne.selector);
        adapter.withdraw(key, 1, 0, 0, alice);
        vm.stopPrank();
        assertEq(pm.ownerOf(uint256(key)), address(vault));
    }

    function test_withdraw_oneNftOfSeveralWithDebt() public {
        bytes32 k1 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        bytes32 k2 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, k1);
        _pledge(alice, k2);
        vm.startPrank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 8e17, alice);
        adapter.withdraw(k1, 0, 0, 0, alice);
        vm.stopPrank();
        assertEq(pm.ownerOf(uint256(k1)), alice);
        assertEq(_supplied(alice, FULL), 1e18);
    }

    function test_withdraw_rejectsOtherWallets() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NotPositionOwner.selector, key, bob));
        adapter.withdraw(key, 0, 0, 0, bob);
        bytes32 none = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NotPositionOwner.selector, none, alice));
        adapter.withdraw(none, 0, 0, 0, alice);
    }

    function test_withdraw_rejectsZeroRecipient() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.InvalidAddress.selector, address(0)));
        adapter.withdraw(key, 0, 0, 0, address(0));
    }

    /// @dev Share rounding leaves the supply below credit; withdrawals trim it to the remaining credit and empty it.
    function test_withdraw_supplyRoundingNeverExceedsCredit() public {
        spoke.setSupplyHaircut(1);
        bytes32 k1 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        bytes32 k2 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, k1);
        _pledge(alice, k2);
        assertEq(_supplied(alice, FULL), 2e18 - 2);
        vm.startPrank(alice);
        adapter.withdraw(k1, 0, 0, 0, alice);
        assertEq(_supplied(alice, FULL), 1e18, "the supply drops to the remaining credit");
        adapter.withdraw(k2, 0, 0, 0, alice);
        vm.stopPrank();
        assertEq(_supplied(alice, FULL), 0);
    }

    /// @notice Bug hunted: a partial withdraw that burns vault tokens although Aave's supply is already under the
    /// remaining credit (supply rounding lost units at each pledge). Withdrawing that supply would take Aave
    /// collateral that the remaining NFTs back; only supply above the credit may be trimmed.
    function test_withdraw_partLeavesASupplyAlreadyUnderTheCredit() public {
        spoke.setSupplyHaircut(1);
        bytes32 k1 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, k1);
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        assertEq(_supplied(alice, FULL), 2e18 - 2);
        vm.prank(alice);
        uint256 burned = adapter.withdraw(k1, 1, 0, 0, alice);
        assertEq(burned, 0, "the supply is under the remaining credit");
        assertEq(_supplied(alice, FULL), 2e18 - 2);
        assertEq(vault.accountCredit(adapter.accountOf(alice, FULL), FULL), 2e18 - 1);
    }

    // ─── Borrow ───

    function test_borrow_sendsToRecipient() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 5e17, carol);
        assertEq(usdc.balanceOf(carol), 5e17);
        assertEq(spoke.debt(adapter.accountOf(alice, FULL), DEBT_RESERVE), 5e17);
    }

    function test_borrow_checks() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NoAccount.selector, alice, FULL));
        adapter.borrow(FULL, DEBT_RESERVE, 1, alice);
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        vm.startPrank(alice);
        vm.expectRevert(IAaveAdapter.InvalidAmount.selector);
        adapter.borrow(FULL, DEBT_RESERVE, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.InvalidAddress.selector, address(0)));
        adapter.borrow(FULL, DEBT_RESERVE, 1, address(0));
        vm.expectRevert(AdapterTestSpoke.HealthFactorBelowOne.selector);
        adapter.borrow(FULL, DEBT_RESERVE, 8e17 + 1, alice);
        vm.stopPrank();
        rm.setBorrowBlocked(true);
        vm.prank(alice);
        vm.expectRevert(IRiskModule.NoActiveKeeper.selector);
        adapter.borrow(FULL, DEBT_RESERVE, 1, alice);
    }

    function test_borrow_accountsAreIsolated() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        _pledge(alice, _mint(alice, BAND_LOWER, BAND_UPPER, 1e18));
        vm.startPrank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 8e17, alice);
        adapter.borrow(CUSTOM, DEBT_RESERVE, 8e17, alice);
        vm.expectRevert(AdapterTestSpoke.HealthFactorBelowOne.selector);
        adapter.borrow(FULL, DEBT_RESERVE, 1, alice);
        vm.stopPrank();
    }

    // ─── Repay ───

    function test_repay_partialAndMax() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        vm.startPrank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 5e17, alice);
        assertEq(adapter.repay(FULL, DEBT_RESERVE, 2e17, alice), 2e17);
        assertEq(adapter.repay(FULL, DEBT_RESERVE, type(uint256).max, alice), 3e17);
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapter.NoDebt.selector, adapter.accountOf(alice, FULL), DEBT_RESERVE)
        );
        adapter.repay(FULL, DEBT_RESERVE, 1, alice);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(spoke)), 0);
    }

    /// @notice Bug hunted: tokens pulled for a repay that Aave does not take stay in the adapter. The adapter pulls
    /// the debt it reads, but the Spoke may take less (its repaid shares round down); the rest must go back to the
    /// payer, and the Spoke's allowance must return to zero.
    function test_repay_refundsWhatTheSpokeDidNotTake() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 5e17, alice);
        spoke.setRepayShortfall(3);
        vm.prank(alice);
        uint256 repaid = adapter.repay(FULL, DEBT_RESERVE, type(uint256).max, alice);
        assertEq(repaid, 5e17 - 3);
        assertEq(usdc.balanceOf(alice), 3, "the untaken part comes back");
        assertEq(usdc.balanceOf(address(adapter)), 0, "nothing stays in the adapter");
        assertEq(usdc.allowance(address(adapter), address(spoke)), 0);
        assertEq(spoke.debt(adapter.accountOf(alice, FULL), DEBT_RESERVE), 3);
    }

    function test_repay_byAnotherPayer() public {
        _pledge(alice, _mint(alice, FULL_LOWER, FULL_UPPER, 1e18));
        vm.prank(alice);
        adapter.borrow(FULL, DEBT_RESERVE, 5e17, alice);
        usdc.mint(bob, 1e18);
        vm.prank(bob);
        assertEq(adapter.repay(FULL, DEBT_RESERVE, type(uint256).max, alice), 5e17);
        assertEq(usdc.balanceOf(bob), 5e17, "only the debt is pulled");
        assertEq(spoke.debt(adapter.accountOf(alice, FULL), DEBT_RESERVE), 0);
    }

    function test_repay_checks() public {
        vm.expectRevert(IAaveAdapter.InvalidAmount.selector);
        adapter.repay(FULL, DEBT_RESERVE, 0, alice);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NoAccount.selector, alice, FULL));
        adapter.repay(FULL, DEBT_RESERVE, 1, alice);
    }

    // ─── Fees ───

    function test_collectFees_selectedNfts() public {
        bytes32 k1 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        bytes32 k2 = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, k1);
        _pledge(alice, k2);
        pm.accrue(uint256(k1), 3, 4);
        pm.accrue(uint256(k2), 5, 6);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = k2;
        vm.prank(alice);
        (uint256[] memory a0, uint256[] memory a1) = adapter.collectFees(FULL, keys);
        assertEq(a0[0], 5);
        assertEq(a1[0], 6);
        assertEq(token0.balanceOf(alice), 5);
        (uint256 f0,) = vault.feesOf(k1);
        assertEq(f0, 3, "unnamed NFT keeps its fees");
    }

    function test_collectFees_onlyOwnPositions() public {
        bytes32 key = _mint(alice, FULL_LOWER, FULL_UPPER, 1e18);
        _pledge(alice, key);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapter.NoAccount.selector, bob, FULL));
        adapter.collectFees(FULL, keys);
        _pledge(bob, _mint(bob, FULL_LOWER, FULL_UPPER, 1e18));
        address bobAccount = adapter.accountOf(bob, FULL);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotPositionAccount.selector, key, bobAccount));
        adapter.collectFees(FULL, keys);
    }
}
