// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapter} from "../../src/AaveAdapter.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {ILiquidationModule} from "../../src/interfaces/ILiquidationModule.sol";
import {INfpmPositions} from "../../src/interfaces/INfpmPositions.sol";
import {
    AaveV4MarketTestBase,
    IAaveV4Errors,
    ILifecycleHubConfigurator,
    ILifecycleSpokeConfigurator
} from "../utils/AaveV4MarketTestBase.sol";
import {SpokeDynamicReserveConfig} from "./VaultToken.AaveV4.integration.t.sol";

/// @title MarketLifecycleAaveV4IntegrationTest
/// @notice Market freeze, deprecation and emergency stops (`design/README.md`), plus the custody cases that touch
/// Aave state, on the pinned real Aave V4 Hub, CDP Spoke and Lend Spoke, configured only through Aave's own
/// configurators. Avana runs its real AaveAdapter, VaultToken, LPOracle, LiquidationModule and Uniswap v3 LPVault on the
/// real v3 factory, pool and NonfungiblePositionManager. The RiskModule is the market-lookup stand-in the adapter and
/// LiquidationModule suites use: it answers `getMarket`, `routeOf` and `checkBorrow` and holds no Aave state.
/// @dev The pool's tokens are listed on the Lend Spoke, which is the LPOracle's price Spoke, as on a real deployment.
/// One full-range market at $1 per token: a full-range position of 1,000 of each token is 1,000e18 credit units worth
/// $2,000, so the collateral factor of 80 % gives $1,600 of borrowing power.
contract MarketLifecycleAaveV4IntegrationTest is AaveV4MarketTestBase {
    // ─── Case 5: freeze and deprecation ───

    /// @notice Bug hunted: after a freeze and a collateral factor cut to 0 (Aave's deprecation path), new collateral
    /// or new debt still gets in, or a debtor leaves with collateral, or the exits a deprecated market must keep (repay,
    /// fee collection, a debt-free withdrawal) are blocked.
    function test_freezeAndCfZero_blockNewCollateralAndBorrows_keepExitsOpen() public {
        (bytes32 aKey,) = _mintFull(alice, SIZE);
        (bytes32 bKey, uint128 bLiquidity) = _mintFull(bob, SIZE);
        _pledge(alice, aKey);
        _pledge(bob, bKey);
        _borrow(alice, 800e18);
        _trade();
        _freezeAndCutCf();

        // Pledge and top-up by an account that already exists both supply, which the frozen reserve refuses.
        (bytes32 bKey2,) = _mintFull(bob, 100e18);
        vm.prank(bob);
        vm.expectRevert(IAaveV4Errors.ReserveFrozen.selector);
        adapter.pledge(bKey2);
        assertEq(nfpm.ownerOf(uint256(bKey2)), bob);
        _fundTopUp(bob, 10e18, 10e18);
        vm.prank(bob);
        vm.expectRevert(IAaveV4Errors.ReserveFrozen.selector);
        adapter.addLiquidity(bKey, 10e18, 10e18, 0, 0);
        assertEq(t0.balanceOf(bob), 10e18);

        // Borrow refreshes to the new collateral factor 0: refused for the debtor and the debt-free account alike.
        vm.prank(alice);
        vm.expectRevert(IAaveV4Errors.HealthFactorBelowThreshold.selector);
        adapter.borrow(MARKET, debtReserveId, 1e18, alice);
        vm.prank(bob);
        vm.expectRevert(IAaveV4Errors.HealthFactorBelowThreshold.selector);
        adapter.borrow(MARKET, debtReserveId, 1e18, bob);

        // A debtor cannot take collateral out, whole or in part.
        vm.prank(alice);
        vm.expectRevert(IAaveV4Errors.HealthFactorBelowThreshold.selector);
        adapter.withdraw(aKey, 0, 0, 0, alice);
        vm.prank(alice);
        vm.expectRevert(IAaveV4Errors.HealthFactorBelowThreshold.selector);
        adapter.withdraw(aKey, uint128(SIZE / 10), 0, 0, alice);
        assertEq(nfpm.ownerOf(uint256(aKey)), address(vault));

        // Fee collection does not touch the Spoke.
        _checkCollectFees(alice, aKey);

        // Repay works; once debt-free, the account leaves with its NFT.
        address aAccount = adapter.accountOf(alice, MARKET);
        _repayAll(alice);
        assertEq(spoke.getUserTotalDebt(debtReserveId, aAccount), 0);
        vm.prank(alice);
        adapter.withdraw(aKey, 0, 0, 0, alice);
        assertEq(nfpm.ownerOf(uint256(aKey)), alice);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, aAccount), 0);

        // The debt-free account takes part, then the rest.
        vm.prank(bob);
        adapter.withdraw(bKey, bLiquidity / 2, 0, 0, bob);
        vm.prank(bob);
        adapter.withdraw(bKey, 0, 0, 0, bob);
        assertEq(nfpm.ownerOf(uint256(bKey)), bob);
        assertEq(vault.getMarket(MARKET).totalCredit, 0);
        assertEq(vt.totalSupply(), 0);
    }

    /// @notice Bug hunted: the freeze and collateral factor cut also stop liquidation, leaving bad debt to grow. Aave
    /// liquidates with `receiveShares = false` at the account's own earlier collateral factor, so the unhealthy account
    /// is still liquidated and unwound in kind, with every ledger reconciled.
    function test_freezeAndCfZero_liquidationStillWorks() public {
        (bytes32 cKey, uint128 cLiquidity) = _mintFull(carol, SIZE);
        _pledge(carol, cKey);
        _borrow(carol, 1500e18);
        _freezeAndCutCf();
        // $2,000 of collateral falls to $1,600; 80 % of it backs $1,280 < $1,500 of debt.
        feed0.set(0.8e8);
        feed1.set(0.8e8);
        address account = adapter.accountOf(carol, MARKET);
        assertLt(spoke.getUserAccountData(account).healthFactor, 1e18);
        uint256 debtBefore = spoke.getUserTotalDebt(debtReserveId, account);

        ILiquidationModule.LiquidationResult memory r = _liquidate(account, 500e18);
        assertGt(r.debtRepaid, 0);
        assertGt(r.seized, 0);
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), debtBefore - r.debtRepaid);
        assertGt(t0.balanceOf(liquidator) + t1.balanceOf(liquidator), 0);
        // Only liquidity worth the seized units left the position, and the remaining supply is backed by the credit
        // left.
        ILPVault.Position memory p = vault.getPosition(cKey);
        assertLt(p.liquidity, cLiquidity);
        assertGt(p.liquidity, 0);
        assertLe(spoke.getUserSuppliedAssets(vtReserveId, account), vault.accountCredit(account, MARKET));
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(cKey)).liquidity, p.liquidity);
    }

    /// @notice Bug hunted: a pledge into a frozen market moves the NFT, creates the account or mints vault tokens
    /// before Aave refuses the supply, leaving an NFT in custody with no record (or a record with no collateral). The
    /// whole pledge reverts: the NFT stays with its owner and nothing is recorded, minted or created. A freeze alone is
    /// enough.
    function test_pledgeIntoAFrozenMarket_revertsWhole() public {
        (bytes32 bKey,) = _mintFull(bob, SIZE);
        _pledge(bob, bKey);
        uint256 supplyBefore = vt.totalSupply();
        uint256 creditBefore = vault.getMarket(MARKET).totalCredit;
        vm.prank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserveId, true);

        (bytes32 dKey,) = _mintFull(dave, SIZE);
        vm.prank(dave);
        vm.expectRevert(IAaveV4Errors.ReserveFrozen.selector);
        adapter.pledge(dKey);
        assertEq(nfpm.ownerOf(uint256(dKey)), dave);
        assertEq(vault.getPosition(dKey).account, address(0));
        assertEq(adapter.accountOf(dave, MARKET), address(0));
        assertEq(adapter.predictAccount(dave, MARKET).code.length, 0);
        assertEq(vault.getMarket(MARKET).totalCredit, creditBefore);
        assertEq(vt.totalSupply(), supplyBefore);
    }

    /// @notice Bug hunted: a freeze alone is taken for a full stop. It is not: a frozen collateral reserve still backs
    /// new borrowing (Aave checks only the debt reserve's flags), and the collateral factor cannot be cut to 0 in
    /// place, so deprecation needs a new dynamic config with collateral factor 0.
    function test_freezeAlone_leavesBorrowOpen_andCfZeroNeedsANewConfig() public {
        (bytes32 bKey,) = _mintFull(bob, SIZE);
        _pledge(bob, bKey);
        vm.prank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserveId, true);
        _borrow(bob, 100e18);
        assertEq(debt.balanceOf(bob), 100e18);

        uint32 key = spoke.getReserve(vtReserveId).dynamicConfigKey;
        vm.prank(aaveDao);
        vm.expectRevert(IAaveV4Errors.InvalidCollateralFactor.selector);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator)
            .updateDynamicReserveConfig(aave.cdpSpoke, vtReserveId, key, SpokeDynamicReserveConfig(0, 10_500, 0));
        _cutCf();
        vm.prank(bob);
        vm.expectRevert(IAaveV4Errors.HealthFactorBelowThreshold.selector);
        adapter.borrow(MARKET, debtReserveId, 1e18, bob);
    }

    /// @notice Bug hunted: a Spoke pause is not a full emergency stop. Repay, withdrawal (with or without debt),
    /// liquidation, borrow and pledge all revert while paused; fee collection, which never touches the Spoke and pays
    /// fees that are not collateral, still works. Unpausing reopens repay.
    function test_spokePause_stopsEveryAaveAction() public {
        (bytes32 aKey, bytes32 bKey, address cAccount) = _threeAccounts();
        vm.prank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).pauseAllReserves(aave.cdpSpoke);
        _checkStopped(IAaveV4Errors.ReservePaused.selector, aKey, bKey, cAccount);
        vm.startPrank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).updatePaused(aave.cdpSpoke, vtReserveId, false);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).updatePaused(aave.cdpSpoke, debtReserveId, false);
        vm.stopPrank();
        _repayAll(alice);
        assertEq(spoke.getUserTotalDebt(debtReserveId, adapter.accountOf(alice, MARKET)), 0);
    }

    /// @notice Bug hunted: a Hub halt of the CDP Spoke is not a full emergency stop. Repay, withdrawal, liquidation,
    /// borrow and pledge all revert with `SpokeHalted`; fee collection still works. Lifting the halt reopens repay.
    function test_hubHalt_stopsEveryAaveAction() public {
        (bytes32 aKey, bytes32 bKey, address cAccount) = _threeAccounts();
        vm.prank(aaveDao);
        ILifecycleHubConfigurator(aave.hubConfigurator).haltSpoke(aave.hub, aave.cdpSpoke);
        _checkStopped(IAaveV4Errors.SpokeHalted.selector, aKey, bKey, cAccount);
        vm.startPrank(aaveDao);
        ILifecycleHubConfigurator(aave.hubConfigurator).updateSpokeHalted(aave.hub, vtAssetId, aave.cdpSpoke, false);
        ILifecycleHubConfigurator(aave.hubConfigurator)
            .updateSpokeHalted(aave.hub, spoke.getReserve(debtReserveId).assetId, aave.cdpSpoke, false);
        vm.stopPrank();
        _repayAll(alice);
        assertEq(spoke.getUserTotalDebt(debtReserveId, adapter.accountOf(alice, MARKET)), 0);
    }

    // ─── Case 2: top-up through the adapter after a direct increase ───

    /// @notice Bug hunted: after liquidity is added straight on the NFPM (bypassing Avana), `AaveAdapter.addLiquidity`
    /// supplies credit for the direct liquidity too (double count), loses part of the new liquidity, or keeps the
    /// unused tokens. The supply grows by exactly the new liquidity's credit, the unused token comes back to the owner,
    /// and a full withdrawal returns the NFT with all its liquidity and burns exactly the supply.
    function test_addLiquidity_afterADirectIncrease_suppliesExactlyTheNewCredit() public {
        (bytes32 bKey, uint128 l0) = _mintFull(bob, SIZE);
        (, uint128 c0) = _pledge(bob, bKey);
        address account = adapter.accountOf(bob, MARKET);
        uint128 extra = _directIncrease(bKey, 100e18);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), c0);
        assertEq(vault.accountCredit(account, MARKET), c0);

        _fundTopUp(bob, 50e18, 10e18);
        vm.prank(bob);
        (uint128 added, uint128 credit, uint256 a0, uint256 a1) = adapter.addLiquidity(bKey, 50e18, 10e18, 0, 0);
        assertEq(credit, added, "a full-band top-up is credited its liquidity");
        assertEq(t0.balanceOf(bob), 50e18 - a0, "unused token0 back to the owner");
        assertEq(t1.balanceOf(bob), 10e18 - a1);
        assertGt(t0.balanceOf(bob), 0);
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), uint256(c0) + credit);
        assertEq(vault.accountCredit(account, MARKET), uint256(c0) + credit);
        assertEq(vt.totalSupply(), uint256(c0) + credit);
        assertEq(t0.balanceOf(address(vault)) + t0.balanceOf(address(adapter)), 0);
        assertEq(t1.balanceOf(address(vault)) + t1.balanceOf(address(adapter)), 0);

        vm.prank(bob);
        adapter.withdraw(bKey, 0, 0, 0, bob);
        assertEq(nfpm.ownerOf(uint256(bKey)), bob);
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(bKey)).liquidity, l0 + added + extra);
        assertEq(vt.totalSupply(), 0);
    }

    // ─── Case 1: duplicate pledge and unsolicited assets ───

    /// @notice Bug hunted: the same NFT pledged twice in one `multicall` gets two records or double collateral, or
    /// leaves the account or vault tokens behind when the batch fails.
    function test_duplicatePledgeInOneMulticall_revertsWhole() public {
        (bytes32 bKey,) = _mintFull(bob, SIZE);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(AaveAdapter.pledge, (bKey));
        calls[1] = calls[0];
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.AlreadyPledged.selector, bKey));
        adapter.multicall(calls);
        assertEq(nfpm.ownerOf(uint256(bKey)), bob);
        assertEq(vault.getPosition(bKey).account, address(0));
        assertEq(adapter.accountOf(bob, MARKET), address(0));
        assertEq(vt.totalSupply(), 0);
    }

    /// @notice Bug hunted: tokens and NFTs sent straight to the LPVault, the adapter or the LiquidationModule are paid
    /// out in a later flow, counted as someone's repayment, fees or principal, or let an NFT be pledged without its
    /// owner. Every later flow pays only its own amounts and the stray assets stay where they were sent.
    function test_unsolicitedAssets_toVaultAdapterAndModule_moveNoLedger() public {
        (bytes32 aKey,) = _mintFull(alice, SIZE);
        (bytes32 bKey,) = _mintFull(bob, SIZE);
        (bytes32 stray,) = _mintFull(dave, SIZE);
        address[3] memory sinks = [address(vault), address(adapter), address(module)];
        for (uint256 i; i < sinks.length; ++i) {
            t0.mint(sinks[i], 7e18);
            t1.mint(sinks[i], 7e18);
            debt.mint(sinks[i], 7e18);
        }
        vm.prank(dave);
        nfpm.transferFrom(dave, address(adapter), uint256(stray));
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(ILPVault.NotTokenOwner.selector, stray));
        adapter.pledge(stray);

        _pledge(alice, aKey);
        _pledge(bob, bKey);
        _borrow(alice, 100e18);
        assertEq(debt.balanceOf(alice), 100e18);
        debt.mint(alice, 1e18);
        vm.startPrank(alice);
        debt.approve(address(adapter), type(uint256).max);
        uint256 repaid = adapter.repay(MARKET, debtReserveId, type(uint256).max, alice);
        vm.stopPrank();
        assertEq(repaid, 100e18);
        assertEq(debt.balanceOf(alice), 1e18, "alice paid exactly her debt");
        _trade();
        _checkCollectFees(bob, bKey);
        vm.prank(bob);
        adapter.withdraw(bKey, 0, 0, 0, bob);
        assertEq(nfpm.ownerOf(uint256(bKey)), bob);

        for (uint256 i; i < sinks.length; ++i) {
            assertEq(t0.balanceOf(sinks[i]), 7e18);
            assertEq(t1.balanceOf(sinks[i]), 7e18);
            assertEq(debt.balanceOf(sinks[i]), 7e18);
        }
        assertEq(nfpm.ownerOf(uint256(stray)), address(adapter));
        assertEq(vault.getPosition(stray).account, address(0));
    }

    // ─── Helpers ───

    /// @dev Alice pledges and borrows $800, Bob pledges with no debt, Carol pledges and borrows $1,500, fees accrue,
    /// then the price falls so Carol is unhealthy.
    function _threeAccounts() internal returns (bytes32 aKey, bytes32 bKey, address cAccount) {
        (aKey,) = _mintFull(alice, SIZE);
        (bKey,) = _mintFull(bob, SIZE);
        (bytes32 cKey,) = _mintFull(carol, SIZE);
        _pledge(alice, aKey);
        _pledge(bob, bKey);
        _pledge(carol, cKey);
        _borrow(alice, 800e18);
        _borrow(carol, 1500e18);
        _trade();
        feed0.set(0.8e8);
        feed1.set(0.8e8);
        cAccount = adapter.accountOf(carol, MARKET);
        assertLt(spoke.getUserAccountData(cAccount).healthFactor, 1e18);
    }

    /// @dev Under an emergency stop: repay, withdrawal with and without debt, liquidation, borrow and pledge revert
    /// with `err`; fee collection pays exactly the fees.
    function _checkStopped(
        bytes4 err,
        bytes32 aKey,
        bytes32 bKey,
        address cAccount
    ) internal {
        debt.mint(alice, 1e21);
        vm.startPrank(alice);
        debt.approve(address(adapter), type(uint256).max);
        vm.expectRevert(err);
        adapter.repay(MARKET, debtReserveId, 1e18, alice);
        vm.expectRevert(err);
        adapter.withdraw(aKey, 0, 0, 0, alice);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(err);
        adapter.withdraw(bKey, 0, 0, 0, bob);
        vm.prank(bob);
        vm.expectRevert(err);
        adapter.borrow(MARKET, debtReserveId, 1e18, bob);
        vm.prank(liquidator);
        vm.expectRevert(err);
        module.liquidate(_params(cAccount, 100e18));
        (bytes32 dKey,) = _mintFull(dave, SIZE);
        vm.prank(dave);
        vm.expectRevert(err);
        adapter.pledge(dKey);
        assertEq(nfpm.ownerOf(uint256(dKey)), dave);
        assertEq(nfpm.ownerOf(uint256(bKey)), address(vault));
        _checkCollectFees(bob, bKey);
    }

    function _checkCollectFees(
        address wallet,
        bytes32 key
    ) internal {
        (uint256 f0, uint256 f1) = vault.feesOf(key);
        assertGt(f0 + f1, 0, "fees accrued");
        uint256 b0 = t0.balanceOf(wallet);
        uint256 b1 = t1.balanceOf(wallet);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(wallet);
        adapter.collectFees(MARKET, keys);
        assertEq(t0.balanceOf(wallet) - b0, f0);
        assertEq(t1.balanceOf(wallet) - b1, f1);
    }

    function _freezeAndCutCf() internal {
        vm.prank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserveId, true);
        _cutCf();
    }

    /// @dev Aave's deprecation step: a new dynamic config with collateral factor 0, the rest unchanged.
    function _cutCf() internal {
        vm.prank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator)
            .addDynamicReserveConfig(aave.cdpSpoke, vtReserveId, SpokeDynamicReserveConfig(0, 10_500, 0));
    }
}
