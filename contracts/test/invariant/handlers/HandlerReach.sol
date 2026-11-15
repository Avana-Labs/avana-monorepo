// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CommonBase} from "forge-std/Base.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @title HandlerReach
/// @notice Measures what an invariant suite's handler actually does, so a campaign that passes because every call
/// reverted or returned early shows up as a failing test. It replays `runs` fixed-seed sequences of `depth` calls to
/// the handler's targeted selectors from the suite's set-up state, each call with pseudo-random arguments (`_calldata`), and counts
/// per selector the calls that succeeded, the calls the handler skipped (its named no-op error) and the calls that
/// failed; after each run the suite reports which of its target states the run reached. The suite then asserts a
/// floor on each selector's success rate and on each target's reach, and the logs give the table (`forge test -vv`).
/// @dev Deterministic: the same seeds every time, so the floors are regression checks on the handler's steering, not
/// statistics. Gas metering is paused (`_reachMetered`); the replay is far longer than one block.
abstract contract HandlerReach is CommonBase {
    /// @dev The accounts `_replayLanded` counts writes to (or, with `_reachExcept`, does not count).
    address[] private _reachSubjects;
    bool private _reachExcept;

    struct Reach {
        uint256[] ok;
        uint256[] skipped;
        uint256[] failed;
        uint256[] reached;
        uint256 runs;
        // Calls that returned normally but wrote no storage slot of a subject (only with `_replayLanded`).
        uint256[] noop;
    }

    /// @dev Whether the replay keeps gas metering on. Off by default (the replay is far longer than one block); a suite
    /// whose calls only end by running out of gas turns it on, so such a call fails instead of running forever.
    function _reachMetered() internal view virtual returns (bool) {
        return false;
    }

    /// @dev The target states one run reached; called at the end of each replayed run, before the state is reset.
    function _reached() internal view virtual returns (bool[] memory);

    /// @dev The call for `selector` from `seed`: five pseudo-random words, so any handler action of up to five
    /// `uint256` parameters decodes. A suite whose actions take other types (a `bool` must be 0 or 1) overrides it.
    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal view virtual returns (bytes memory) {
        return abi.encodeWithSelector(
            selector, _word(seed, 1), _word(seed, 2), _word(seed, 3), _word(seed, 4), _word(seed, 5)
        );
    }

    /// @dev The call for `selector` from `seed` with one word per parameter, each reduced to its type the way the
    /// fuzzer generates it: `kinds[i]` is 1 for a `bool`, `b` in 8..256 for a `uintb` (160 for an `address`), and
    /// `-b` for an `intb`.
    function _typed(
        bytes4 selector,
        int16[] memory kinds,
        uint256 seed
    ) internal pure returns (bytes memory data) {
        data = abi.encodePacked(selector);
        for (uint256 i = 0; i < kinds.length; ++i) {
            uint256 w = _word(seed, i + 1);
            int16 k = kinds[i];
            if (k == 1) {
                w %= 2;
            } else if (k > 0 && k < 256) {
                w &= (uint256(1) << uint16(k)) - 1;
            } else if (k < 0 && k > -256) {
                uint256 bits = uint16(-k);
                w &= (uint256(1) << bits) - 1;
                if (w >> (bits - 1) == 1) w |= type(uint256).max << bits;
            }
            data = abi.encodePacked(data, w);
        }
    }

    function _word(
        uint256 seed,
        uint256 i
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _replay(
        address handler,
        bytes4[] memory selectors,
        bytes4 skipped,
        uint256 runs,
        uint256 depth,
        uint256 targets
    ) internal returns (Reach memory r) {
        return _replayLanded(handler, selectors, skipped, runs, depth, targets, new address[](0), false);
    }

    /// @dev As `_replay`, but when `subjects` is not empty a call that returned normally counts as `ok` only if it
    /// changed a storage slot of one of `subjects` (the contracts under test) in a frame that did not revert, or, with
    /// `except`, of any account other than `subjects` (the handler and the test contract, whose ghost counters do not
    /// count); a call that returned without such a change is counted in `noop`. This catches a handler that returns
    /// early, or swallows the subject's revert in a `try`, without naming it with its skip error. Cheatcode writes
    /// (`deal`, `vm.store`) are not storage accesses and never count.
    function _replayLanded(
        address handler,
        bytes4[] memory selectors,
        bytes4 skipped,
        uint256 runs,
        uint256 depth,
        uint256 targets,
        address[] memory subjects,
        bool except
    ) internal returns (Reach memory r) {
        (_reachSubjects, _reachExcept) = (subjects, except);
        r = _replayRuns(handler, selectors, skipped, runs, depth, targets);
    }

    function _replayRuns(
        address handler,
        bytes4[] memory selectors,
        bytes4 skipped,
        uint256 runs,
        uint256 depth,
        uint256 targets
    ) private returns (Reach memory r) {
        bool metered = _reachMetered();
        if (!metered) vm.pauseGasMetering();
        uint256 n = selectors.length;
        (r.ok, r.skipped, r.failed, r.reached, r.runs, r.noop) =
        (new uint256[](n), new uint256[](n), new uint256[](n), new uint256[](targets), runs, new uint256[](n));
        uint256 snapshot = vm.snapshotState();
        for (uint256 run = 0; run < runs; ++run) {
            vm.revertToState(snapshot);
            _replayRun(handler, selectors, skipped, depth, run, r);
        }
        vm.revertToState(snapshot);
        if (!metered) vm.resumeGasMetering();
    }

    /// @dev Run `run` of the replay: `depth` calls from the current state, counted into `r`.
    function _replayRun(
        address handler,
        bytes4[] memory selectors,
        bytes4 skipped,
        uint256 depth,
        uint256 run,
        Reach memory r
    ) private {
        // Each step allocates its calldata, return data and state diff, and none of it is read after the step, so the
        // free memory pointer goes back to this mark after every step; otherwise a replay of 1,600 calls with state
        // diffs ends in `MemoryLimitOOG`.
        uint256 mark;
        assembly ("memory-safe") {
            mark := mload(0x40)
        }
        uint256 seed = uint256(keccak256(abi.encode("reach", run)));
        for (uint256 i = 0; i < depth; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 k = seed % selectors.length;
            uint256 outcome = _step(handler, selectors[k], skipped, seed);
            assembly ("memory-safe") {
                mstore(0x40, mark)
            }
            if (outcome == 0) ++r.ok[k];
            else if (outcome == 1) ++r.noop[k];
            else if (outcome == 2) ++r.skipped[k];
            else ++r.failed[k];
        }
        bool[] memory hit = _reached();
        for (uint256 t = 0; t < r.reached.length; ++t) {
            if (hit[t]) ++r.reached[t];
        }
        assembly ("memory-safe") {
            mstore(0x40, mark)
        }
    }

    /// @dev One call of the replay: 0 if it changed a counted slot (or nothing is counted), 1 if it returned without
    /// such a change, 2 if it reverted with `skipped`, 3 if it failed otherwise.
    function _step(
        address handler,
        bytes4 selector,
        bytes4 skipped,
        uint256 seed
    ) private returns (uint256) {
        address[] memory subjects = _reachSubjects;
        if (subjects.length != 0) vm.startStateDiffRecording();
        (bool ok, bytes memory ret) = handler.call(_calldata(selector, seed));
        bool changed = subjects.length == 0 || _changed(vm.stopAndReturnStateDiff(), subjects, _reachExcept);
        // A call that reverted inside `startPrank` leaves the prank on; end it before the next call.
        (VmSafe.CallerMode mode,,) = vm.readCallers();
        if (mode != VmSafe.CallerMode.None) vm.stopPrank();
        if (ok) return changed ? 0 : 1;
        return ret.length >= 4 && bytes4(ret) == skipped ? 2 : 3;
    }

    /// @dev Whether `accesses` hold a write that changed a slot of one of `subjects` (with `except`: of an account
    /// not in `subjects`) and was not reverted.
    function _changed(
        VmSafe.AccountAccess[] memory accesses,
        address[] memory subjects,
        bool except
    ) private pure returns (bool) {
        for (uint256 a = 0; a < accesses.length; ++a) {
            if (accesses[a].reverted) continue;
            VmSafe.StorageAccess[] memory st = accesses[a].storageAccesses;
            for (uint256 j = 0; j < st.length; ++j) {
                if (!st[j].isWrite || st[j].reverted || st[j].previousValue == st[j].newValue) continue;
                bool listed;
                for (uint256 s = 0; s < subjects.length; ++s) {
                    if (st[j].account == subjects[s]) listed = true;
                }
                if (listed != except) return true;
            }
        }
        return false;
    }

    /// @dev Logs the table and asserts that selector `k` succeeds in at least `minOkPct[k]` % of its calls and target
    /// `t` is reached in at least `minReachPct[t]` % of the runs.
    function _check(
        Reach memory r,
        string[] memory names,
        string[] memory targetNames,
        uint256[] memory minOkPct,
        uint256[] memory minReachPct
    ) internal pure {
        _check(r, names, targetNames, minOkPct, minReachPct, new bool[](names.length));
    }

    /// @dev As `_check`; an action with `check[k]` set is a check or a clock step that changes no stored state when it
    /// does its work, so a call of it that returned normally counts as a success whether or not it changed a slot.
    function _check(
        Reach memory r,
        string[] memory names,
        string[] memory targetNames,
        uint256[] memory minOkPct,
        uint256[] memory minReachPct,
        bool[] memory check
    ) internal pure {
        console.log("action: calls / ok / skipped / failed / no-op");
        for (uint256 k = 0; k < names.length; ++k) {
            uint256 calls = r.ok[k] + r.skipped[k] + r.failed[k] + r.noop[k];
            console.log(
                string.concat(
                    "  ",
                    names[k],
                    check[k] ? " (check)" : "",
                    ": ",
                    _row(calls, r.ok[k], r.skipped[k], r.failed[k]),
                    " / ",
                    vm.toString(r.noop[k])
                )
            );
        }
        console.log(string.concat("target: runs reaching it, of ", vm.toString(r.runs)));
        for (uint256 t = 0; t < targetNames.length; ++t) {
            console.log(string.concat("  ", targetNames[t], ": ", vm.toString(r.reached[t])));
        }
        for (uint256 k = 0; k < names.length; ++k) {
            uint256 calls = r.ok[k] + r.skipped[k] + r.failed[k] + r.noop[k];
            uint256 ok = r.ok[k] + (check[k] ? r.noop[k] : 0);
            require(calls != 0 && ok * 100 >= calls * minOkPct[k], string.concat("low success: ", names[k]));
        }
        for (uint256 t = 0; t < targetNames.length; ++t) {
            require(r.reached[t] * 100 >= r.runs * minReachPct[t], string.concat("low reach: ", targetNames[t]));
        }
    }

    /// @dev `n` copies of `pct`, for `_check`'s floors.
    function _floors(
        uint256 n,
        uint256 pct
    ) internal pure returns (uint256[] memory floors) {
        floors = new uint256[](n);
        for (uint256 t = 0; t < n; ++t) {
            floors[t] = pct;
        }
    }

    function _row(
        uint256 calls,
        uint256 ok,
        uint256 skipped,
        uint256 failed
    ) private pure returns (string memory) {
        return string.concat(
            vm.toString(calls), " / ", vm.toString(ok), " / ", vm.toString(skipped), " / ", vm.toString(failed)
        );
    }
}
