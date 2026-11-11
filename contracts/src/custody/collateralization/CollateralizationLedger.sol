// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {CollateralizationBase} from "./CollateralizationBase.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {Pending} from "./types/Pending.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// Every external call in this file goes to the market's registered LPVault, the vault token, the VaultTokenFactory, the
// Aave Hub or Spoke, or (in `pledge` and `recredit`) the RiskModule's view check and the market's LPOracle, while a Lock
// member holds the Lock, so no other code can re-enter Collateralization; the order of calls, writes and events is the
// one 2.3 fixes: custody before the credit is read, balance deltas measured around the call that delivers them, and
// events that report a call's amounts after that call (REQ-VAULT-089, REQ-LOCK-017).
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
// The ledger's writes happen only inside the Adapter's and LPVaultSwap's entry points, each of which emits its 2.3 event
// (`CollateralPledged`, `RecordRecredited`, `RecordReduced`, `RecordDebited`, `CollateralReleased`, `SeizureSettled`,
// `SeizureReconciled`, `PendingSettled`); the internal helpers that write counters are covered by those events.
// forge-lint: disable-start(missing-events-access-control)
/// @title CollateralizationLedger
/// @notice The record side of Collateralization: record lookup for the Adapter-driven paths, the largest-first seizure
/// list and its debit walk, the zero-credit list, closing a record, the market's record index and reconcile on exit.
/// @dev Every walk is over one account-market's lists, at most `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 entries in all
/// (SPEC-BACK-016). Reconciliation finishes every record, total and `pending.units` update before its LPVault calls and
/// books the pending amounts from the balance deltas measured around them (REQ-VAULT-089).
/// @custom:spec REQ-VAULT-033, REQ-VAULT-054, REQ-VAULT-074, REQ-VAULT-129, REQ-VAULT-130, REQ-VAULT-134, REQ-VAULT-135, REQ-VAULT-136, REQ-VAULT-140, SPEC-BACK-006, SPEC-BACK-011, SPEC-BACK-014, SPEC-BACK-015
abstract contract CollateralizationLedger is CollateralizationBase {
    // ─── Record lookup ───

    /// @notice The open record of `positionKey` in the vault token's integration, which must belong to `vaultToken`.
    /// @dev A proxy's market is fixed at its first pledge, so `proxyMarket[record.proxy]` is the record's vault token.
    /// @custom:spec REQ-VAULT-068, REQ-VAULT-119, REQ-VAULT-102, REQ-LOCK-011
    function _record(
        Ctx memory c,
        bytes32 positionKey
    ) internal view returns (uint256 id, BackingRecord storage r) {
        id = _recordIdOf[c.integrationId][positionKey];
        if (id == 0) revert RecordNotFound();
        r = records[id];
    }

    /// @custom:spec REQ-VAULT-068, REQ-VAULT-102
    function _checkMarket(
        Ctx memory c,
        BackingRecord storage r
    ) internal view {
        if (proxyMarket[r.proxy] != c.vaultToken) revert InvalidVaultToken();
    }

    // ─── Seizure list ───

    /// @notice Inserts a record before the first entry with fewer credited units, or at the tail (SPEC-BACK-006).
    /// @custom:spec REQ-VAULT-016, SPEC-BACK-006, INV-015
    function _insert(
        uint256[] storage list,
        uint256 id,
        uint256 credited
    ) internal {
        uint256 len = list.length;
        uint256 pos = len;
        for (uint256 i = 0; i < len; ++i) {
            if (records[list[i]].credited < credited) {
                pos = i;
                break;
            }
        }
        list.push(id);
        for (uint256 j = len; j > pos; --j) {
            // Inherent: shifting at most 15 entries one place toward the tail.
            // forge-lint: disable-next-line(costly-loop)
            list[j] = list[j - 1];
        }
        if (pos != len) list[pos] = id;
    }

    /// @notice Removes `id` from `list`, keeping the order of the others.
    /// @custom:spec REQ-VAULT-033, SPEC-BACK-006
    function _remove(
        uint256[] storage list,
        uint256 id
    ) internal {
        uint256 len = list.length;
        uint256 pos = len;
        for (uint256 i = 0; i < len; ++i) {
            if (list[i] == id) {
                pos = i;
                break;
            }
        }
        // An open record sits in exactly one of its account-market's two lists.
        assert(pos < len);
        for (uint256 j = pos + 1; j < len; ++j) {
            // Inherent: shifting at most 15 entries one place toward the head.
            // forge-lint: disable-next-line(costly-loop)
            list[j - 1] = list[j];
        }
        list.pop();
    }

    /// @notice Debits `units` from the account-market's seizure list, head first (SPEC-BACK-006), releasing each
    /// debited record's exposure (SPEC-BACK-005) and capping its rescue units (SPEC-BACK-014). Records debited to 0
    /// move to the zero-credit list and stay open. Subtracts `units` from the account, market and pool totals.
    /// @custom:spec REQ-VAULT-031, REQ-VAULT-043, REQ-VAULT-054, REQ-VAULT-055, REQ-VAULT-056, REQ-VAULT-074, REQ-VAULT-117, REQ-COLL-016, SPEC-BACK-005, SPEC-BACK-006, SPEC-BACK-014, INV-015
    function _debit(
        Ctx memory c,
        address proxy,
        uint256 units
    ) internal returns (Debit[] memory debits, uint256 touched) {
        address vt = c.vaultToken;
        uint256[] storage list = seizureList[proxy][vt];
        uint256 len = list.length;
        debits = new Debit[](len);
        uint256 rem = units;
        uint256 emptied = 0;
        while (rem != 0 && touched < len) {
            uint256 id = list[touched];
            BackingRecord storage r = records[id];
            uint256 credited = r.credited;
            uint256 take = rem < credited ? rem : credited;
            rem -= take;
            // take <= credited < 2^120.
            // forge-lint: disable-next-line(unsafe-typecast)
            r.credited = uint128(credited - take);
            // uint40 seconds last until the year 36812.
            // forge-lint: disable-next-line(unsafe-typecast)
            r.lastDebitedAt = uint40(block.timestamp);
            uint256 released = _releaseExposure(c, r);
            _capRescue(r, proxy, vt);
            if (take == credited) {
                r.inList = false;
                zeroCreditList[proxy][vt].push(id);
                ++emptied;
            }
            debits[touched] = Debit({
                recordId: id,
                positionKey: r.positionKey,
                // take <= credited < 2^120.
                // forge-lint: disable-next-line(unsafe-typecast)
                take: uint128(take),
                creditedAfter: credited - take,
                capReleased: released
            });
            ++touched;
        }
        if (rem != 0) revert InsufficientCredit();
        if (emptied != 0) _dropHead(list, emptied);
        accountCredited[proxy][vt] -= units;
        totalCredited[vt] -= units;
        _poolUnits[c.poolKey] -= units;
    }

    /// @notice Removes the first `k` entries of a list (the records a debit emptied, always a prefix).
    function _dropHead(
        uint256[] storage list,
        uint256 k
    ) private {
        uint256 len = list.length;
        for (uint256 j = k; j < len; ++j) {
            // Inherent: at most 15 entries move toward the head.
            // forge-lint: disable-next-line(costly-loop)
            list[j - k] = list[j];
        }
        for (uint256 j = 0; j < k; ++j) {
            list.pop();
        }
    }

    /// @notice `rescueUnits = min(rescueUnits, credited)`, with the account sum moved by the same delta.
    /// @custom:spec REQ-COLL-016, SPEC-BACK-014, INV-082
    function _capRescue(
        BackingRecord storage r,
        address proxy,
        address vt
    ) internal {
        uint128 rescue = r.rescueUnits;
        uint128 credited = r.credited;
        if (rescue > credited) {
            accountRescueUnits[proxy][vt] -= rescue - credited;
            r.rescueUnits = credited;
        }
    }

    /// @notice Debits `units` from one record in place (partial removal, deleverage release); the record keeps its
    /// list position, or moves to the zero-credit list when emptied.
    /// @custom:spec REQ-COLL-014, REQ-COLL-017, SPEC-BACK-005, SPEC-BACK-014
    function _debitRecord(
        Ctx memory c,
        BackingRecord storage r,
        uint256 units
    ) internal returns (uint256 released) {
        address proxy = r.proxy;
        address vt = c.vaultToken;
        // units <= record.credited < 2^120, checked by every caller before the debit.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.credited -= uint128(units);
        released = _releaseExposure(c, r);
        _capRescue(r, proxy, vt);
        accountCredited[proxy][vt] -= units;
        totalCredited[vt] -= units;
        _poolUnits[c.poolKey] -= units;
    }

    // ─── Closing and the market index ───

    /// @notice Closes a record: removes it from its list and the market index, drops its rescue units and deletes it
    /// and its position index. The caller returns the position afterwards (REQ-VAULT-033).
    /// @custom:spec REQ-VAULT-033, REQ-COLL-006, REQ-COLL-016
    function _close(
        Ctx memory c,
        uint256 id,
        BackingRecord storage r
    ) internal {
        address proxy = r.proxy;
        address vt = c.vaultToken;
        if (r.inList) _remove(seizureList[proxy][vt], id);
        else _remove(zeroCreditList[proxy][vt], id);
        uint256 rescue = r.rescueUnits;
        if (rescue != 0) accountRescueUnits[proxy][vt] -= rescue;
        uint256[] storage ids = marketRecords[vt];
        uint256 index = marketRecordIndex[id] - 1;
        uint256 last = ids[ids.length - 1];
        if (last != id) {
            ids[index] = last;
            marketRecordIndex[last] = index + 1;
        }
        ids.pop();
        delete marketRecordIndex[id];
        delete _recordIdOf[r.integrationId][r.positionKey];
        delete records[id];
    }

    // ─── Reconcile on exit ───

    /// @notice Reconciles the account-market against `supplied` shares (SPEC-BACK-011): debits the shortfall
    /// largest-first, moves its units into `pending.units`, removes them from the positions to this contract and books
    /// the principal received (`min(received, removed)`, SPEC-BACK-015). Skipped while Hub added assets differ from
    /// added shares (REQ-VAULT-130). `c` must carry the reserve (`_withReserve`).
    /// @custom:spec REQ-VAULT-129, REQ-VAULT-130, REQ-VAULT-133, REQ-VAULT-134, REQ-VAULT-135, REQ-VAULT-136, REQ-VAULT-140, REQ-VAULT-143, REQ-VAULT-146, SPEC-BACK-011, SPEC-BACK-015, INV-058
    function _reconcile(
        Ctx memory c,
        address proxy,
        uint256 supplied
    ) internal {
        address vt = c.vaultToken;
        uint256 credited = accountCredited[proxy][vt];
        if (credited <= supplied || !_sharesEqualAssets(c)) return;
        uint256 shortfall = credited - supplied;
        (Debit[] memory debits, uint256 count) = _debit(c, proxy, shortfall);
        Pending storage p = pending[vt];
        p.units += shortfall;
        uint256 n = c.tokens.length;
        if (p.amounts.length == 0) p.amounts = new uint256[](n);
        uint256[] memory zeros = new uint256[](n);
        uint256[] memory total = new uint256[](n);
        for (uint256 k = 0; k < count; ++k) {
            uint256[] memory booked = _unwindToSelf(c, debits[k], zeros);
            for (uint256 i = 0; i < n; ++i) {
                total[i] += booked[i];
            }
            Debit memory d = debits[k];
            emit RecordDebited(d.recordId, d.positionKey, proxy, vt, d.take, d.creditedAfter, booked, d.capReleased);
        }
        for (uint256 i = 0; i < n; ++i) {
            // Inherent: one pending amount per market token, at most 8.
            // forge-lint: disable-next-line(costly-loop)
            if (total[i] != 0) p.amounts[i] += total[i];
        }
        emit SeizureReconciled(proxy, vt, shortfall, total);
    }

    /// @notice Has the LPVault remove one debited record's units to this contract and returns, per token,
    /// `min(received, removed)` measured by this contract's balance delta (REQ-VAULT-135).
    /// @custom:spec REQ-VAULT-088, REQ-VAULT-135, SPEC-BACK-015, Q-271
    function _unwindToSelf(
        Ctx memory c,
        Debit memory d,
        uint256[] memory zeros
    ) private returns (uint256[] memory booked) {
        uint256[] memory before = _balances(c, address(this));
        uint256[] memory removed = _unwind(c, d.positionKey, d.take, zeros, address(this));
        booked = _received(c, address(this), before);
        uint256 n = booked.length;
        for (uint256 i = 0; i < n; ++i) {
            if (removed[i] < booked[i]) booked[i] = removed[i];
        }
    }

    /// @notice The units `positionKey`'s record would keep after reconciling the account-market's current shortfall.
    /// @custom:spec REQ-VAULT-128, REQ-COLL-018, SPEC-BACK-011
    function _creditedAfterReconcile(
        Ctx memory c,
        uint256 id,
        BackingRecord storage r
    ) internal view returns (uint256) {
        address proxy = r.proxy;
        uint256 credited = accountCredited[proxy][c.vaultToken];
        uint256 supplied = _supplied(c, proxy);
        if (credited <= supplied || !_sharesEqualAssets(c)) return r.credited;
        uint256 rem = credited - supplied;
        uint256[] storage list = seizureList[proxy][c.vaultToken];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 listed = list[i];
            uint256 cr = records[listed].credited;
            uint256 take = rem < cr ? rem : cr;
            if (listed == id) return cr - take;
            rem -= take;
        }
        return r.credited;
    }

    /// @notice The exposure counters of `depositor`'s pledge into the context's market, `accountRecords` left 0.
    /// @custom:spec REQ-VAULT-014, REQ-VAULT-034, REQ-COLL-026, SPEC-BACK-004
    function _counters(
        Ctx memory c,
        address depositor
    ) internal view returns (PledgeCounters memory counters) {
        counters.hub = c.hub;
        counters.regularUsed = SafeCast.toUint128(marketUsd[c.vaultToken][Bucket.Regular]);
        counters.sliceUsed = SafeCast.toUint128(marketUsd[c.vaultToken][Bucket.Slice]);
        counters.depositorUsed = depositorUsd[c.hub][depositor];
        counters.poolKey = c.poolKey;
        counters.poolUnits = _poolUnits[c.poolKey];
        uint256 n = c.tokens.length;
        counters.tokenUsed = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            counters.tokenUsed[i] = tokenUsd[c.hub][c.tokens[i]];
        }
    }
}
// forge-lint: disable-end(missing-events-access-control)
// forge-lint: disable-end(reentrancy-no-eth)
// forge-lint: disable-end(reentrancy-events)
