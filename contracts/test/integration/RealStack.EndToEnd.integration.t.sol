// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {PendingView} from "../../src/types/PendingView.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title RealStackEndToEndIntegrationTest
/// @notice The AaveAdapter and LPVaultSwap together, end to end, with every Avana and Aave V4 contract real
/// (`RealStackFlows`): wallets pledge real Uniswap v3 NFTs into a market listed through the real MarketRegistry and
/// ParameterStore, borrow GHO, both pool tokens fall 7 % on every feed, an account below HF 1 is liquidated through
/// LPVaultSwap (seizure, real unwind through the NonfungiblePositionManager, real `DexPathRoute` swaps into GHO), units
/// kept by an earlier seizure are reconciled into pending and settled into the First-Loss Reserve, and a healthy account
/// deleverages through `repayWithCollateral` (flash loan, unwind, swap, repay). Each Lens preview the wallet or caller
/// acts on is checked against the execution: `previewBorrowMax`, `previewLiquidation`, `previewRepayWithCollateral`
/// and `previewMaxWithdraw`.
/// forge-config: default.isolate = false
contract RealStackEndToEndIntegrationTest is RealStackFlows {
    uint256 internal mA;
    address internal vt;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
    }

    function _deadlineIn() internal view returns (uint256) {
        return block.timestamp + 120;
    }

    // ─── Borrow sizing ───

    /// @notice `previewBorrowMax` is a borrow the real Adapter and RiskModule accept, leaving Aave's HF above 1, and
    /// after it the Lens has (almost) nothing more to offer while a borrow 1 % above it is refused.
    function test_previewBorrowMaxIsWhatTheAdapterLends() public {
        (, address proxy) = _pledgeAs(alice, mA, UNITS);
        uint256 max = lens.previewBorrowMax(alice, mA, ghoReserveId, _deadline());
        // $20,000 at CF 30 %: at most $6,000.
        assertGt(max, 5900e18, "close to the CF limit");
        assertLt(max, 6000e18, "below it (rate and deadline buffer)");
        uint256 snap = vm.snapshotState();
        uint256 nonce = adapterC.borrowNonce(proxy);
        vm.prank(alice);
        (bool ok,) = adapter.call(
            abi.encodeCall(adapterC.borrow, (mA, ghoReserveId, max + max / 100, alice, _deadline(), 0, nonce))
        );
        assertFalse(ok, "1 % above the preview is refused");
        vm.revertToState(snap);
        _borrowAs(alice, mA, ghoReserveId, max);
        assertEq(_debtOf(proxy, ghoReserveId), max, "the previewed amount is lent");
        assertGe(_hf(proxy), 1e18, "Aave HF at or above 1");
        assertLe(lens.previewBorrowMax(alice, mA, ghoReserveId, _deadline()), max / 1e4, "nothing more to offer");
    }

    // ─── The whole flow ───

    /// @notice Pledge, borrow, price move, liquidation, pending settlement and deleverage on one market, with every
    /// preview checked against the execution.
    function test_endToEnd_pledgeBorrowPriceMoveLiquidateSettleDeleverage() public {
        // Bob near the edge (HF 1.05), alice too (her account takes the kept seizure), carol well collateralized.
        (, address bobProxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, ghoReserveId, 5700e18);
        (, address aliceProxy) = _pledgeAs(alice, mA, UNITS);
        _borrowAs(alice, mA, ghoReserveId, 5700e18);
        (bytes32 carolKey, address carolProxy) = _pledgeAs(carol, mA, UNITS);
        (bytes32 carolSmall,) = _pledgeAs(carol, mA, UNITS / 10);
        _borrowAs(carol, mA, ghoReserveId, 2000e18);
        assertGt(_hf(bobProxy), 1e18, "healthy before the move");

        // Both pool tokens fall 7 % on every feed; the market's LPOracle serves it to Aave.
        _movePoolTokens(93_000_000);
        assertLt(_hf(bobProxy), 1e18, "bob below HF 1");
        assertLt(_hf(aliceProxy), 1e18, "alice below HF 1");
        assertGt(_hf(carolProxy), 1.5e18, "carol well above");

        _liquidateAgainstPreview(bobProxy);
        _settleKeptSeizure(aliceProxy);
        _deleverageAgainstPreview(carolKey, carolProxy);
        // Carol borrows again: 9,000 vault tokens left at $1.86 carry $5,022 of borrowing power, HF 2.0 at 2,500 GHO.
        _borrowAs(carol, mA, ghoReserveId, 2500e18);
        _withdrawAgainstSizing(carolProxy, carolKey, carolSmall);
        assertFalse(lock.isLocked(), "Lock free at the end");
    }

    /// @dev `previewLiquidation`'s parameters execute unchanged through LPVaultSwap and its amounts are the executed
    /// ones: D, c, the recovery floor and the Avana fee exactly; the payout differs from the preview's (valued at the
    /// oracle, R = V) by exactly what the real unwind and routes recovered below V.
    function _liquidateAgainstPreview(
        address proxy
    ) internal {
        LiquidationPreview memory p = lens.previewLiquidation(proxy, ghoReserveId, _deadlineIn());
        assertTrue(p.aaveLiquidatable && p.pricesUsable && p.debtPriceFresh, "liquidatable with usable gates");
        assertEq(p.params.proxy, proxy, "ready-to-send params");
        uint256 debtBefore = _debtOf(proxy, ghoReserveId);
        uint256 hfBefore = _hf(proxy);
        uint256 supplyBefore = IERC20(vt).totalSupply();
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.debtRepaid, p.expectedDebtRepaid, "D as previewed");
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "c as previewed");
        assertEq(r.minOut, p.recoveryFloor, "recovery floor as previewed");
        assertEq(r.avanaFee, p.expectedAvanaFee, "Avana fee as previewed");
        assertGe(r.recovered + r.shortfall, r.minOut, "the settlement met its floor");
        assertEq(debtBefore - _debtOf(proxy, ghoReserveId), r.debtRepaid, "the Spoke's debt fell by D");
        assertGt(_hf(proxy), hfBefore, "health factor rose");
        assertEq(supplyBefore - IERC20(vt).totalSupply(), r.unitsSeized, "the seized units were burned");
        assertGt(r.amountsOut[0] + r.amountsOut[1], 0, "the real unwind returned pool tokens");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt), "supply = credited");
        assertEq(
            usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap) + gho.balanceOf(lpVaultSwap),
            0,
            "LPVaultSwap keeps nothing"
        );
    }

    /// @dev A seizure whose units LPVaultSwap kept (a direct `liquidationCall` from its address, as an earlier
    /// non-conforming implementation would have left), reconciled by the next honest liquidation, then
    /// `settlePending` by any caller: burned through the Adapter, unwound and swapped into the settlement asset and
    /// added to its First-Loss Reserve.
    function _settleKeptSeizure(
        address proxy
    ) internal {
        uint256 x = 50e18;
        gho.mint(lpVaultSwap, x);
        vm.startPrank(lpVaultSwap);
        gho.approve(aave.cdpSpoke, x);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(mkt[mA].reserveId, ghoReserveId, proxy, x, false);
        gho.approve(aave.cdpSpoke, 0);
        vm.stopPrank();
        uint256 kept = IERC20(vt).balanceOf(lpVaultSwap);
        assertGt(kept, 0, "LPVaultSwap kept the seized units");
        assertEq(lens.checkBacking(vt).unsettledSeizedUnits, kept, "Lens: unsettled seized units");

        LiquidationPreview memory p = lens.previewLiquidation(proxy, ghoReserveId, _deadlineIn());
        LiquidationResult memory r = _liquidateAs(keeper, p.params);
        assertEq(r.unitsSeized, p.expectedUnitsSeized, "the honest seizure settles on its own units");
        assertEq(coll.getPending(vt).units, kept, "the kept units moved to pending");
        PendingView memory pv = lens.getPendingSettlement(vt);
        assertEq(pv.units, kept, "Lens: pending units");
        assertTrue(pv.settleable, "Lens: settleable");

        uint256 settleReserve = registry.settlementReserve(mA);
        address reserve = firstLossReserveOf[address(_assetOf(settleReserve))];
        assertEq(pv.firstLossReserve, reserve, "Lens: the settlement asset's First-Loss Reserve");
        uint256 fundedBefore = IAvanaFirstLossReserve(reserve).fundedBalance();
        uint256 supplyBefore = IERC20(vt).totalSupply();
        vm.prank(makeAddr("anyone"));
        (uint256 units,, uint256 added) = lvs.settlePending(mA, settleReserve);
        assertEq(units, kept, "every pending unit settled");
        assertEq(supplyBefore - IERC20(vt).totalSupply(), kept, "burned by the Adapter");
        assertEq(coll.getPending(vt).units, 0, "pending cleared");
        assertGt(added, 0, "proceeds recovered through the real unwind and routes");
        assertApproxEqAbs(
            IAvanaFirstLossReserve(reserve).fundedBalance(), fundedBefore + added, 1, "added to the First-Loss Reserve"
        );
        assertTrue(lens.checkBacking(vt).supplyEqualsCredited, "Lens: backed");
    }

    /// @dev `previewRepayWithCollateral` against the real flash-loan deleverage: 2,000 vault tokens ($3,720 at $1.86)
    /// cover carol's 2,000 GHO, so the repaid debt is exactly the preview's (all of it) and the account ends debt-free as
    /// previewed; the wallet's rest is below the preview (which values the release at the oracle) by what the real unwind
    /// and the 0.05 % route pools kept, within 1 %.
    function _deleverageAgainstPreview(
        bytes32 key,
        address proxy
    ) internal {
        uint128 units = UNITS / 5;
        (uint256 pvRepaid, uint256 pvToWallet, uint256 pvHf) =
            lens.previewRepayWithCollateral(carol, mA, key, units, ghoReserveId);
        uint256 debtBefore = _debtOf(proxy, ghoReserveId);
        uint256 walletBefore = gho.balanceOf(carol);
        vm.prank(carol);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(_rwcParams(mA, key, units, ghoReserveId));
        assertEq(debtBefore - _debtOf(proxy, ghoReserveId), repaid, "the Spoke's debt fell by debtRepaid");
        assertEq(gho.balanceOf(carol) - walletBefore, toWallet, "the rest to the wallet");
        assertEq(repaid, pvRepaid, "debt repaid as previewed");
        assertLe(toWallet, pvToWallet, "the preview values the release at the oracle");
        assertApproxEqRel(toWallet, pvToWallet, 0.01e18, "within the routes' fee and impact");
        assertEq(_debtOf(proxy, ghoReserveId), 0, "debt-free");
        assertEq(_hf(proxy), pvHf, "health factor as previewed (no debt)");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt), "supply = credited");
    }

    /// @dev `previewMaxWithdraw` against the real withdrawal: a record it says fits is withdrawn and leaves the
    /// account at or above the target; a record it says does not fit is refused at that target.
    function _withdrawAgainstSizing(
        address proxy,
        bytes32 bigKey,
        bytes32 smallKey
    ) internal {
        uint256 target = 1.5e18;
        RemovalSizing memory s = lens.previewMaxWithdraw(carol, mA, target);
        assertEq(s.proxy, proxy, "carol's account");
        assertEq(s.records.length, 2, "two records");
        bool sawBig;
        bool sawSmall;
        for (uint256 i = 0; i < s.records.length; ++i) {
            bytes32 k = s.records[i].positionKey;
            if (k == bigKey) {
                sawBig = true;
                assertFalse(s.records[i].fits, "the large record does not fit at the target");
                uint256 snap = vm.snapshotState();
                vm.prank(carol);
                (bool ok,) = adapter.call(
                    abi.encodeCall(adapterC.withdraw, (mA, _ref(k), s.records[i].units, _deadline(), target))
                );
                assertFalse(ok, "and is refused");
                vm.revertToState(snap);
            } else if (k == smallKey) {
                sawSmall = true;
                assertTrue(s.records[i].fits, "the small record fits");
                assertLe(s.records[i].units, s.maxUnits, "within the maximum");
                _withdrawVia(carol, mA, k, s.records[i].units);
                assertGe(_hf(proxy), target, "at or above the target after");
                assertEq(IERC20(address(nfpm)).balanceOf(carol), 1, "the NFT is back with the wallet");
            }
        }
        assertTrue(sawBig && sawSmall, "both records sized");
    }
}
