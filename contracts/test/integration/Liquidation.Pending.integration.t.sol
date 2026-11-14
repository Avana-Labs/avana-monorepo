// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BackingView} from "../../src/lens/lens/types/BackingView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PendingView} from "../../src/types/PendingView.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @title LiquidationPendingIntegrationTest
/// @notice Pending settlement on the real stack (`RealStackFlows`). An earlier, non-conforming LPVaultSwap
/// implementation kept the units of a seizure (simulated by a direct `liquidationCall` from LPVaultSwap's address,
/// which the vault token admits as the only seizure recipient). The next honest liquidation through the real
/// LPVaultSwap, or the borrower's withdrawal through the real AaveAdapter, reconciles them into Collateralization's
/// pending balance; `settlePending` by any caller burns them through the real Adapter's `burnSeized`, unwinds them
/// through the real Uniswap v3 LPVault and NonfungiblePositionManager, swaps both pool tokens through the real
/// `DexPathRoute`s into the market's settlement asset (GHO, `registry.settlementReserve`) and funds the real
/// First-Loss Reserve of the market's (Hub, settlement asset). The Lens's pending and backing views are checked at each
/// step.
/// @dev Bob's account: 10,000 vault tokens ($20,000 at $2.00, CF 30 %) against 5,880 USDC, HF 1.020; USDT then falls
/// to $0.93 (`_depegUsdt`), the vault token to $1.9287 and HF to 0.984. The kept seizure repays 50 USDC and seizes
/// `50 × bonus × pUSDC / 1.9287` vault tokens (the Spoke's bonus at that HF, as the Lens reports it); the honest
/// liquidation then repays the Lens's `params.debtToCover` and seizes its `expectedUnitsSeized`.
/// forge-config: default.isolate = false
contract LiquidationPendingIntegrationTest is RealStackFlows {
    uint256 internal constant KEPT_REPAY = 50e6;
    uint256 internal mA;
    address internal vt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    function _bobAccount() internal returns (address proxy, bytes32 key) {
        (key, proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 5880e6);
        _depegUsdt(93_000_000);
    }

    /// @dev A seizure whose units LPVaultSwap kept, outside any Avana call. Returns the units seized.
    function _keptSeizure(
        address proxy,
        uint256 x
    ) internal returns (uint256 seized) {
        uint256 before = IERC20(vt).balanceOf(lpVaultSwap);
        usdc.mint(lpVaultSwap, x);
        vm.startPrank(lpVaultSwap);
        usdc.approve(aave.cdpSpoke, x);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(mkt[mA].reserveId, usdcReserveId, proxy, x, false);
        usdc.approve(aave.cdpSpoke, 0);
        vm.stopPrank();
        seized = IERC20(vt).balanceOf(lpVaultSwap) - before;
    }

    /// @dev The units a repayment of `x` USDC seizes at the Spoke's current bonus: `x × bonus × pUSDC / pVT`.
    function _expectedSeizure(
        address proxy,
        uint256 x
    ) internal view returns (uint256) {
        uint256 bonusBps = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120).bonusBps;
        uint256 pDebt = uint256(usdcOracle.latestAnswer());
        uint256 pVt = uint256(mkt[mA].oracle.latestAnswer());
        return x * bonusBps * pDebt / (10_000 * pVt);
    }

    function _credited(
        bytes32 key
    ) internal view returns (uint256) {
        return coll.getRecord(coll.recordIdOf(V3, key)).credited;
    }

    // TEST-151 verifies: REQ-SWAP-020, REQ-SWAP-045, REQ-ADAPTER-070, INV-005, INV-080, Q-160, Q-201, Q-224
    // TEST-170 verifies: REQ-SWAP-044, REQ-SWAP-076, SPEC-LIQ-014, REQ-ADAPTER-070, INV-021, Q-160
    function test_TEST_170_honestLiquidationReconcilesThenSettlePendingFundsCoverage() public {
        (address proxy, bytes32 key) = _bobAccount();
        uint256 pledged = _credited(key);
        uint256 expectedKept = _expectedSeizure(proxy, KEPT_REPAY);
        uint256 kept = _keptSeizure(proxy, KEPT_REPAY);
        assertApproxEqAbs(kept, expectedKept, 2, "50 x bonus x pUSDC / pVT");
        assertEq(lens.checkBacking(vt).unsettledSeizedUnits, kept, "Lens: unsettled seized units held by LPVaultSwap");
        RecordView[] memory recs = lens.getRecords(proxy, 0, 16);
        assertEq(recs[0].creditedAfterReconcile, pledged - kept, "Lens: withdrawal units after reconciliation");

        LiquidationPreview memory lp = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertTrue(lp.aaveLiquidatable, "still below HF 1 after the kept seizure");
        LiquidationResult memory r = _liquidateAs(keeper, lp.params);
        assertEq(r.unitsSeized, lp.expectedUnitsSeized, "the honest seizure settles on its own units");
        assertEq(coll.getPending(vt).units, kept, "the kept units moved to pending");
        assertEq(_credited(key), pledged - kept - r.unitsSeized, "debit");
        assertEq(IERC20(vt).balanceOf(lpVaultSwap), kept, "LPVaultSwap still holds the kept units");
        uint256 settleReserve = registry.settlementReserve(mA);
        address reserve = firstLossReserveOf[address(_assetOf(settleReserve))];
        PendingView memory pv = lens.getPendingSettlement(vt);
        assertEq(pv.units, kept, "Lens: pending units");
        assertTrue(pv.settleable, "Lens: settleable");
        assertEq(pv.firstLossReserve, reserve, "Lens: the settlement asset's First-Loss Reserve");
        assertTrue(lens.checkBacking(vt).supplyEqualsCredited, "Lens: supply = credited + pending");

        // Any caller, under Paused, with both pool tokens swapped into the settlement asset and added to its
        // First-Loss Reserve.
        _setPause(PauseState.Paused, PauseReason.MintPathSuspect);
        uint256 supplyBefore = IERC20(vt).totalSupply();
        uint256 fundedBefore = IAvanaFirstLossReserve(reserve).fundedBalance();
        vm.expectEmit(true, true, false, true, adapter);
        emit IAaveAdapterEvents.SeizedUnitsBurned(mA, vt, kept);
        vm.prank(makeAddr("anyone"));
        (uint256 units,, uint256 added) = lvs.settlePending(mA, settleReserve);
        assertEq(units, kept, "every pending unit settled");
        assertEq(supplyBefore - IERC20(vt).totalSupply(), kept, "burned by the real Adapter");
        assertEq(coll.getPending(vt).units, 0, "pending cleared");
        assertGt(added, 0, "proceeds recovered through the real unwind and routes");
        assertApproxEqAbs(
            IAvanaFirstLossReserve(reserve).fundedBalance(), fundedBefore + added, 1, "added to the First-Loss Reserve"
        );
        assertEq(
            usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap) + gho.balanceOf(lpVaultSwap)
                + IERC20(vt).balanceOf(lpVaultSwap),
            0,
            "empty"
        );
        BackingView memory b = lens.checkBacking(vt);
        assertTrue(b.supplyEqualsCredited, "Lens: backed");
        assertEq(b.pendingUnits + b.unsettledSeizedUnits, 0, "Lens: nothing pending");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice The borrower repays and withdraws through the real Adapter after a kept seizure: the withdrawal
    /// reconciles the kept units into pending and returns the NFT with the units left.
    // TEST-151 verifies: REQ-ADAPTER-071, REQ-PROXY-035, INV-005, INV-080, Q-201
    function test_TEST_151_withdrawalReconcilesKeptSeizure() public {
        (address proxy, bytes32 key) = _bobAccount();
        uint256 kept = _keptSeizure(proxy, KEPT_REPAY);
        uint256 owed = _debtOf(proxy, usdcReserveId);
        _repayVia(bob, bob, mA, usdcReserveId, owed, true);
        uint256 left = lens.getRecords(proxy, 0, 16)[0].creditedAfterReconcile;
        _withdrawVia(bob, mA, key, left);
        assertEq(IERC721(address(nfpm)).ownerOf(uint256(key)), bob, "NFT returned");
        assertEq(coll.getPending(vt).units, kept, "kept units reconciled into pending");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt) + kept, "supply = credited + pending");
        assertEq(lens.getRecords(proxy, 0, 16).length, 0, "Lens: no record left");
    }

    // TEST-170 verifies: REQ-SWAP-044, SPEC-LIQ-014
    function test_TEST_170_nothingPendingRefused() public {
        uint256 settleReserve = registry.settlementReserve(mA);
        vm.expectRevert(ILPVaultSwapErrors.NothingPending.selector);
        lvs.settlePending(mA, settleReserve);
    }
}
