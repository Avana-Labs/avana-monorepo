// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {CommonBase} from "forge-std/Base.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @title HandlerReach
/// @notice Measures what an invariant suite's handler actually does, so a campaign that passes because every call
/// reverted or returned early shows up as a failing test. It replays `runs` fixed-seed sequences of `depth` calls to
/// the handler's targeted selectors from the suite's set-up state, each call with three pseudo-random words, and counts
/// per selector the calls that succeeded, the calls the handler skipped (its named no-op error) and the calls that
/// failed; after each run the suite reports which of its target states the run reached. The suite then asserts a
/// floor on each selector's success rate and on each target's reach, and the logs give the table (`forge test -vv`).
/// @dev Deterministic: the same seeds every time, so the floors are regression checks on the handler's steering, not
/// statistics. Gas metering is paused; the replay is far longer than one block.
abstract contract HandlerReach is CommonBase {
    struct Reach {
        uint256[] ok;
        uint256[] skipped;
        uint256[] failed;
        uint256[] reached;
        uint256 runs;
    }

    /// @dev The target states one run reached; called at the end of each replayed run, before the state is reset.
    function _reached() internal view virtual returns (bool[] memory);

    function _replay(
        address handler,
        bytes4[] memory selectors,
        bytes4 skipped,
        uint256 runs,
        uint256 depth,
        uint256 targets
    ) internal returns (Reach memory r) {
        vm.pauseGasMetering();
        uint256 n = selectors.length;
        (r.ok, r.skipped, r.failed, r.reached, r.runs) =
        (new uint256[](n), new uint256[](n), new uint256[](n), new uint256[](targets), runs);
        uint256 snapshot = vm.snapshotState();
        for (uint256 run = 0; run < runs; ++run) {
            vm.revertToState(snapshot);
            uint256 seed = uint256(keccak256(abi.encode("reach", run)));
            for (uint256 i = 0; i < depth; ++i) {
                seed = uint256(keccak256(abi.encode(seed)));
                uint256 k = seed % n;
                (bool ok, bytes memory ret) = handler.call(
                    abi.encodeWithSelector(
                        selectors[k],
                        uint256(keccak256(abi.encode(seed, 1))),
                        uint256(keccak256(abi.encode(seed, 2))),
                        uint256(keccak256(abi.encode(seed, 3))),
                        uint256(keccak256(abi.encode(seed, 4))),
                        uint256(keccak256(abi.encode(seed, 5)))
                    )
                );
                // A call that reverted inside `startPrank` leaves the prank on; end it before the next call.
                (VmSafe.CallerMode mode,,) = vm.readCallers();
                if (mode != VmSafe.CallerMode.None) vm.stopPrank();
                if (ok) ++r.ok[k];
                else if (ret.length >= 4 && bytes4(ret) == skipped) ++r.skipped[k];
                else ++r.failed[k];
            }
            bool[] memory hit = _reached();
            for (uint256 t = 0; t < targets; ++t) {
                if (hit[t]) ++r.reached[t];
            }
        }
        vm.revertToState(snapshot);
        vm.resumeGasMetering();
    }

    /// @dev Logs the table and asserts that every selector succeeds in at least `minOkPct` % of its calls and every
    /// target is reached in at least `minReachPct` % of the runs.
    function _check(
        Reach memory r,
        string[] memory names,
        string[] memory targetNames,
        uint256 minOkPct,
        uint256 minReachPct
    ) internal pure {
        console.log("action: calls / ok / skipped / failed");
        for (uint256 k = 0; k < names.length; ++k) {
            uint256 calls = r.ok[k] + r.skipped[k] + r.failed[k];
            console.log(string.concat("  ", names[k], ": ", _row(calls, r.ok[k], r.skipped[k], r.failed[k])));
        }
        console.log(string.concat("target: runs reaching it, of ", vm.toString(r.runs)));
        for (uint256 t = 0; t < targetNames.length; ++t) {
            console.log(string.concat("  ", targetNames[t], ": ", vm.toString(r.reached[t])));
        }
        for (uint256 k = 0; k < names.length; ++k) {
            uint256 calls = r.ok[k] + r.skipped[k] + r.failed[k];
            require(calls != 0 && r.ok[k] * 100 >= calls * minOkPct, string.concat("low success: ", names[k]));
        }
        for (uint256 t = 0; t < targetNames.length; ++t) {
            require(r.reached[t] * 100 >= r.runs * minReachPct, string.concat("low reach: ", targetNames[t]));
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
