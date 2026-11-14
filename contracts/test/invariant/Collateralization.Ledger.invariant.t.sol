// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollWorld, CollateralizationHandler} from "./handlers/CollateralizationHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title CollateralizationLedgerInvariantTest
/// @notice Ledger-shape invariants on the real Collateralization and the real local Aave V4 under every ledger write
/// the handler makes: pledges, withdrawals, partial removals, deleverage releases, re-credits, zero-credit releases,
/// borrows, repays, price moves, honest liquidations, kept seizures and pending settlements by two borrowers. After
/// every call: the exposure counters equal the sum of the open records' current charges (INV-027, TEST-097); each
/// account-market's records are its credited records in the seizure list followed by its zero-credit records, at most
/// 16, with the account credit their sum (INV-015, INV-096); every open record's position is in the LPVault's custody
/// under its depositor with live units covering its credit (INV-006, TEST-084); the market index lists every open
/// record once; the pool counter equals the market credit; the pending pool tokens are held by Collateralization; and
/// supply equals credited plus pending, with each proxy's supply plus its unreconciled kept units equal to its credit
/// (INV-001, INV-008).
/// forge-config: default.isolate = false
contract CollateralizationLedgerInvariantTest is CollateralizationFixture, HandlerReach {
    CollateralizationHandler internal handler;

    function setUp() public {
        _deployCollateralization();
        CollWorld memory world = CollWorld({
            coll: coll,
            lock: lock,
            token: token,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            debt: debt,
            vtPrice: vtPrice,
            adapter: adapter,
            lpVaultSwap: lpVaultSwap,
            vtReserveId: vtReserveId,
            debtReserveId: debtReserveId,
            marketId: MARKET_ID
        });
        handler = new CollateralizationHandler(world, [aliceProxy, bobProxy], [alice, bob]);
        handler.seedAccounts();
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    // TEST-097 verifies: INV-027, REQ-VAULT-034, REQ-VAULT-036, REQ-VAULT-038, REQ-COLL-026, SPEC-BACK-004, SPEC-BACK-005, SPEC-BACK-013
    // Sources: 5.1 TEST-097 (aggregate counters equal the sum of remaining record charges)
    function invariant_TEST_097_countersEqualOpenRecordCharges() public view {
        (, BackingRecord[] memory rs) = coll.getMarketRecords(vt, 0, 64);
        uint256 sum = 0;
        uint256 aliceSum = 0;
        uint256 bobSum = 0;
        for (uint256 i = 0; i < rs.length; ++i) {
            sum += rs[i].currentUsdCharge;
            if (rs[i].depositor == alice) aliceSum += rs[i].currentUsdCharge;
            if (rs[i].depositor == bob) bobSum += rs[i].currentUsdCharge;
            assertLe(
                rs[i].currentUsdCharge,
                _ceilDiv(uint256(rs[i].originalUsdCharge) * rs[i].credited, rs[i].originalUnits),
                "a record's charge never exceeds its basis share"
            );
        }
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(uint256(k.regularUsed) + k.sliceUsed, sum, "market buckets");
        assertEq(k.tokenUsed[0], sum, "USDC counter");
        assertEq(k.tokenUsed[1], sum, "USDT counter");
        assertEq(k.depositorUsed, aliceSum, "alice's counter");
        assertEq(coll.getCounters(vt, bob).depositorUsed, bobSum, "bob's counter");
    }

    // TEST-102 verifies: INV-015, INV-096, REQ-VAULT-025, REQ-VAULT-074, REQ-VAULT-128, REQ-VAULT-129, SPEC-BACK-006
    // Sources: 5.1 TEST-102 (record lists follow SPEC-BACK-006), 2.3 REQ-VAULT-128
    function invariant_TEST_102_accountListsPartitionByCredit() public view {
        uint256 open = 0;
        for (uint256 p = 0; p < 2; ++p) {
            address proxy = handler.proxyAt(p);
            (uint256[] memory ids, BackingRecord[] memory rs) = coll.getAccountRecords(proxy, vt, 0, 32);
            assertLe(ids.length, 16, "record bound");
            assertEq(coll.getOpenRecordCount(proxy, vt), ids.length);
            bool inZero = false;
            uint256 credited = 0;
            for (uint256 i = 0; i < ids.length; ++i) {
                assertEq(rs[i].proxy, proxy, "record of this account");
                if (rs[i].credited == 0) inZero = true;
                assertEq(rs[i].inList, !inZero, "credited records first, then the zero-credit list");
                if (inZero) assertEq(rs[i].credited, 0, "no credited record after a zero-credit one");
                assertEq(coll.recordIdOf(INTEGRATION, rs[i].positionKey), ids[i], "record key");
                credited += rs[i].credited;
            }
            assertEq(coll.getAccountCredited(proxy, vt), credited, "account credit is the sum");
            open += ids.length;
        }
        assertEq(coll.getMarketRecordCount(vt), open, "market index lists every open record");
    }

    // TEST-084 verifies: INV-002, INV-006, REQ-VAULT-032, SPEC-BACK-010
    // Sources: 5.1 TEST-084 (custody), 2.3 SPEC-BACK-010 (live units cover credit)
    function invariant_TEST_084_openRecordsInCustody() public view {
        (uint256[] memory ids, BackingRecord[] memory rs) = coll.getMarketRecords(vt, 0, 64);
        for (uint256 i = 0; i < ids.length; ++i) {
            bytes32 key = rs[i].positionKey;
            assertEq(lpVault.ownerOf(key), address(lpVault), "position in custody");
            assertEq(lpVault.depositorOf(key), rs[i].depositor, "depositor of record");
            (,,, uint128 live,) = lpVault.positions(key);
            assertGe(live, rs[i].credited, "live units cover credit");
        }
    }

    // TEST-153 verifies: INV-001, INV-008, INV-058, REQ-VAULT-137, REQ-COLL-026
    // Sources: 5.1 TEST-153 (backing with the ledger actions), 2.3 REQ-COLL-026 (pool counter)
    function invariant_TEST_153_backingWithLedgerActions() public view {
        uint256 total = coll.getTotalCredited(vt);
        Pending memory p = coll.getPending(vt);
        assertEq(token.totalSupply(), total + p.units, "INV-001");
        assertEq(coll.getCounters(vt, alice).poolUnits, total, "one market: pool units are its credit");
        if (p.amounts.length != 0) {
            assertGe(usdc.balanceOf(address(coll)), p.amounts[0], "pending USDC held");
            assertGe(usdt.balanceOf(address(coll)), p.amounts[1], "pending USDT held");
        }
        uint256 unreconciled = 0;
        for (uint256 i = 0; i < 2; ++i) {
            address proxy = handler.proxyAt(i);
            assertEq(_shares(proxy) + handler.unreconciled(proxy), coll.getAccountCredited(proxy, vt), "INV-008");
            unreconciled += handler.unreconciled(proxy);
        }
        assertEq(p.units + unreconciled, handler.keptHeld(), "pending + unreconciled = kept");
    }

    // TEST-082 verifies: TEST-007
    /// @notice The handler does real work: over 32 fixed-seed runs of 50 calls from this suite's set-up state, every
    /// action succeeds in at least 30 % of its calls and every target state is reached in at least 75 % of the runs.
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](12);
        names[0] = "pledge";
        names[1] = "withdraw";
        names[2] = "borrow";
        names[3] = "repay";
        names[4] = "setPrice";
        names[5] = "liquidate";
        names[6] = "seizeAndKeep";
        names[7] = "settlePending";
        names[8] = "partialRemove";
        names[9] = "deleverage";
        names[10] = "recredit";
        names[11] = "releaseZero";
        string[] memory targets = new string[](4);
        targets[0] = "honest liquidation";
        targets[1] = "kept seizure";
        targets[2] = "pending settlement";
        targets[3] = "zero-credit release";
        Reach memory r = _replay(address(handler), _actions(), CollateralizationHandler.Skipped.selector, 32, 50, 4);
        _check(r, names, targets, _floors(names.length, 30), _floors(targets.length, 75));
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](4);
        hit[0] = handler.honestLiquidations() != 0;
        hit[1] = handler.keptSeizures() != 0;
        hit[2] = handler.pendingSettlements() != 0;
        hit[3] = handler.zeroReleases() != 0;
    }

    function _actions() internal pure returns (bytes4[] memory actions) {
        actions = new bytes4[](12);
        actions[0] = CollateralizationHandler.pledge.selector;
        actions[1] = CollateralizationHandler.withdraw.selector;
        actions[2] = CollateralizationHandler.borrow.selector;
        actions[3] = CollateralizationHandler.repay.selector;
        actions[4] = CollateralizationHandler.setPrice.selector;
        actions[5] = CollateralizationHandler.liquidate.selector;
        actions[6] = CollateralizationHandler.seizeAndKeep.selector;
        actions[7] = CollateralizationHandler.settlePending.selector;
        actions[8] = CollateralizationHandler.partialRemove.selector;
        actions[9] = CollateralizationHandler.deleverage.selector;
        actions[10] = CollateralizationHandler.recredit.selector;
        actions[11] = CollateralizationHandler.releaseZero.selector;
    }

    function _ceilDiv(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
