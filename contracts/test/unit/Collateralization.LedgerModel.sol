// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CollateralizationLedgerModel
/// @notice A reference model of the 2.3 backing ledger that the ledger-sequence suites drive next to the real
/// Collateralization: every open record with its credited units, charge basis and current charge (SPEC-BACK-005), each
/// account-market's seizure list (largest-first at insertion, debited from the head, partial changes in place,
/// SPEC-BACK-006) and zero-credit list, the market record index (swap-and-pop on close), the pending balance
/// (SPEC-BACK-011, SPEC-BACK-012, SPEC-BACK-015) and the units each proxy's kept, unreconciled seizures took. `_check`
/// compares every view of the real ledger with the model and asserts INV-001 (supply equals credited plus pending),
/// INV-008 (supplied shares plus unreconciled kept units equal credited), INV-015 (list order) and INV-058 (pending
/// units and amounts) with exact unit accounting.
/// @dev The fixture's RiskModule charges `units × 200` (a $2.00 price on a 6-decimal token, exact), books no slice and
/// no rescue units, so every exposure counter equals the sum of the open records' current charges. Each removal pays
/// `floor(take × rate / 10^6)` raw units of each token, per debited record.
abstract contract CollateralizationLedgerModel is CollateralizationFixture {
    struct ModelRecord {
        bytes32 key;
        address proxy;
        address depositor;
        uint128 credited;
        uint128 originalUnits;
        uint64 originalCharge;
        uint64 currentCharge;
        bool inList;
        bool open;
    }

    uint256 internal constant PRICE_FACTOR = 200;

    mapping(uint256 id => ModelRecord) internal mRec;
    mapping(address proxy => uint256[]) internal mList;
    mapping(address proxy => uint256[]) internal mZero;
    mapping(address proxy => uint256) internal mKept;
    uint256[] internal mMarket;
    uint256 internal mNext = 1;
    uint256 internal mPendingUnits;
    uint256[2] internal mPendingAmounts;
    /// @notice Kept units LPVaultSwap still holds (neither burned nor settled).
    uint256 internal mKeptHeld;
    address[] internal mProxies;

    // ─── Model operations ───

    function _mPledge(
        address proxy,
        address depositor,
        bytes32 key,
        uint128 units
    ) internal returns (uint256 id) {
        id = mNext++;
        uint64 charge = uint64(uint256(units) * PRICE_FACTOR);
        mRec[id] = ModelRecord(key, proxy, depositor, units, units, charge, charge, true, true);
        uint256[] storage list = mList[proxy];
        uint256 pos = list.length;
        for (uint256 i = 0; i < list.length; ++i) {
            if (mRec[list[i]].credited < units) {
                pos = i;
                break;
            }
        }
        list.push(id);
        for (uint256 j = list.length - 1; j > pos; --j) {
            list[j] = list[j - 1];
        }
        list[pos] = id;
        mMarket.push(id);
        if (!_known(proxy)) mProxies.push(proxy);
    }

    /// @notice SPEC-BACK-006 debit of `units` from the head of the proxy's list; returns the per-token principal the
    /// removals pay, summed.
    function _mWalk(
        address proxy,
        uint256 units
    ) internal returns (uint256[2] memory paid) {
        uint256[] storage list = mList[proxy];
        uint256 rem = units;
        uint256 emptied = 0;
        for (uint256 i = 0; i < list.length && rem != 0; ++i) {
            ModelRecord storage r = mRec[list[i]];
            uint256 take = rem < r.credited ? rem : r.credited;
            rem -= take;
            r.credited -= uint128(take);
            _mRebaseDown(r);
            paid[0] += take * 800_000 / 1e6;
            paid[1] += take * 1_250_000 / 1e6;
            if (r.credited == 0) {
                r.inList = false;
                mZero[proxy].push(list[i]);
                ++emptied;
            }
        }
        require(rem == 0, "model: walk above credit");
        for (uint256 j = emptied; j < list.length; ++j) {
            list[j - emptied] = list[j];
        }
        for (uint256 j = 0; j < emptied; ++j) {
            list.pop();
        }
    }

    /// @notice The reconcile of a proxy's kept units into the pending balance (SPEC-BACK-011).
    function _mReconcile(
        address proxy
    ) internal {
        uint256 c = mKept[proxy];
        if (c == 0) return;
        uint256[2] memory paid = _mWalk(proxy, c);
        mPendingUnits += c;
        mPendingAmounts[0] += paid[0];
        mPendingAmounts[1] += paid[1];
        mKept[proxy] = 0;
    }

    /// @notice A partial removal or deleverage release of `units` from record `id`, in place.
    function _mReduce(
        uint256 id,
        uint128 units
    ) internal {
        ModelRecord storage r = mRec[id];
        r.credited -= units;
        _mRebaseDown(r);
    }

    function _mRecredit(
        uint256 id,
        uint128 added
    ) internal {
        ModelRecord storage r = mRec[id];
        uint64 rebased = r.currentCharge + uint64(uint256(added) * PRICE_FACTOR);
        r.credited += added;
        r.originalUnits = r.credited;
        r.originalCharge = rebased;
        r.currentCharge = rebased;
    }

    function _mClose(
        uint256 id
    ) internal {
        ModelRecord storage r = mRec[id];
        _mRemoveFrom(r.inList ? mList[r.proxy] : mZero[r.proxy], id);
        uint256 n = mMarket.length;
        for (uint256 i = 0; i < n; ++i) {
            if (mMarket[i] == id) {
                mMarket[i] = mMarket[n - 1];
                mMarket.pop();
                break;
            }
        }
        r.credited = 0;
        r.currentCharge = 0;
        r.open = false;
    }

    /// @notice The units `previewRelease` must report for `id`: its credit after the proxy's kept units are walked.
    function _mPreview(
        uint256 id
    ) internal view returns (uint256) {
        ModelRecord storage target = mRec[id];
        uint256 rem = mKept[target.proxy];
        uint256[] storage list = mList[target.proxy];
        for (uint256 i = 0; i < list.length; ++i) {
            uint256 cr = mRec[list[i]].credited;
            uint256 take = rem < cr ? rem : cr;
            if (list[i] == id) return cr - take;
            rem -= take;
        }
        return target.credited;
    }

    // ─── Real flows mirrored in the model ───

    function _doPledge(
        address depositor,
        address proxy,
        bytes32 key,
        uint128 units
    ) internal returns (uint256 id) {
        id = _pledge(depositor, proxy, key, units);
        assertEq(id, _mPledge(proxy, depositor, key, units), "record ID");
    }

    function _doPartial(
        uint256 id,
        uint128 units
    ) internal returns (uint256[] memory amounts) {
        ModelRecord storage r = mRec[id];
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(r.proxy, units);
        vm.prank(adapter);
        (, amounts) = coll.releasePartial(r.proxy, vt, r.key, units, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        _mReconcile(r.proxy);
        _mReduce(id, units);
    }

    function _doDeleverage(
        uint256 id,
        uint128 units
    ) internal returns (uint256[] memory amounts, bool closed) {
        ModelRecord storage r = mRec[id];
        address proxy = r.proxy;
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(proxy, units);
        vm.prank(adapter);
        (amounts, closed) = coll.releaseForDeleverage(proxy, vt, r.key, units, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        _mReconcile(proxy);
        _mReduce(id, units);
        if (mRec[id].credited == 0) _mClose(id);
    }

    function _doWithdraw(
        uint256 id
    ) internal {
        ModelRecord storage r = mRec[id];
        uint256 units = coll.previewRelease(INTEGRATION, r.key);
        assertEq(units, _mPreview(id), "previewRelease");
        _withdraw(r.proxy, r.key, units);
        _mReconcile(r.proxy);
        _mClose(id);
    }

    function _doRecredit(
        uint256 id,
        uint128 extra
    ) internal returns (uint128 added) {
        ModelRecord storage r = mRec[id];
        lpVault.addUnits(r.key, extra);
        vm.startPrank(adapter);
        lock.acquire();
        (added,) = coll.recredit(r.depositor, r.proxy, vt, r.key, "", false);
        token.mint(r.proxy, added);
        vm.stopPrank();
        _supply(r.proxy, added);
        vm.prank(adapter);
        lock.release();
        _mReconcile(r.proxy);
        _mRecredit(id, added);
    }

    function _doZeroRelease(
        uint256 id
    ) internal {
        ModelRecord storage r = mRec[id];
        vm.startPrank(adapter);
        lock.acquire();
        coll.releaseZeroCredit(r.depositor, vt, r.key);
        lock.release();
        vm.stopPrank();
        _mReconcile(r.proxy);
        _mClose(id);
    }

    function _doKeep(
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 c) {
        c = _seizeAndKeep(proxy, debtToCover);
        mKept[proxy] += c;
        mKeptHeld += c;
    }

    function _doLiquidate(
        address proxy,
        uint256 debtToCover
    ) internal returns (uint256 seized, uint256[] memory amounts) {
        (seized, amounts) = _liquidate(proxy, debtToCover);
        _mReconcile(proxy);
        uint256[2] memory paid = _mWalk(proxy, seized);
        assertEq(amounts[0], paid[0], "seized USDC principal");
        assertEq(amounts[1], paid[1], "seized USDT principal");
    }

    function _doSettlePending(
        uint256 units
    ) internal returns (uint256[] memory amounts) {
        amounts = _settlePending(units);
        uint256[2] memory out;
        for (uint256 i = 0; i < 2; ++i) {
            out[i] = units == mPendingUnits ? mPendingAmounts[i] : mPendingAmounts[i] * units / mPendingUnits;
            mPendingAmounts[i] -= out[i];
            assertEq(amounts[i], out[i], "pending payout");
        }
        mPendingUnits -= units;
        mKeptHeld -= units;
    }

    function _repayAll(
        address proxy
    ) internal {
        debt.mint(proxy, 1_000_000e18);
        vm.startPrank(proxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, proxy);
        vm.stopPrank();
    }

    // ─── The comparison ───

    function _check(
        string memory step
    ) internal view {
        uint256 total = 0;
        uint256 charges = 0;
        for (uint256 q = 0; q < mProxies.length; ++q) {
            total += _checkAccount(mProxies[q], step);
        }
        for (uint256 i = 0; i < mMarket.length; ++i) {
            charges += mRec[mMarket[i]].currentCharge;
        }
        assertEq(coll.getTotalCredited(vt), total, string.concat(step, ": total credited"));
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, mPendingUnits, string.concat(step, ": pending units"));
        if (mPendingUnits != 0 || p.amounts.length != 0) {
            assertEq(p.amounts[0], mPendingAmounts[0], string.concat(step, ": pending USDC"));
            assertEq(p.amounts[1], mPendingAmounts[1], string.concat(step, ": pending USDT"));
            assertGe(usdc.balanceOf(address(coll)), mPendingAmounts[0], string.concat(step, ": USDC held"));
            assertGe(usdt.balanceOf(address(coll)), mPendingAmounts[1], string.concat(step, ": USDT held"));
        }
        // INV-001 with equality: every burn of this sequence is settled in its own call.
        assertEq(token.totalSupply(), total + mPendingUnits, string.concat(step, ": INV-001"));
        assertEq(token.balanceOf(lpVaultSwap), mKeptHeld, string.concat(step, ": kept units held"));
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.regularUsed, charges, string.concat(step, ": regular bucket"));
        assertEq(k.sliceUsed, 0, string.concat(step, ": slice bucket"));
        assertEq(k.tokenUsed[0], charges, string.concat(step, ": USDC counter"));
        assertEq(k.tokenUsed[1], charges, string.concat(step, ": USDT counter"));
        assertEq(k.depositorUsed, _depositorCharges(alice), string.concat(step, ": alice counter"));
        assertEq(coll.getCounters(vt, bob).depositorUsed, _depositorCharges(bob), string.concat(step, ": bob counter"));
        assertEq(k.poolUnits, total, string.concat(step, ": pool units"));
        (uint256[] memory ids,) = coll.getMarketRecords(vt, 0, 64);
        assertEq(ids.length, mMarket.length, string.concat(step, ": market record count"));
        assertEq(coll.getMarketRecordCount(vt), mMarket.length, string.concat(step, ": market count view"));
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(ids[i], mMarket[i], string.concat(step, ": market index order"));
        }
        assertEq(coll.nextRecordId(), mNext, string.concat(step, ": next record ID"));
    }

    function _checkAccount(
        address proxy,
        string memory step
    ) internal view returns (uint256 credited) {
        uint256[] storage list = mList[proxy];
        uint256[] storage zero = mZero[proxy];
        (uint256[] memory ids, BackingRecord[] memory rs) = coll.getAccountRecords(proxy, vt, 0, 16);
        assertEq(ids.length, list.length + zero.length, string.concat(step, ": open records"));
        assertEq(coll.getOpenRecordCount(proxy, vt), ids.length, string.concat(step, ": open record count"));
        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = i < list.length ? list[i] : zero[i - list.length];
            ModelRecord storage m = mRec[id];
            assertEq(ids[i], id, string.concat(step, ": INV-015 list order"));
            assertEq(rs[i].credited, m.credited, string.concat(step, ": credited"));
            assertEq(rs[i].inList, i < list.length, string.concat(step, ": inList"));
            assertEq(rs[i].originalUnits, m.originalUnits, string.concat(step, ": charge basis units"));
            assertEq(rs[i].originalUsdCharge, m.originalCharge, string.concat(step, ": charge basis"));
            assertEq(rs[i].currentUsdCharge, m.currentCharge, string.concat(step, ": current charge"));
            assertEq(rs[i].positionKey, m.key, string.concat(step, ": position"));
            assertEq(rs[i].depositor, m.depositor, string.concat(step, ": depositor"));
            assertEq(rs[i].proxy, proxy, string.concat(step, ": proxy"));
            assertEq(coll.recordIdOf(INTEGRATION, m.key), id, string.concat(step, ": record key"));
            (,,, uint128 live,) = lpVault.positions(m.key);
            assertGe(live, m.credited, string.concat(step, ": live units cover credit"));
            if (i < list.length) assertGt(m.credited, 0, string.concat(step, ": listed record has credit"));
            credited += m.credited;
        }
        assertEq(coll.getAccountCredited(proxy, vt), credited, string.concat(step, ": account credited"));
        // INV-008: supplied shares plus the units kept seizures took equal the credited units.
        assertEq(_shares(proxy) + mKept[proxy], credited, string.concat(step, ": INV-008"));
    }

    function _depositorCharges(
        address depositor
    ) internal view returns (uint256 sum) {
        for (uint256 i = 0; i < mMarket.length; ++i) {
            if (mRec[mMarket[i]].depositor == depositor) sum += mRec[mMarket[i]].currentCharge;
        }
    }

    function _mRebaseDown(
        ModelRecord storage r
    ) private {
        uint256 remaining = Math.mulDiv(r.originalCharge, r.credited, r.originalUnits, Math.Rounding.Ceil);
        if (remaining < r.currentCharge) r.currentCharge = uint64(remaining);
    }

    function _mRemoveFrom(
        uint256[] storage list,
        uint256 id
    ) private {
        uint256 n = list.length;
        uint256 pos = n;
        for (uint256 i = 0; i < n; ++i) {
            if (list[i] == id) {
                pos = i;
                break;
            }
        }
        require(pos < n, "model: record not listed");
        for (uint256 j = pos + 1; j < n; ++j) {
            list[j - 1] = list[j];
        }
        list.pop();
    }

    function _known(
        address proxy
    ) private view returns (bool) {
        for (uint256 i = 0; i < mProxies.length; ++i) {
            if (mProxies[i] == proxy) return true;
        }
        return false;
    }
}
