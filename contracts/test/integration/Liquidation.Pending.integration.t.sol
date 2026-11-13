// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BackingView} from "../../src/lens/lens/types/BackingView.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PendingView} from "../../src/types/PendingView.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title LiquidationPendingIntegrationTest
/// @notice Pending settlement on the deployed stack. An earlier, non-conforming LPVaultSwap implementation kept the
/// units of a seizure (simulated by a direct `liquidationCall` from LPVaultSwap's address, which the vault token admits
/// as the only seizure recipient). The next honest liquidation through the real LPVaultSwap, or the borrower's
/// withdrawal through the real AaveAdapter, reconciles them into Collateralization's pending balance; `settlePending`
/// by any caller burns them through the real Adapter's `burnSeized`, unwinds them and funds the Coverage Spoke of the
/// market's (Hub, settlement asset). The Lens's pending and backing views are checked at each step.
/// forge-config: default.isolate = false
contract LiquidationPendingIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    /// @dev A seizure whose units LPVaultSwap kept, outside any Avana call. Returns the units seized.
    function _keptSeizure(
        address proxy,
        uint256 x
    ) internal returns (uint256 seized) {
        uint256 before = token.balanceOf(lpVaultSwap);
        usdc.mint(lpVaultSwap, x);
        vm.startPrank(lpVaultSwap);
        usdc.approve(aave.cdpSpoke, x);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, usdcReserveId, proxy, x, false);
        usdc.approve(aave.cdpSpoke, 0);
        vm.stopPrank();
        seized = token.balanceOf(lpVaultSwap) - before;
    }

    // TEST-151 verifies: REQ-SWAP-020, REQ-SWAP-045, REQ-ADAPTER-070, INV-005, INV-080, Q-160, Q-201, Q-224
    // TEST-170 verifies: REQ-SWAP-044, REQ-SWAP-076, SPEC-LIQ-014, REQ-ADAPTER-070, INV-021, Q-160
    function test_TEST_170_honestLiquidationReconcilesThenSettlePendingFundsCoverage() public {
        (address proxy, bytes32 key) = _bobAccount();
        uint256 kept = _keptSeizure(proxy, 300e6);
        assertEq(kept, 150e6, "300 x 1.05 / 2.10");
        assertEq(lens.checkBacking(vt).unsettledSeizedUnits, kept, "Lens: unsettled seized units held by LPVaultSwap");
        RecordView[] memory recs = lens.getRecords(proxy, 0, 16);
        assertEq(recs[0].creditedAfterReconcile, 10_000e6 - kept, "Lens: withdrawal units after reconciliation");

        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(proxy, MARKET_ID, usdcReserveId, 1950e6));
        assertEq(r.unitsSeized, 975e6, "the honest seizure settles on its own units");
        assertEq(coll.getPending(vt).units, kept, "the kept units moved to pending");
        assertEq(coll.getRecord(coll.recordIdOf(INTEGRATION, key)).credited, 10_000e6 - kept - r.unitsSeized, "debit");
        assertEq(token.balanceOf(lpVaultSwap), kept, "LPVaultSwap still holds the kept units");
        PendingView memory pv = lens.getPendingSettlement(vt);
        assertEq(pv.units, kept, "Lens: pending units");
        assertTrue(pv.settleable, "Lens: settleable");
        assertEq(pv.coverageSpoke, address(usdcCoverage), "Lens: the settlement asset's Coverage Spoke");
        assertTrue(lens.checkBacking(vt).supplyEqualsCredited, "Lens: supply = credited + pending");

        // Any caller, under Paused, with the pool tokens swapped into USDC and added to the Coverage Spoke.
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        uint256 supplyBefore = token.totalSupply();
        uint256 fundedBefore = usdcCoverage.fundedBalance();
        vm.expectEmit(true, true, false, true, adapter);
        emit IAaveAdapterEvents.SeizedUnitsBurned(MARKET_ID, vt, kept);
        vm.prank(makeAddr("anyone"));
        (uint256 units,, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, kept, "every pending unit settled");
        assertEq(supplyBefore - token.totalSupply(), kept, "burned by the real Adapter");
        assertEq(coll.getPending(vt).units, 0, "pending cleared");
        assertGt(added, 0, "proceeds recovered");
        assertApproxEqAbs(usdcCoverage.fundedBalance(), fundedBefore + added, 1, "added to the Coverage Spoke");
        assertEq(usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap) + token.balanceOf(lpVaultSwap), 0, "empty");
        BackingView memory b = lens.checkBacking(vt);
        assertTrue(b.supplyEqualsCredited, "Lens: backed");
        assertEq(b.pendingUnits + b.unsettledSeizedUnits, 0, "Lens: nothing pending");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice The borrower repays and withdraws through the real Adapter after a kept seizure: the withdrawal
    /// reconciles the kept units into pending and returns the position with the units left.
    // TEST-151 verifies: REQ-ADAPTER-071, REQ-PROXY-035, INV-005, INV-080, Q-201
    function test_TEST_151_withdrawalReconcilesKeptSeizure() public {
        (address proxy, bytes32 key) = _bobAccount();
        uint256 kept = _keptSeizure(proxy, 300e6);
        uint256 owed = _debtOf(proxy, usdcReserveId);
        _repayVia(bob, bob, MARKET_ID, usdcReserveId, owed, true);
        uint256 left = lens.getRecords(proxy, 0, 16)[0].creditedAfterReconcile;
        _withdrawVia(bob, MARKET_ID, key, left);
        assertEq(vault.ownerOf(key), bob, "position returned");
        assertEq(coll.getPending(vt).units, kept, "kept units reconciled into pending");
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + kept, "supply = credited + pending");
        assertEq(lens.getRecords(proxy, 0, 16).length, 0, "Lens: no record left");
    }

    // TEST-170 verifies: REQ-SWAP-044, SPEC-LIQ-014
    function test_TEST_170_nothingPendingRefused() public {
        vm.expectRevert(ILPVaultSwapErrors.NothingPending.selector);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }
}
