// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../../src/custody/collateralization/types/BackingRecord.sol";
import {CollateralizationLedgerHarness, HarnessLock} from "../../utils/harness/CollateralizationLedgerHarness.sol";

/// @title CollateralizationProperties
/// @notice Echidna and Medusa properties of Collateralization's record internals (2.3) over two accounts of one
/// market. Between transactions: each account's credit is the sum of its records' credited units and the market total
/// is the sum over both; every seizure-list record has credited units and every zero-credit record has none; an
/// account holds at most 16 open records; rescue units never exceed credited units and sum per account; the market
/// buckets and the token counter equal the sum of the remaining charges. Inside one transaction: a pledge inserts
/// largest-first, a debit takes exactly its units head first or reverts with nothing changed, a close removes exactly
/// one record.
/// @dev The harness inherits the production internals and writes records as `pledge` does after its external checks;
/// Aave, the vault token and the LPVault are outside it. `property_` functions run in property mode; `pledge`, `debit`,
/// `reduce` and `close` run in assertion mode with finite branching.
/// Compilation: the harness inherits the facets and compiles with the default legacy pipeline, while the deployed
/// `Collateralization.sol` is built via IR at 200 runs (foundry.toml compilation restriction). These checks therefore
/// cover the source logic of the internals; the deployed bytecode is covered by the unit, fuzz, invariant and gas suites,
/// which deploy `Collateralization.sol:Collateralization`, and by Certora, which compiles with the same two settings.
contract CollateralizationProperties {
    address internal constant P0 = address(0xA0);
    address internal constant P1 = address(0xA1);

    CollateralizationLedgerHarness internal immutable H;
    HarnessLock internal immutable LOCK;

    /// @notice Number of assertion calls run; written so each call is a transaction.
    uint256 public calls;

    constructor() {
        LOCK = new HarnessLock();
        H = new CollateralizationLedgerHarness(address(0xADA), address(0x5A1), address(LOCK));
    }

    function _proxy(
        bool second
    ) internal pure returns (address) {
        return second ? P1 : P0;
    }

    function _open(
        address p
    ) internal view returns (uint256) {
        return H.list(p).length + H.zeros(p).length;
    }

    // ─── Assertion entry points ───

    /// @notice A pledge of `units` (1 to 2^64) charged `charge` with a slice and rescue units inside the charge checks.
    function pledge(
        bool second,
        uint64 units,
        uint64 charge,
        uint64 slice,
        bool rescue
    ) external {
        ++calls;
        address p = _proxy(second);
        if (_open(p) >= 16) return;
        uint128 u = uint128(units) + 1;
        uint64 c = charge == 0 ? 1 : (charge > type(uint64).max / 4 ? type(uint64).max / 4 : charge);
        uint64 s = slice > c ? c : slice;
        uint256 id = H.seed(p, u, c, s, rescue ? u : 0);
        uint256[] memory l = H.list(p);
        uint256 pos = l.length;
        for (uint256 i = 0; i < l.length; ++i) {
            if (l[i] == id) pos = i;
        }
        assert(pos < l.length);
        if (pos > 0) assert(H.record(l[pos - 1]).credited >= u);
        if (pos + 1 < l.length) assert(H.record(l[pos + 1]).credited < u);
    }

    /// @notice A seizure or reconciliation debit of `units` from one account.
    function debit(
        bool second,
        uint256 units
    ) external {
        ++calls;
        address p = _proxy(second);
        uint256 before = H.credit(p);
        uint256 totalBefore = H.total();
        try H.debit(p, units) {
            assert(units <= before);
            assert(H.credit(p) == before - units);
            assert(H.total() == totalBefore - units);
            uint256[] memory l = H.list(p);
            for (uint256 i = 1; i < l.length; ++i) {
                // Every record left in the seizure list keeps credited units.
                assert(H.record(l[i]).credited > 0);
            }
        } catch {
            assert(units > before);
            assert(H.credit(p) == before);
        }
    }

    /// @notice A partial removal of `units` below one record's credit.
    function reduce(
        bool second,
        uint8 index,
        uint64 units
    ) external {
        ++calls;
        address p = _proxy(second);
        uint256[] memory l = H.list(p);
        if (l.length == 0) return;
        uint256 id = l[index % l.length];
        uint256 credited = H.record(id).credited;
        if (units == 0 || units >= credited) return;
        uint256 before = H.credit(p);
        H.debitRecord(id, units);
        assert(H.credit(p) == before - units);
        assert(H.record(id).inList);
        assert(H.record(id).rescueUnits <= H.record(id).credited);
    }

    /// @notice A withdrawal or zero-credit release closes one open record.
    function close(
        bool second,
        uint8 index,
        bool zero
    ) external {
        ++calls;
        address p = _proxy(second);
        uint256[] memory l = zero ? H.zeros(p) : H.list(p);
        if (l.length == 0) return;
        uint256 id = l[index % l.length];
        uint256 open = _open(p);
        H.close(id);
        assert(_open(p) == open - 1);
        assert(H.record(id).depositor == address(0));
    }

    // ─── Properties ───

    function _sums(
        address p
    ) internal view returns (uint256 credited, uint256 rescue, uint256 charges, bool shape) {
        shape = true;
        uint256[] memory l = H.list(p);
        for (uint256 i = 0; i < l.length; ++i) {
            BackingRecord memory r = H.record(l[i]);
            if (r.credited == 0 || !r.inList || r.rescueUnits > r.credited) shape = false;
            credited += r.credited;
            rescue += r.rescueUnits;
            charges += r.currentUsdCharge;
        }
        uint256[] memory z = H.zeros(p);
        for (uint256 i = 0; i < z.length; ++i) {
            BackingRecord memory r = H.record(z[i]);
            if (r.credited != 0 || r.inList || r.rescueUnits != 0 || r.depositor == address(0)) shape = false;
            charges += r.currentUsdCharge;
        }
    }

    function property_creditsAreSums() external view returns (bool) {
        (uint256 c0,,,) = _sums(P0);
        (uint256 c1,,,) = _sums(P1);
        return H.credit(P0) == c0 && H.credit(P1) == c1 && H.total() == c0 + c1 && H.pool() == c0 + c1;
    }

    function property_listShape() external view returns (bool) {
        (,,, bool s0) = _sums(P0);
        (,,, bool s1) = _sums(P1);
        return s0 && s1 && _open(P0) <= 16 && _open(P1) <= 16;
    }

    function property_rescueSums() external view returns (bool) {
        (, uint256 r0,,) = _sums(P0);
        (, uint256 r1,,) = _sums(P1);
        return H.rescueSum(P0) == r0 && H.rescueSum(P1) == r1;
    }

    function property_countersFollowCharges() external view returns (bool) {
        (,, uint256 ch0,) = _sums(P0);
        (,, uint256 ch1,) = _sums(P1);
        (uint256 regular, uint256 slice) = H.market();
        return regular + slice == ch0 + ch1 && H.tokenCounter() == ch0 + ch1;
    }
}
