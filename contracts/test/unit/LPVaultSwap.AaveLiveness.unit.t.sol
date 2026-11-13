// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationDebtMark} from "../../src/custody/collateralization/ICollateralizationDebtMark.sol";
import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

interface IReserveFlagConfigurator {
    function updateBorrowable(
        address spoke,
        uint256 reserveId,
        bool borrowable
    ) external;

    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
}

/// @title LPVaultSwapAaveLivenessUnitTest
/// @notice Liquidation stays open under Aave's own risk actions on a debt reserve, and a liquidation that removes an
/// account's last debt clears its indebted mark. Real local Aave V4 Hub, Spoke and SpokeConfigurator, real LPVaultSwap,
/// Collateralization, Lock and vault token.
/// forge-config: default.isolate = false
contract LPVaultSwapAaveLivenessUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        // Bob: 10,000 vault units pledged at $2.50, 18,000 USDC borrowed; at $2.10 his HF is below 1.
        (proxy,) = _bobAccount();
    }

    function _setBorrowable(
        bool on
    ) internal {
        vm.prank(aaveDao);
        IReserveFlagConfigurator(aave.spokeConfigurator).updateBorrowable(aave.cdpSpoke, usdcReserveId, on);
    }

    // TEST-055 verifies: REQ-SWAP-087, REQ-SWAP-095, REQ-SWAP-003, ATTACK-200
    /// @notice After the Aave DAO turns off new USDC borrowing, the liquidation of an account owing USDC runs exactly as
    /// it does with borrowing on (same seizure and settlement), as Aave's own liquidation does.
    function test_TEST_055_liquidationRunsWithBorrowingOff() public {
        assertLt(_hf(proxy), 1e18, "liquidatable");
        uint256 snap = vm.snapshotState();
        LiquidationResult memory on = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snap);
        _setBorrowable(false);
        assertFalse(IAaveV4Spoke(aave.cdpSpoke).getReserveConfig(usdcReserveId).borrowable, "borrowing off");
        LiquidationResult memory off = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(off.unitsSeized, 0, "units seized");
        assertEq(off.unitsSeized, on.unitsSeized, "same seizure");
        assertEq(off.debtRepaid, on.debtRepaid, "same repayment");
        assertEq(off.keeperOut, on.keeperOut, "same settlement");
    }

    // TEST-055 verifies: REQ-SWAP-087, REQ-SWAP-003, ATTACK-200
    /// @notice A week of falling prices with borrowing off: the account is still liquidated in full steps; the direct
    /// `liquidationCall` stays refused by the vault token, so LPVaultSwap is the path that must stay open.
    function test_TEST_055_borrowingOffDeepUnderwaterStillLiquidates() public {
        _setBorrowable(false);
        usdc.mint(attacker, 1950e6);
        vm.startPrank(attacker);
        usdc.approve(aave.cdpSpoke, 1950e6);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, attacker));
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, 1950e6, false);
        vm.stopPrank();
        lpOracle.setAnswer(150_000_000);
        vm.warp(block.timestamp + 7 days);
        lpOracle.setAnswer(150_000_000);
        assertLt(_hf(proxy), 0.7e18, "deep underwater");
        uint256 suppliedBefore = _suppliedUnits(proxy);
        LiquidationParams memory p = _params(proxy, _debtOf(proxy, usdcReserveId));
        p.deadline = block.timestamp + 120;
        p.maxShortfall = p.debtToCover / 5;
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertGt(r.unitsSeized, 0, "seized");
        assertEq(_suppliedUnits(proxy), suppliedBefore - r.unitsSeized, "units left the account");
    }

    // TEST-055 verifies: REQ-SWAP-087, REQ-SWAP-095
    /// @notice A reserve the MarketRegistry has not enabled is still refused, borrowable or not.
    function test_TEST_055_unapprovedReserveStillRefused() public {
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, _debtDef(usdcReserveId, address(usdc), 6, false), false);
        _expectLiquidateRevert(
            keeper,
            _params(proxy, 1950e6),
            abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, usdcReserveId)
        );
    }

    // TEST-055 verifies: REQ-SWAP-003
    /// @notice Aave's other risk action, a frozen debt reserve, leaves liquidation open as well.
    function test_TEST_055_liquidationRunsWithReserveFrozen() public {
        vm.prank(aaveDao);
        IReserveFlagConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, usdcReserveId, true);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "frozen reserve: liquidation still runs");
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-SWAP-026
    /// @notice Liquidating an account until Aave reports no borrow left (the rest as deficit) clears its indebted mark
    /// in the last liquidation, so the market reads debt-free with no keeper `refreshDebtMark`.
    function test_TEST_272_liquidationToZeroBorrowsClearsTheMark() public {
        _mark(proxy);
        ICollateralizationViews views = ICollateralizationViews(address(coll));
        assertFalse(views.getMarketDebtFree(address(vt)), "marked before");
        lpOracle.setAnswer(100_000_000);
        for (uint256 i = 0; i < 30 && _suppliedUnits(proxy) != 0; ++i) {
            uint256 owed = _debtOf(proxy, usdcReserveId);
            LiquidationParams memory p = _params(proxy, owed);
            p.maxShortfall = owed / 5;
            _liquidateAs(keeper, p);
            if (_suppliedUnits(proxy) != 0) assertFalse(views.getMarketDebtFree(address(vt)), "debt remains: marked");
        }
        assertEq(_suppliedUnits(proxy), 0, "all collateral seized");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).borrowCount, 0, "no borrows left");
        assertTrue(views.getMarketDebtFree(address(vt)), "mark cleared by the liquidation");
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-SWAP-026
    /// @notice A partial liquidation keeps the mark: debt remains.
    function test_TEST_272_partialLiquidationKeepsTheMark() public {
        _mark(proxy);
        _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(_debtOf(proxy, usdcReserveId), 0, "debt remains");
        assertFalse(ICollateralizationViews(address(coll)).getMarketDebtFree(address(vt)), "still marked");
    }

    /// @dev The fixture's Adapter stand-in borrows without marking; mark the account as the real Adapter's `borrow`.
    function _mark(
        address p
    ) internal {
        vm.startPrank(address(adapter));
        lock.acquire();
        ICollateralizationDebtMark(address(coll)).markIndebted(p);
        lock.release();
        vm.stopPrank();
    }
}
