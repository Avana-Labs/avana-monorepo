// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {CollateralizationBase} from "./CollateralizationBase.sol";
import {BackingRecord} from "./types/BackingRecord.sol";
import {Pending} from "./types/Pending.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// External calls go only to known protocol contracts while a Lock member holds the Lock, so nothing can re-enter.
// forge-lint: disable-start(reentrancy-events)
// forge-lint: disable-start(reentrancy-no-eth)
// Ledger writes happen only inside entry points that emit their own event.
// forge-lint: disable-start(missing-events-access-control)
/// @title CollateralizationLedger
/// @notice Record side of Collateralization: lookup, seizure and zero-credit lists, debits, closing and reconcile.
abstract contract CollateralizationLedger is CollateralizationBase {
    function _record(
        Ctx memory c,
        bytes32 positionKey
    ) internal view returns (uint256 id, BackingRecord storage r) {
        id = _recordIdOf[c.integrationId][positionKey];
        if (id == 0) revert RecordNotFound();
        r = records[id];
    }

    function _checkMarket(
        Ctx memory c,
        BackingRecord storage r
    ) internal view {
        if (proxyMarket[r.proxy] != c.vaultToken) revert InvalidVaultToken();
    }

    /// @notice Inserts a record before the first entry with fewer credited units, or at the tail.
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
            // Shifts at most 15 entries one place toward the tail.
            // forge-lint: disable-next-line(costly-loop)
            list[j] = list[j - 1];
        }
        if (pos != len) list[pos] = id;
    }

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
            // Shifts at most 15 entries one place toward the head.
            // forge-lint: disable-next-line(costly-loop)
            list[j - 1] = list[j];
        }
        list.pop();
    }

    /// @notice Debits `units` from the account-market's seizure list, head first, releasing each record's exposure.
    /// @dev Records debited to 0 move to the zero-credit list and stay open.
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
            // At most 15 entries move toward the head.
            // forge-lint: disable-next-line(costly-loop)
            list[j - k] = list[j];
        }
        for (uint256 j = 0; j < k; ++j) {
            list.pop();
        }
    }

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

    /// @dev The caller returns the position afterwards.
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

    /// @notice Debits the account-market's shortfall against `supplied` shares into pending settlement.
    /// @dev Skipped while Hub added assets differ from added shares. `c` must carry the reserve (`_withReserve`).
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
            // One pending amount per market token, at most 8.
            // forge-lint: disable-next-line(costly-loop)
            if (total[i] != 0) p.amounts[i] += total[i];
        }
        emit SeizureReconciled(proxy, vt, shortfall, total);
    }

    /// @notice Unwinds one debited record's units to this contract; returns `min(received, removed)` per token.
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

    /// @notice The exposure counters of a pledge into the context's market, `accountRecords` left 0.
    function _counters(
        Ctx memory c
    ) internal view returns (PledgeCounters memory counters) {
        counters.hub = c.hub;
        counters.regularUsed = SafeCast.toUint128(marketUsd[c.vaultToken][Bucket.Regular]);
        counters.sliceUsed = SafeCast.toUint128(marketUsd[c.vaultToken][Bucket.Slice]);
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
