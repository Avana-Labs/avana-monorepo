// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollateralizationLedgerModel} from "./Collateralization.LedgerModel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title CollateralizationMaxRecordsUnitTest
/// @notice An account-market at the 16-record bound on the real local Aave V4, checked against the ledger model: sixteen
/// records of sixteen sizes inserted largest-first, one liquidation that debits all sixteen in list order (one
/// `RecordDebited` each, one `SeizureSettled` with `recordsDebited = 16`), the bound counting records at 0 credit, a
/// zero-credit release from the middle of the zero-credit list, and a pledge admitted again below the bound.
/// forge-config: default.isolate = false
contract CollateralizationMaxRecordsUnitTest is CollateralizationLedgerModel {
    bytes32 internal constant RECORD_DEBITED =
        keccak256("RecordDebited(uint256,bytes32,address,address,uint256,uint256,uint256[],uint256)");
    bytes32 internal constant SEIZURE_SETTLED = keccak256("SeizureSettled(address,address,uint256,uint256[],uint256)");

    function setUp() public {
        _deployCollateralization();
    }

    // TEST-269 verifies: REQ-VAULT-025, REQ-VAULT-054, REQ-VAULT-062, REQ-VAULT-108, REQ-COLL-025, SPEC-BACK-006, SPEC-BACK-016, INV-015, INV-096, Q-294
    // Sources: 5.1 TEST-269, 2.3 REQ-VAULT-025 (records at 0 credited units included), SPEC-BACK-016
    /// @notice Sixteen records of 100e6 x (1..16, permuted) units sit largest-first; a liquidation of the whole debt
    /// debits all sixteen from the head with one event each, leaving sixteen zero-credit records in walk order; the bound
    /// still refuses a seventeenth pledge; releasing the ninth zero-credit record keeps the others' order; the next
    /// pledge is admitted and heads the seizure list.
    function test_TEST_269_sixteenRecordsSeizedInListOrder() public {
        uint256[] memory ids = new uint256[](16);
        for (uint256 i = 0; i < 16; ++i) {
            uint128 units = uint128(100_000_000 * (1 + (i * 7) % 16));
            ids[i] = _doPledge(alice, aliceProxy, _key(100 + i), units);
        }
        _check("sixteen pledges");
        for (uint256 i = 0; i < 16; ++i) {
            assertEq(mRec[mList[aliceProxy][i]].credited, 100_000_000 * (16 - i), "largest first");
        }

        _borrow(aliceProxy, 20_000e18);
        vtPrice.set(1e8);
        uint256[] memory order = _copyList(aliceProxy);
        vm.recordLogs();
        (uint256 seized,) = _doLiquidate(aliceProxy, 20_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(seized, 13_600_000_000, "the whole credit seized");
        _check("sixteen records debited");
        assertEq(mZero[aliceProxy].length, 16, "every record at 0 credit");

        uint256 debited = 0;
        for (uint256 l = 0; l < logs.length; ++l) {
            if (logs[l].emitter != address(coll)) continue;
            if (logs[l].topics[0] == RECORD_DEBITED) {
                assertEq(uint256(logs[l].topics[1]), order[debited], "debited in list order");
                (, uint256 unitsDebited, uint256 creditedAfter,,) =
                    abi.decode(logs[l].data, (address, uint256, uint256, uint256[], uint256));
                assertEq(unitsDebited, 100_000_000 * (16 - debited), "whole record");
                assertEq(creditedAfter, 0);
                ++debited;
            } else if (logs[l].topics[0] == SEIZURE_SETTLED) {
                (uint256 units,, uint256 recordsDebited) = abi.decode(logs[l].data, (uint256, uint256[], uint256));
                assertEq(units, seized);
                assertEq(recordsDebited, 16, "recordsDebited");
            }
        }
        assertEq(debited, 16, "one RecordDebited per record");

        lpVault.mintPosition(_key(500), alice, MARKET_ID, 1_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.TooManyRecords.selector, 16));
        coll.pledge(alice, aliceProxy, vt, _key(500), false);
        lock.release();
        vm.stopPrank();

        uint256 middle = mZero[aliceProxy][8];
        _doZeroRelease(middle);
        _check("middle zero-credit record released");
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 15);

        uint256 fresh = _doPledge(alice, aliceProxy, _key(501), 1_000_000);
        _check("pledge admitted below the bound");
        (uint256[] memory open,) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(open[0], fresh, "the only credited record heads the list");
        assertEq(open.length, 16);
    }

    // TEST-010 verifies: REQ-VAULT-128, REQ-COLL-018
    // Sources: 2.3 REQ-VAULT-128 (seizure list in order, then the zero-credit records)
    /// @notice Account paging across the boundary between the seizure list and the zero-credit list returns each
    /// record once, in order, for every page size and offset; an offset at or past the end returns nothing; a limit of
    /// 0 returns nothing.
    function test_TEST_010_accountPagingAcrossBothLists() public {
        for (uint256 i = 0; i < 6; ++i) {
            _doPledge(alice, aliceProxy, _key(100 + i), uint128(1_000_000_000 * (6 - i)));
        }
        _borrow(aliceProxy, 30_000e18);
        vtPrice.set(1.2e8);
        _doLiquidate(aliceProxy, 14_000e18);
        assertGt(mZero[aliceProxy].length, 0, "some records at 0");
        assertGt(mList[aliceProxy].length, 0, "some records credited");
        uint256[] memory all = new uint256[](6);
        uint256 n = 0;
        for (uint256 i = 0; i < mList[aliceProxy].length; ++i) {
            all[n++] = mList[aliceProxy][i];
        }
        for (uint256 i = 0; i < mZero[aliceProxy].length; ++i) {
            all[n++] = mZero[aliceProxy][i];
        }
        for (uint256 limit = 0; limit <= 7; ++limit) {
            for (uint256 offset = 0; offset <= 7; ++offset) {
                (uint256[] memory page, BackingRecord[] memory rs) =
                    coll.getAccountRecords(aliceProxy, vt, offset, limit);
                uint256 expected = offset >= 6 ? 0 : (6 - offset < limit ? 6 - offset : limit);
                assertEq(page.length, expected, "page length");
                assertEq(rs.length, expected);
                for (uint256 k = 0; k < page.length; ++k) {
                    assertEq(page[k], all[offset + k], "page order");
                    assertEq(rs[k].positionKey, mRec[all[offset + k]].key, "page record");
                }
            }
        }
        (uint256[] memory market,) = coll.getMarketRecords(vt, 5, 10);
        assertEq(market.length, 1, "market paging past the middle");
        (market,) = coll.getMarketRecords(vt, 6, 10);
        assertEq(market.length, 0, "market paging at the end");
        (market,) = coll.getMarketRecords(vt, 0, 0);
        assertEq(market.length, 0, "limit 0");
    }

    function _copyList(
        address proxy
    ) internal view returns (uint256[] memory out) {
        uint256[] storage list = mList[proxy];
        out = new uint256[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            out[i] = list[i];
        }
    }
}

