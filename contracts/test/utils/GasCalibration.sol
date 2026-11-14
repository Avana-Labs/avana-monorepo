// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Vm} from "forge-std/Vm.sol";

/// @title GasCalibration
/// @notice Cold-start gas measurement for the calibration suites in `test/gas/`: a call is run once to learn every
/// account it touches, the state is restored, every one of those accounts and its storage is marked cold (`vm.cool`),
/// and the call is run again under `gasleft()`. The figure is the call's execution with every account and slot at its
/// first access, as in a transaction that touches nothing else first (EIP-2929), without the 21,000 intrinsic gas and
/// the calldata cost. The bookkeeping runs with gas metering paused and in its own call frame (a large call's state
/// diff decodes into a large memory array, released when the frame returns), so it costs the test nothing. Suites keep
/// `isolate = false`: the fixtures rely on state carried across their setup calls.
abstract contract GasCalibration {
    Vm private constant VM_ = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice EIP-7825 per-transaction gas limit (2^24).
    uint256 internal constant TX_GAS_CAP = 16_777_216;

    mapping(address account => uint256 generation) private _seen;
    uint256 private _generation;

    /// @notice Every distinct account `target.call(data)` as `caller` touches, the state left as it was; reverts with
    /// the call's revert data when the call fails. External so its memory is released on return; call it through
    /// `_touched`.
    function gasCalibrationTouched(
        address caller,
        address target,
        bytes calldata data
    ) external returns (address[] memory accounts) {
        uint256 snap = VM_.snapshotState();
        VM_.startStateDiffRecording();
        VM_.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        Vm.AccountAccess[] memory acc = VM_.stopAndReturnStateDiff();
        _rethrow(ok, ret);
        VM_.revertToStateAndDelete(snap);
        uint256 n = 1;
        for (uint256 i = 0; i < acc.length; ++i) {
            n += 1 + acc[i].storageAccesses.length;
        }
        accounts = new address[](n);
        uint256 g = ++_generation;
        uint256 k = _add(accounts, 0, target, g);
        for (uint256 i = 0; i < acc.length; ++i) {
            k = _add(accounts, k, acc[i].account, g);
            for (uint256 j = 0; j < acc[i].storageAccesses.length; ++j) {
                k = _add(accounts, k, acc[i].storageAccesses[j].account, g);
            }
        }
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(accounts, k)
        }
    }

    function _add(
        address[] memory accounts,
        uint256 k,
        address a,
        uint256 g
    ) private returns (uint256) {
        if (_seen[a] == g) return k;
        _seen[a] = g;
        accounts[k] = a;
        return k + 1;
    }

    /// @dev `gasCalibrationTouched` with gas metering paused.
    function _touched(
        address caller,
        address target,
        bytes memory data
    ) internal returns (address[] memory accounts) {
        VM_.pauseGasMetering();
        accounts = this.gasCalibrationTouched(caller, target, data);
        VM_.resumeGasMetering();
    }

    /// @dev Marks every account of `accounts` and all of its storage cold.
    function _coolAll(
        address[] memory accounts
    ) internal {
        VM_.pauseGasMetering();
        for (uint256 i = 0; i < accounts.length; ++i) {
            VM_.cool(accounts[i]);
        }
        VM_.resumeGasMetering();
    }

    /// @dev Gas of `target.call(data)` as `caller` with every account it touches cold; the call's effects are kept.
    /// Reverts with the call's revert data when the call fails.
    function _coldGas(
        address caller,
        address target,
        bytes memory data
    ) internal returns (uint256 used) {
        _coolAll(_touched(caller, target, data));
        VM_.prank(caller);
        uint256 start = gasleft();
        (bool ok, bytes memory ret) = target.call(data);
        used = start - gasleft();
        _rethrow(ok, ret);
    }

    /// @dev Gas of `target.call(data)` as `caller` as its own transaction, for suites run with `isolate = true`: the
    /// regular gas the transaction spends before refunds, intrinsic gas and calldata included, every account cold at
    /// its first access. For calls whose state diff is too large for `_coldGas` to collect. Reverts with the call's
    /// revert data when the call fails.
    function _txGas(
        address caller,
        address target,
        bytes memory data
    ) internal returns (uint256 used) {
        VM_.prank(caller);
        (bool ok, bytes memory ret) = target.call(data);
        _rethrow(ok, ret);
        used = VM_.lastFrameGas().gasTotalUsed;
    }

    function _rethrow(
        bool ok,
        bytes memory ret
    ) internal pure {
        if (ok) return;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}
