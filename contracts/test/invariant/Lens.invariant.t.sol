// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AccountView} from "../../src/lens/lens/types/AccountView.sol";
import {BackingView} from "../../src/lens/lens/types/BackingView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

/// @title LensInvariantTest
/// @notice Random pledges, borrows of both debt reserves, price moves, donations, time and liquidations sized by the
/// Lens on the real Aave V4 Spoke and Collateralization. After every step: the Lens answers every view for every
/// account and state without reverting, its record reconciliation equals Collateralization's, its backing check holds
/// for honest flows, and every liquidation it sized executed exactly as previewed.
/// forge-config: default.isolate = false
contract LensInvariantTest is StdInvariant, LensFixture {
    address[2] internal wallets;
    address[2] internal proxies;
    uint256[2] internal nextKey;
    uint256 internal liquidations;
    uint256 internal mismatches;
    uint256 internal liquidationFailures;

    function setUp() public {
        _deployLens();
        (wallets[0], wallets[1]) = (alice, bob);
        (proxies[0], proxies[1]) = (aliceProxy, bobProxy);
        (nextKey[0], nextKey[1]) = (1, 101);
        _open(alice, aliceProxy, nextKey[0]++, 20_000e6);
        _open(bob, bobProxy, nextKey[1]++, 5000e6);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = this.actPledge.selector;
        selectors[1] = this.actBorrow.selector;
        selectors[2] = this.actPrice.selector;
        selectors[3] = this.actWarp.selector;
        selectors[4] = this.actDonate.selector;
        selectors[5] = this.actLiquidate.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
        targetContract(address(this));
    }

    // ─── actions ───

    function actPledge(
        uint256 who,
        uint256 units
    ) external {
        uint256 i = who % 2;
        if (coll.getOpenRecordCount(proxies[i], vt) >= 16) return;
        _open(wallets[i], proxies[i], nextKey[i]++, uint128(bound(units, 10e6, 30_000e6)));
    }

    function actBorrow(
        uint256 who,
        uint256 bps,
        bool usdcDebt
    ) external {
        uint256 i = who % 2;
        uint256 amount =
            lens.previewBorrowMax(wallets[i], MARKET_ID, usdcDebt ? usdcReserveId : debtReserveId, block.timestamp);
        amount = amount * bound(bps, 1, 10_000) / 10_000;
        if (amount == 0) return;
        if (usdcDebt) _borrowUsdc(proxies[i], amount);
        else _borrow(proxies[i], amount);
    }

    function actPrice(
        uint256 price
    ) external {
        _setVtPrice(int256(bound(price, 0.2e8, 2.5e8)));
    }

    function actWarp(
        uint256 dt
    ) external {
        vm.warp(block.timestamp + bound(dt, 1, 10 days));
        vm.roll(block.number + 1);
        lpo.setTokenAt(0, uint64(block.timestamp - 60), 0);
        lpo.setTokenAt(1, uint64(block.timestamp - 60), 0);
        usdcOracle.set(0.9999e8, PriceState.Live, 0.9999e8, uint64(block.timestamp - 60));
    }

    function actDonate(
        uint256 who,
        uint256 units
    ) external {
        uint256 i = who % 2;
        (, BackingRecordLike memory r) = _firstRecord(proxies[i]);
        if (r.positionKey == bytes32(0)) return;
        vault.addUnits(r.positionKey, uint128(bound(units, 1, 1000e6)));
    }

    function actLiquidate(
        uint256 who,
        bool usdcDebt
    ) external {
        uint256 i = who % 2;
        uint256 reserveId = usdcDebt ? usdcReserveId : debtReserveId;
        LiquidationPreview memory p = lens.previewLiquidation(proxies[i], reserveId, block.timestamp);
        if (p.expectedDebtRepaid == 0) return;
        address asset = usdcDebt ? address(usdc) : address(debt);
        CollPoolToken(asset).mint(lpVaultSwap, p.params.debtToCover);
        uint256 debtBefore = CollPoolToken(asset).balanceOf(lpVaultSwap);
        uint256 unitsBefore = token.balanceOf(lpVaultSwap);
        vm.startPrank(lpVaultSwap);
        CollPoolToken(asset).approve(aave.cdpSpoke, p.params.debtToCover);
        try IAaveV4Spoke(aave.cdpSpoke)
            .liquidationCall(vtReserveId, reserveId, proxies[i], p.params.debtToCover, false) {
            ++liquidations;
            if (debtBefore - CollPoolToken(asset).balanceOf(lpVaultSwap) != p.expectedDebtRepaid) ++mismatches;
            if (token.balanceOf(lpVaultSwap) - unitsBefore != p.expectedUnitsSeized) ++mismatches;
        } catch {
            ++liquidationFailures;
        }
        vm.stopPrank();
    }

    // ─── invariants ───

    // TEST-069 verifies: REQ-LENS-017, REQ-LENS-028, REQ-LENS-029
    function invariant_TEST_069_liquidationsExecuteAsPreviewed() public view {
        assertEq(mismatches, 0, "every executed liquidation repaid and seized exactly the preview");
        assertEq(liquidationFailures, 0, "ready-to-send params never revert in the block they were read");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-009, REQ-LENS-011, REQ-LENS-016, SPEC-BACK-011
    function invariant_TEST_247_viewsAnswerAndReconcileAgrees() public view {
        for (uint256 i = 0; i < 2; ++i) {
            AccountView memory a = lens.getAccount(wallets[i], MARKET_ID);
            assertEq(a.healthFactor, _hf(proxies[i]), "Aave's health factor");
            RecordView[] memory r = lens.getRecords(proxies[i], 0, 16);
            for (uint256 k = 0; k < r.length; ++k) {
                assertEq(r[k].creditedAfterReconcile, coll.previewRelease(INTEGRATION, r[k].positionKey), "reconcile");
                assertGe(r[k].liveUnits, r[k].credited, "live covers credit");
            }
            lens.previewLiquidation(proxies[i], debtReserveId, block.timestamp);
            lens.previewLiquidation(proxies[i], usdcReserveId, block.timestamp);
            lens.previewBorrowRecommended(wallets[i], MARKET_ID, debtReserveId, block.timestamp + 600);
            lens.quoteRepayAll(wallets[i], MARKET_ID, usdcReserveId, block.timestamp + 600);
        }
        lens.getPriceState(vt);
        lens.getCapHeadroom(vt, alice);
        lens.getTailCoverage(aave.hub, address(debt));
        lens.getPendingSettlement(vt);
    }

    // TEST-247 verifies: REQ-LENS-012, INV-001
    function invariant_TEST_247_backingHolds() public view {
        BackingView memory b = lens.checkBacking(vt);
        assertTrue(b.supplyEqualsCredited, "supply = credited + pending");
        assertTrue(b.hubHoldsSupplied, "the Hub holds what it records");
        assertEq(b.unsettledSeizedUnits, token.balanceOf(lpVaultSwap), "seized units held");
    }

    // ─── helpers ───

    struct BackingRecordLike {
        bytes32 positionKey;
    }

    function _firstRecord(
        address proxy
    ) internal view returns (uint256 n, BackingRecordLike memory r) {
        RecordView[] memory list = lens.getRecords(proxy, 0, 1);
        n = list.length;
        if (n > 0) r.positionKey = list[0].positionKey;
    }
}