/// @title CollateralizationMaxRecordsEightTokensUnitTest
/// @notice The worst case of SPEC-BACK-016 in the widest market of REQ-COLL-028: sixteen records in an eight-token
/// market, a kept seizure reconciled into eight pending amounts, then one settlement that debits every record and pays
/// eight per-record sums; the per-token minimum is checked on the summed amounts at its exact boundary, the first
/// failing index is reported, and minimums arrays of seven and nine entries are refused.
/// forge-config: default.isolate = false
contract CollateralizationMaxRecordsEightTokensUnitTest is CollateralizationFixture {
    uint256 internal constant N = 8;
    uint256 internal constant UNITS = 500_000_000;

    function setUp() public {
        extraTokenCount = N - 2;
        _deployCollateralization();
    }

    // TEST-208 verifies: REQ-COLL-028, REQ-AMM-CORE-007, REQ-VAULT-060, REQ-VAULT-062, REQ-VAULT-108, REQ-VAULT-135, SPEC-BACK-015, SPEC-BACK-016
    // Sources: 2.3 REQ-COLL-028 (eight tokens), SPEC-BACK-016 (sixteen records), REQ-AMM-CORE-007 (summed minimums)
    /// @notice Sixteen 500e6-unit records in an eight-token market: a kept seizure of `c` units books eight pending
    /// amounts of `floor(c x rate)`; the full settlement pays each token the sum of its per-record removals; a minimum
    /// one unit above the last token's sum reverts `BelowMinimum(7, sum, sum + 1)`; a minimum one unit above the first
    /// token's sum is the index reported when two fail; minimums of length 7 and 9 revert `LengthMismatch`; minimums
    /// equal to every sum pass.
    function test_TEST_208_sixteenRecordsEightTokensSummedMinimums() public {
        for (uint256 i = 0; i < 16; ++i) {
            _pledge(alice, aliceProxy, bytes32(100 + i), uint128(UNITS));
        }
        _borrow(aliceProxy, 6000e18);
        vtPrice.set(0.9e8);
        uint256 c = _seizeAndKeep(aliceProxy, 300e18);
        assertGt(c, 0);
        assertLt(c, UNITS, "the kept seizure stays in the head record");

        vtPrice.set(0.7e8);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        uint256 seized = _seizeAndKeep(aliceProxy, 10_000e18);
        assertEq(seized, 16 * UNITS - c, "the rest of the credit");
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);

        uint256[] memory sums = new uint256[](N);
        for (uint256 i = 0; i < N; ++i) {
            uint256 rate = _rate(i);
            sums[i] = (UNITS - c) * rate / 1e6 + 15 * (UNITS * rate / 1e6);
        }
        vm.startPrank(lpVaultSwap);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, N, 7));
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](7));
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, N, 9));
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](9));
        uint256[] memory mins = _copy(sums);
        mins[7] = sums[7] + 1;
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.BelowMinimum.selector, 7, sums[7], sums[7] + 1));
        coll.settleSeizure(aliceProxy, vt, seized, mins);
        mins[0] = sums[0] + 1;
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.BelowMinimum.selector, 0, sums[0], sums[0] + 1));
        coll.settleSeizure(aliceProxy, vt, seized, mins);
        mins = _copy(sums);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.SeizureSettled(aliceProxy, vt, seized, sums, 16);
        uint256[] memory amounts = coll.settleSeizure(aliceProxy, vt, seized, mins);
        lock.release();
        vm.stopPrank();

        for (uint256 i = 0; i < N; ++i) {
            assertEq(amounts[i], sums[i], "summed per-record removals");
            assertEq(_balance(i, lpVaultSwap), sums[i], "paid to LPVaultSwap");
        }
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(p.amounts[i], c * _rate(i) / 1e6, "pending amount per token");
            assertEq(_balance(i, address(coll)), p.amounts[i], "held by Collateralization");
        }
        assertEq(coll.getAccountCredited(aliceProxy, vt), 0);
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 16);
        assertEq(_gap(), 0);
    }

    // TEST-208 verifies: REQ-COLL-028, REQ-VAULT-088, REQ-VAULT-139, SPEC-BACK-012
    // Sources: 2.3 REQ-COLL-028, SPEC-BACK-012 (pro-rata rounded down, the last call pays the rest)
    /// @notice In the eight-token market a partial removal returns eight measured amounts and refuses two-entry
    /// minimums; a pending balance settled in three calls pays each token pro-rata rounded down and the exact
    /// remainder last, so the eight balances held reach exactly 0.
    function test_TEST_208_eightTokenPartialAndPendingSplit() public {
        _pledge(alice, aliceProxy, bytes32(uint256(1)), 5_000_000_000);
        _pledge(alice, aliceProxy, bytes32(uint256(2)), 4_000_000_000);
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.prank(adapter);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, N, 2));
        coll.releasePartial(aliceProxy, vt, bytes32(uint256(2)), 1_000_000_000, new uint256[](2));
        vm.prank(adapter);
        (, uint256[] memory amounts) =
            coll.releasePartial(aliceProxy, vt, bytes32(uint256(2)), 1_000_000_000, new uint256[](N));
        vm.prank(adapter);
        lock.release();
        assertEq(amounts.length, N);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(amounts[i], 1_000_000_000 * _rate(i) / 1e6, "measured at the depositor");
            assertEq(_balance(i, alice), amounts[i]);
        }

        _borrow(aliceProxy, 10_000e18);
        vtPrice.set(1.3e8);
        uint256 c = _seizeAndKeep(aliceProxy, 1777e18);
        _repayAndWithdraw(c);
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c);
        uint256[] memory paid = new uint256[](N);
        uint256 first = c / 3;
        uint256 second = c / 7;
        uint256[] memory out = _settlePending(first);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(out[i], p.amounts[i] * first / c, "first call: pro-rata, rounded down");
            paid[i] += out[i];
        }
        Pending memory q = coll.getPending(vt);
        out = _settlePending(second);
        for (uint256 i = 0; i < N; ++i) {
            assertEq(out[i], q.amounts[i] * second / q.units, "second call: pro-rata of what is left");
            paid[i] += out[i];
        }
        out = _settlePending(c - first - second);
        for (uint256 i = 0; i < N; ++i) {
            paid[i] += out[i];
            assertEq(paid[i], p.amounts[i], "the three calls pay exactly the balance");
            assertEq(_balance(i, address(coll)), 0, "nothing stranded");
        }
        assertEq(coll.getPending(vt).units, 0);
        assertEq(_gap(), 0);
    }

    function _repayAndWithdraw(
        uint256 c
    ) internal {
        vtPrice.set(2e8);
        debt.mint(aliceProxy, 1_000_000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
        _withdraw(aliceProxy, bytes32(uint256(1)), 5_000_000_000 - c);
    }

    function _rate(
        uint256 i
    ) internal pure returns (uint256) {
        return i == 0 ? 800_000 : i == 1 ? 1_250_000 : 1_000_000;
    }

    function _balance(
        uint256 i,
        address who
    ) internal view returns (uint256) {
        if (i == 0) return usdc.balanceOf(who);
        if (i == 1) return usdt.balanceOf(who);
        return IERC20(address(extraTokens[i - 2])).balanceOf(who);
    }

    function _copy(
        uint256[] memory a
    ) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; ++i) {
            b[i] = a[i];
        }
    }
}
