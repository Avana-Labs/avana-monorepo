// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {BackingView} from "../../src/lens/lens/types/BackingView.sol";
import {RecordBackingView} from "../../src/lens/lens/types/RecordBackingView.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {CapView} from "../../src/types/CapView.sol";
import {PendingView} from "../../src/types/PendingView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensMarketUnitTest
/// @notice `checkBacking`, `checkRecordBacking`, `getPendingSettlement` and `getCapHeadroom` on the real
/// Collateralization, vault token and Aave V4 Hub and Spoke.
/// forge-config: default.isolate = false
contract LensMarketUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
        _open(bob, bobProxy, 2, 4000e6);
    }

    // ─── checkBacking ───

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-005, INV-001
    function test_TEST_247_checkBackingRawValues() public view {
        BackingView memory b = lens.checkBacking(vt);
        assertEq(b.blockNumber, block.number, "block");
        assertEq(b.timestamp, block.timestamp, "timestamp");
        assertEq(b.marketId, MARKET_ID, "market");
        assertEq(b.hub, aave.hub, "home Hub");
        assertEq(b.vaultToken, vt, "vault token");
        assertEq(b.assetId, vtAssetId, "asset");
        assertEq(b.reserveId, vtReserveId, "reserve");
        assertEq(b.totalSupply, 14_000e6, "supply");
        assertEq(b.totalCredited, 14_000e6, "credited");
        assertEq(b.pendingUnits, 0, "nothing pending");
        assertEq(b.pendingAmounts.length, coll.getPending(vt).amounts.length, "Collateralization's pending amounts");
        assertEq(b.unsettledSeizedUnits, 0, "LPVaultSwap holds none");
        assertEq(b.hubBalance, 14_000e6, "Hub holds the supplied units");
        assertEq(b.hubLiquidity, IAaveV4Hub(aave.hub).getAssetLiquidity(vtAssetId), "Hub liquidity");
        assertEq(b.stranded, 0, "nothing stranded");
        assertEq(b.addedAssets, 14_000e6, "added assets");
        assertEq(b.addedShares, 14_000e6, "added shares");
        assertEq(b.drawnShares, 0, "no drawn shares");
    }

    // TEST-247 verifies: REQ-LENS-012, INV-001, INV-003
    function test_TEST_247_checkBackingHealthyFlags() public {
        _setAddCap(vtAssetId, aave.treasurySpoke, 0);
        BackingView memory b = lens.checkBacking(vt);
        assertTrue(b.supplyEqualsCredited, "supply = credited + pending");
        assertTrue(b.hubHoldsSupplied, "Hub balance covers its liquidity");
        assertTrue(b.sharesEqualAssets, "shares = assets");
        assertTrue(b.noDrawnShares, "nothing drawn");
        assertTrue(b.noDrawCap, "no draw cap on any Spoke");
        assertTrue(b.singleBorrowSpoke, "CDP Spoke and a capless fee receiver only");
        assertTrue(b.noLiquidityFee, "no liquidity fee");
        assertTrue(b.noReinvestment, "no reinvestment controller");
        assertTrue(b.reserveFlags, "standard Spoke settings");
    }

    // TEST-247 verifies: REQ-LENS-012
    function test_TEST_247_checkBackingFeeReceiverWithAddCapFails() public view {
        assertFalse(lens.checkBacking(vt).singleBorrowSpoke, "Aave adds the fee receiver at the maximum add cap");
    }

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-013
    function test_TEST_247_checkBackingDrawCapOnAnySpoke() public {
        _setDrawCap(vtAssetId, aave.cdpSpoke, 1);
        assertFalse(lens.checkBacking(vt).noDrawCap, "a draw cap on the vault-token asset");
    }

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-013
    function test_TEST_247_checkBackingExtraSpokeFails() public {
        _setAddCap(vtAssetId, aave.treasurySpoke, 0);
        _hubConfig(
            abi.encodeWithSignature(
                "addSpoke(address,address,uint256,(uint40,uint40,uint24,bool,bool))",
                aave.hub,
                aave.lendSpoke,
                vtAssetId,
                0,
                0,
                0,
                true,
                false
            )
        );
        assertEq(IAaveV4Hub(aave.hub).getSpokeCount(vtAssetId), 3, "a third Spoke");
        assertFalse(lens.checkBacking(vt).singleBorrowSpoke, "only the CDP Spoke and the fee receiver may be listed");
    }

    // TEST-247 verifies: REQ-LENS-012, Q-309
    function test_TEST_247_checkBackingReserveFlags() public {
        _spokeConfig(
            abi.encodeWithSignature("updateBorrowable(address,uint256,bool)", aave.cdpSpoke, vtReserveId, true)
        );
        assertFalse(lens.checkBacking(vt).reserveFlags, "borrowable vault token");
        _spokeConfig(
            abi.encodeWithSignature("updateBorrowable(address,uint256,bool)", aave.cdpSpoke, vtReserveId, false)
        );
        assertTrue(lens.checkBacking(vt).reserveFlags, "restored");
        _spokeConfig(
            abi.encodeWithSignature(
                "updateReceiveSharesEnabled(address,uint256,bool)", aave.cdpSpoke, vtReserveId, true
            )
        );
        assertFalse(lens.checkBacking(vt).reserveFlags, "receive shares on");
    }

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-013, Q-309
    function test_TEST_247_checkBackingLiquidationFeeOnAnyKey() public {
        IAaveV4Spoke.DynamicReserveConfig memory c = IAaveV4Spoke.DynamicReserveConfig(8000, 10_500, 100);
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeWithSignature("getDynamicReserveConfig(uint256,uint32)", vtReserveId, uint32(0)),
            abi.encode(c)
        );
        assertFalse(lens.checkBacking(vt).reserveFlags, "a liquidation fee on key 0");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-012
    function test_TEST_247_checkBackingHubFees() public {
        _hubConfig(abi.encodeWithSignature("updateLiquidityFee(address,uint256,uint256)", aave.hub, vtAssetId, 100));
        assertFalse(lens.checkBacking(vt).noLiquidityFee, "liquidity fee set");
        IAaveV4Hub.AssetConfig memory cfg = IAaveV4Hub(aave.hub).getAssetConfig(vtAssetId);
        cfg.reinvestmentController = makeAddr("controller");
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetConfig(uint256)", vtAssetId), abi.encode(cfg));
        assertFalse(lens.checkBacking(vt).noReinvestment, "reinvestment controller set");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-012, INV-001
    function test_TEST_247_checkBackingStrandedDonation() public {
        vm.prank(adapter);
        token.addValidProxy(makeAddr("donor"));
        vm.prank(adapter);
        token.mint(makeAddr("donor"), 7e6);
        vm.prank(makeAddr("donor"));
        token.transfer(aave.hub, 7e6);
        BackingView memory b = lens.checkBacking(vt);
        assertEq(b.stranded, 7e6, "Hub balance above Hub liquidity");
        assertTrue(b.hubHoldsSupplied, "still holds the supplied units");
        assertFalse(b.supplyEqualsCredited, "the donated units were minted outside the ledger");
    }

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-026, INV-001, Q-201
    function test_TEST_247_checkBackingWithSeizureAndPending() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        BackingView memory b = lens.checkBacking(vt);
        assertEq(b.unsettledSeizedUnits, seized, "LPVaultSwap holds the seized units");
        assertTrue(b.supplyEqualsCredited, "not yet reconciled: supply = credited");
        _reconcile(aliceProxy, _key(1));
        b = lens.checkBacking(vt);
        assertEq(b.pendingUnits, seized, "reconciled into pending");
        assertEq(b.totalSupply, b.totalCredited + b.pendingUnits, "supply = credited + pending");
        assertTrue(b.supplyEqualsCredited, "flag");
        assertGt(b.pendingAmounts[0] + b.pendingAmounts[1], 0, "pool tokens back the pending units");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_checkBackingUnknownVaultTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 0));
        lens.checkBacking(makeAddr("notAVaultToken"));
    }

    // ─── checkRecordBacking ───

    // TEST-247 verifies: REQ-LENS-014, REQ-LENS-005, INV-002
    function test_TEST_247_checkRecordBackingFullPage() public view {
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, 0, 200);
        assertEq(r.length, 2, "two open records");
        for (uint256 i = 0; i < r.length; ++i) {
            assertTrue(r[i].inCustody, "in custody");
            assertEq(r[i].liveUnits, r[i].credited, "live = credited");
            assertTrue(r[i].backed, "backed");
            assertEq(r[i].integrationId, INTEGRATION, "integration");
            assertEq(r[i].recordId, coll.recordIdOf(INTEGRATION, r[i].positionKey), "record ID");
            assertEq(r[i].blockNumber, block.number, "block");
        }
        assertEq(r[0].credited + r[1].credited, 14_000e6, "both records");
    }

    // TEST-247 verifies: REQ-LENS-014
    function test_TEST_247_checkRecordBackingDonationStillBacked() public {
        vault.addUnits(_key(1), 1e6);
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, 0, 200);
        uint256 i = r[0].positionKey == _key(1) ? 0 : 1;
        assertEq(r[i].liveUnits, UNITS + 1e6, "donated liquidity counted live");
        assertTrue(r[i].backed, "live >= credited");
    }

    // TEST-247 verifies: REQ-LENS-014, INV-002
    function test_TEST_247_checkRecordBackingOutOfCustody() public {
        vm.mockCall(address(lpVault), abi.encodeWithSignature("depositorOf(bytes32)", _key(2)), abi.encode(address(0)));
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, 0, 200);
        uint256 i = r[0].positionKey == _key(2) ? 0 : 1;
        assertFalse(r[i].inCustody, "no depositor of record");
        assertEq(r[i].liveUnits, 0, "unitsOf is not read");
        assertFalse(r[i].backed, "not backed");
        assertTrue(r[1 - i].backed, "the other record is");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-014, INV-002
    function test_TEST_247_checkRecordBackingLiveBelowCredited() public {
        vm.mockCall(address(lpVault), abi.encodeWithSignature("unitsOf(bytes32)", _key(1)), abi.encode(uint128(1)));
        RecordBackingView[] memory r = lens.checkRecordBacking(vt, 0, 200);
        uint256 i = r[0].positionKey == _key(1) ? 0 : 1;
        assertTrue(r[i].inCustody, "in custody");
        assertFalse(r[i].backed, "live liquidity below credited");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-014, REQ-LENS-023, REQ-LENS-024, Q-268
    function test_TEST_247_checkRecordBackingPagingBounds() public {
        assertEq(lens.checkRecordBacking(vt, 0, 0).length, 0, "limit 0");
        assertEq(lens.checkRecordBacking(vt, 1, 200).length, 1, "offset 1: one record");
        assertEq(lens.checkRecordBacking(vt, 0, 1).length, 1, "limit 1");
        assertEq(lens.checkRecordBacking(vt, 2, 200).length, 0, "offset = n");
        assertEq(lens.checkRecordBacking(vt, type(uint256).max, 200).length, 0, "offset max, no overflow");
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.LimitTooHigh.selector, 201));
        lens.checkRecordBacking(vt, 2, 201);
    }

    // TEST-247 verifies: REQ-LENS-014
    function test_TEST_247_checkRecordBackingPagesCoverIndex() public {
        for (uint256 i = 3; i <= 9; ++i) {
            _open(carol, makeAddr(string(abi.encode("carolProxy", i))), i, uint128(10e6 * i));
        }
        uint256 n = coll.getMarketRecordCount(vt);
        assertEq(n, 9, "nine records");
        uint256 seen = 0;
        for (uint256 offset = 0; offset < n; offset += 4) {
            RecordBackingView[] memory page = lens.checkRecordBacking(vt, offset, 4);
            assertEq(page.length, offset + 4 <= n ? 4 : n - offset, "page size");
            seen += page.length;
        }
        assertEq(seen, n, "a full scan is the sequence of pages");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_checkRecordBackingUnknownVaultTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 0));
        lens.checkRecordBacking(makeAddr("x"), 0, 10);
    }

    // ─── getPendingSettlement ───

    // TEST-247 verifies: REQ-LENS-026, REQ-LENS-005
    function test_TEST_247_pendingEmpty() public view {
        PendingView memory p = lens.getPendingSettlement(vt);
        assertEq(p.blockNumber, block.number, "block");
        assertEq(p.vaultToken, vt, "vault token");
        assertEq(p.units, 0, "no units");
        assertEq(p.amounts.length, coll.getPending(vt).amounts.length, "as Collateralization reports them");
        assertEq(p.unsettledSeizedUnits, 0, "none held");
        assertEq(p.settleableUnits, 0, "nothing to settle");
        assertFalse(p.settleable, "not settleable");
        assertEq(p.debtAsset, address(debt), "settlement reserve's asset");
        assertEq(p.firstLossReserve, address(ghoCov), "its First-Loss Reserve");
        assertEq(p.valueDebt, 0, "no value");
    }

    // TEST-247 verifies: REQ-LENS-026, SPEC-LIQ-004, Q-201, Q-236
    function test_TEST_247_pendingAfterReconciledSeizure() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        _reconcile(aliceProxy, _key(1));
        PendingView memory p = lens.getPendingSettlement(vt);
        assertEq(p.units, seized, "pending units");
        assertEq(p.unsettledSeizedUnits, seized, "held by LPVaultSwap");
        assertEq(p.settleableUnits, seized, "min(pending, held)");
        assertTrue(p.settleable, "settleable");
        assertEq(p.valueDebt, seized * 1.8e8 * 1e18 / (1e6 * 1e8), "oracle value in GHO");
        assertEq(p.amounts[0], seized * 800_000 / 1e6, "USDC backing");
    }

    // TEST-247 verifies: REQ-LENS-026
    function test_TEST_247_pendingSettleableIsMinOfPendingAndHeld() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        _reconcile(aliceProxy, _key(1));
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized / 3);
        PendingView memory p = lens.getPendingSettlement(vt);
        assertEq(p.unsettledSeizedUnits, seized - seized / 3, "held fell");
        assertEq(p.settleableUnits, seized - seized / 3, "bounded by what LPVaultSwap holds");
    }

    // TEST-247 verifies: REQ-LENS-026, REQ-LENS-007
    function test_TEST_247_pendingValueInUsdcAndZeroPrice() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        uint256 seized = _seizeAndKeep(aliceProxy, 3000e18);
        _reconcile(aliceProxy, _key(1));
        reg.setSettlementReserve(MARKET_ID, usdcReserveId);
        PendingView memory p = lens.getPendingSettlement(vt);
        assertEq(p.debtAsset, address(usdc), "USDC settlement");
        assertEq(p.firstLossReserve, address(usdcCov), "USDC First-Loss Reserve");
        assertEq(p.valueDebt, seized * 1.8e8 * 1e6 / (1e6 * 0.9999e8), "valued at the larger debt price");
        lpo.setAnswer(true, 0);
        assertEq(lens.getPendingSettlement(vt).valueDebt, 0, "a zero price values 0, never reverts");
    }

    // ─── getCapHeadroom ───

    // TEST-247 verifies: REQ-LENS-018, REQ-LENS-019, REQ-LENS-005
    function test_TEST_247_capHeadroomValues() public view {
        CapView memory c = lens.getCapHeadroom(vt, alice);
        assertEq(c.blockNumber, block.number, "block");
        assertEq(c.hub, aave.hub, "Hub");
        assertEq(c.vaultToken, vt, "market");
        assertEq(c.depositor, alice, "depositor");
        assertEq(c.minPledgeUsd, 10e8, "minimum pledge");
        assertEq(c.marketHeadroomUsd, 1_000_000e8 - 28_000e8, "market cap minus both charges");
        assertEq(c.sliceHeadroomUsd, 100_000e8, "slice untouched");
        assertEq(c.tokens.length, 2, "two tokens");
        assertEq(c.tokens[0], address(usdc), "pool order");
        assertEq(c.depositorHeadroomUsd, 500_000e8 - 20_000e8, "Alice's charge under the Hub");
        assertEq(c.poolShareMaxBps, 10_000, "no pool-share cap");
        assertEq(c.poolShareBps, 1, "14,000e6 of 1e15 units, rounded up");
        assertEq(c.chargePricePerWholeToken, 2e8, "accepted price above the stress floor");
        assertEq(c.vaultTokenAddHeadroom, 5_500_000e6 - 14_000e6, "add cap minus added");
        assertEq(c.drawHeadroom.length, 2, "one per enabled debt reserve");
        assertEq(c.drawHeadroom[0].reserveId, debtReserveId, "GHO");
        assertEq(c.drawHeadroom[0].headroom, BORROW_CAP * 1e18, "GHO draw cap");
        assertEq(c.drawHeadroom[1].headroom, 500_000e6, "USDC draw cap");
    }

    // TEST-247 verifies: REQ-LENS-019
    function test_TEST_247_drawHeadroomAfterBorrow() public {
        _borrow(aliceProxy, 4000e18);
        _borrowUsdc(aliceProxy, 300e6);
        CapView memory c = lens.getCapHeadroom(vt, alice);
        assertEq(c.drawHeadroom[0].headroom, BORROW_CAP * 1e18 - 4000e18, "GHO owed");
        assertEq(c.drawHeadroom[1].headroom, 500_000e6 - 300e6, "USDC owed");
        vm.warp(block.timestamp + 365 days);
        c = lens.getCapHeadroom(vt, alice);
        uint256 owed = IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke);
        assertEq(c.drawHeadroom[0].headroom, BORROW_CAP * 1e18 - owed, "interest uses headroom");
    }

    // TEST-247 verifies: REQ-LENS-019
    function test_TEST_247_unlimitedCapsReportMax() public {
        _setDrawCap(ghoAssetId, aave.cdpSpoke, type(uint40).max);
        _setAddCap(vtAssetId, aave.cdpSpoke, type(uint40).max);
        CapView memory c = lens.getCapHeadroom(vt, alice);
        assertEq(c.drawHeadroom[0].headroom, type(uint256).max, "unlimited draw");
        assertEq(c.vaultTokenAddHeadroom, type(uint256).max, "unlimited add");
    }

    // TEST-247 verifies: REQ-LENS-019
    function test_TEST_247_addHeadroomRoundsUpWhenSharesDiffer() public {
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedAssets(uint256)", vtAssetId), abi.encode(14_000e6 + 5));
        CapView memory c = lens.getCapHeadroom(vt, alice);
        assertEq(c.vaultTokenAddHeadroom, 5_500_000e6 - 14_000e6 - 1, "one more unit counted as added");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-019
    function test_TEST_247_drawHeadroomNeverNegative() public {
        _borrow(aliceProxy, 4000e18);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 1000);
        assertEq(lens.getCapHeadroom(vt, alice).drawHeadroom[0].headroom, 0, "owed above the cap: 0");
    }

    // TEST-247 verifies: REQ-LENS-018, SPEC-CAP-005
    function test_TEST_247_poolShareCases() public {
        store.setPoolShareMax(keccak256(abi.encode(INTEGRATION, pool, bytes32(0))), 1000);
        vault.setDepth(140_000e6, true);
        CapView memory c = lens.getCapHeadroom(vt, alice);
        assertEq(c.poolShareMaxBps, 1000, "cap of the pool");
        assertEq(c.poolShareBps, 1000, "14,000 of 140,000");
        vault.setDepth(140_001e6, true);
        assertEq(lens.getCapHeadroom(vt, alice).poolShareBps, 1000, "rounded up");
        vault.setDepth(0, true);
        assertEq(lens.getCapHeadroom(vt, alice).poolShareBps, type(uint256).max, "no depth");
        vault.setDepth(140_000e6, false);
        assertEq(lens.getCapHeadroom(vt, alice).poolShareBps, type(uint256).max, "depth unavailable");
    }

    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_chargePriceUsesStressFloor() public {
        store.setCaps(MARKET_ID, 1_000_000e8, 100_000e8, 2.5e8);
        assertEq(lens.getCapHeadroom(vt, alice).chargePricePerWholeToken, 2.5e8, "stress floor above accepted");
        lpo.setAccepted(3e8, uint64(block.timestamp));
        assertEq(lens.getCapHeadroom(vt, alice).chargePricePerWholeToken, 3e8, "accepted above the floor");
    }

    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_headroomFloorsAtZero() public {
        store.setCaps(MARKET_ID, 10_000e8, 0, 1e8);
        store.setTokenCap(aave.hub, address(usdc), 0);
        store.setDepositorCap(aave.hub, 1e8);
        CapView memory c = lens.getCapHeadroom(vt, alice);
        assertEq(c.marketHeadroomUsd, 0, "market over cap");
        assertEq(c.sliceHeadroomUsd, 0, "no slice");
        assertEq(c.tokenHeadroomUsd[0], 0, "USDC cap 0");
        assertEq(c.depositorHeadroomUsd, 0, "depositor over cap");
        assertEq(lens.getCapHeadroom(vt, carol).depositorHeadroomUsd, 1e8, "a new depositor");
    }

    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_tokenHeadroomKeyedByHub() public view {
        CapView memory c = lens.getCapHeadroom(vt, alice);
        uint256 used0 = coll.getCounters(vt, alice).tokenUsed[0];
        uint256 used1 = coll.getCounters(vt, alice).tokenUsed[1];
        assertEq(c.tokenHeadroomUsd[0], 300_000e8 - used0, "USDC under the Hub");
        assertEq(c.tokenHeadroomUsd[1], 250_000e8 - used1, "USDT under the Hub");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_capHeadroomUnknownVaultTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 0));
        lens.getCapHeadroom(makeAddr("x"), alice);
    }

    /// @notice Repays the account's GHO debt and withdraws the record in full, which reconciles the seizure into the
    /// market's pending-settlement balance.
    function _reconcile(
        address proxy,
        bytes32 key
    ) internal {
        uint256 owed = _debtOf(proxy, debtReserveId);
        debt.mint(proxy, owed);
        vm.startPrank(proxy);
        debt.approve(aave.cdpSpoke, owed);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, owed, proxy);
        vm.stopPrank();
        _withdraw(proxy, key, coll.previewRelease(INTEGRATION, key));
    }
}
