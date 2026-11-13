// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AccountView} from "../../src/lens/lens/types/AccountView.sol";
import {BackingView} from "../../src/lens/lens/types/BackingView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PendingView} from "../../src/types/PendingView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensJourneyIntegrationTest
/// @notice One borrower's journey on the real Aave V4 Spoke and Collateralization with the Lens asserted at every step
/// against what the chain then holds: pledge, borrow, partial repay, a third party's donation and its re-credit
/// preview, a price drop, a partial seizure sized by the Lens and executed by Aave's own `liquidationCall` (the Lens's
/// sizing against Aave's formula), reconciliation into pending settlement, repay all and the full withdrawal; the
/// frozen-wallet and pause variants keep the views answering. The seizure calls the Spoke as the LPVaultSwap address
/// directly, so this file checks the Lens against Aave (TEST-247); the journey through the real LPVaultSwap is
/// TEST-223 in `LpJourney.integration.t.sol`.
/// forge-config: default.isolate = false
contract LensJourneyIntegrationTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-008, REQ-LENS-009, REQ-LENS-011, REQ-LENS-012, REQ-LENS-016, REQ-LENS-026, REQ-LENS-028, REQ-LENS-035, REQ-LENS-036, REQ-LENS-038, Q-268
    function test_TEST_247_borrowerJourney() public {
        // Before the pledge: the predicted account.
        (address predicted, bool deployed) = lens.predictProxy(alice, MARKET_ID);
        assertFalse(deployed, "no account yet");
        assertEq(predicted, proxyManager.predictProxy(alice, aave.cdpSpoke, MARKET_ID), "CREATE2 address");

        // Pledge 20,000 whole vault tokens ($40,000).
        _open(alice, aliceProxy, 1, 20_000e6);
        AccountView memory a = lens.getAccount(alice, MARKET_ID);
        assertEq(a.markets[0].credited, 20_000e6, "credited");
        assertTrue(lens.checkBacking(vt).supplyEqualsCredited, "backed");

        // Borrow the recommended amount.
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        _borrow(aliceProxy, rec);
        assertApproxEqRel(_hf(aliceProxy), 1.1e18, 1e12, "lands at the recommended 1.10");
        assertLt(rec, max, "below the maximum");

        // Partial repay of a quarter of the debt.
        vm.warp(block.timestamp + 30 days);
        uint256 owed = _debtOf(aliceProxy, debtReserveId);
        _repay(aliceProxy, owed / 4);
        assertEq(lens.getAccount(alice, MARKET_ID).debts[0].total, _debtOf(aliceProxy, debtReserveId), "debt shown");

        // A third party adds liquidity to the position: re-credit preview.
        vault.addUnits(_key(1), 1000e6);
        (uint128 added, uint256 charge, bool rescueOnly) = lens.previewRecredit(MARKET_ID, _key(1));
        assertEq(added, 1000e6, "the donated units");
        assertEq(charge, 2000e8, "at $2.00");
        assertFalse(rescueOnly, "regular");

        // Price drop (fresh feed rounds) and a partial liquidation sized by the Lens.
        lpo.setTokenAt(0, uint64(block.timestamp - 60), 0);
        lpo.setTokenAt(1, uint64(block.timestamp - 60), 0);
        _setVtPrice(1.3e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, block.timestamp + 120);
        assertTrue(p.aaveLiquidatable && p.pricesUsable, "liquidatable with usable prices");
        uint256 seized = _seizeAndKeep(aliceProxy, p.params.debtToCover);
        assertEq(seized, p.expectedUnitsSeized, "seized as previewed");
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r[0].creditedAfterReconcile, 20_000e6 - seized, "withdrawal units after reconciliation");
        assertEq(lens.getAccount(alice, MARKET_ID).markets[0].shortfall, seized, "shortfall shown");

        // Repay all with the Lens's quote, then withdraw everything: the seizure reconciles into pending.
        _setVtPrice(2e8);
        uint256 quote = lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp + 600);
        vm.warp(block.timestamp + 600);
        assertGe(quote, _debtOf(aliceProxy, debtReserveId), "the quote covers the debt at the deadline");
        _repay(aliceProxy, _debtOf(aliceProxy, debtReserveId));
        _withdraw(aliceProxy, _key(1), r[0].creditedAfterReconcile);
        PendingView memory pend = lens.getPendingSettlement(vt);
        assertEq(pend.units, seized, "pending units");
        assertTrue(pend.settleable, "LPVaultSwap holds them");
        BackingView memory b = lens.checkBacking(vt);
        assertTrue(b.supplyEqualsCredited, "supply = credited + pending");
        assertEq(lens.getRecords(aliceProxy, 0, 16).length, 0, "no record left");
        assertEq(lens.getAccount(alice, MARKET_ID).markets[0].credited, 0, "nothing credited");
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-031, REQ-LENS-037, REQ-LENS-038, Q-242, Q-252
    function test_TEST_247_frozenAndPausedVariantsKeepViewsOpen() public {
        _open(alice, aliceProxy, 1, 20_000e6);
        _borrow(aliceProxy, 10_000e18);
        vault.addUnits(_key(1), 1000e6);
        reg.setFrozen(alice, true);
        assertTrue(lens.getAccount(alice, MARKET_ID).walletFrozen, "frozen wallet shown");
        (,, bool rescueOnly) = lens.previewRecredit(MARKET_ID, _key(1));
        assertTrue(rescueOnly, "a frozen depositor re-credits only as a rescue top-up");
        assertGt(lens.quoteRepayAll(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "repay stays open");
        reg.setFrozen(alice, false);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        assertEq(lens.getPauseReason(aave.hub), 2, "MintPathSuspect");
        (uint256 x,,) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), 100e6, debtReserveId);
        assertEq(x, 0, "repay with collateral closed while Paused");
        assertTrue(lens.previewLiquidation(aliceProxy, debtReserveId, block.timestamp).pricesUsable, "liquidation open");
        // The RiskModule reports the Hub's pause in the account's gate status.
        rm.setGate(aliceProxy, true, false, PauseState.Paused);
        assertEq(lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp), 0, "borrowing closed");
    }

    function _repay(
        address proxy,
        uint256 amount
    ) internal {
        debt.mint(proxy, amount);
        vm.startPrank(proxy);
        debt.approve(aave.cdpSpoke, amount);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, amount, proxy);
        vm.stopPrank();
    }
}
