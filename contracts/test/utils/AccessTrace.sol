// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Vm, VmSafe} from "forge-std/Vm.sol";

/// @title AccessTrace
/// @notice Reads over the ordered account accesses `vm.stopAndReturnStateDiff()` returns: where a call to an account
/// with a selector first happened, how often it happened and whether an account's storage was written between two
/// accesses. Tests use it to check the order of external calls and that a call stored state, on the real contracts.
library AccessTrace {
    /// @notice Index of the first non-reverted CALL or STATICCALL to `account` whose calldata starts with `selector`,
    /// made by `from` (any caller when `from` is 0), at or after `start`.
    function firstCall(
        Vm.AccountAccess[] memory acc,
        address account,
        bytes4 selector,
        address from,
        uint256 start
    ) internal pure returns (bool found, uint256 index) {
        for (uint256 i = start; i < acc.length; ++i) {
            if (_isCall(acc[i], account, selector, from)) return (true, i);
        }
    }

    /// @notice Number of non-reverted CALLs or STATICCALLs to `account` with `selector` made by `from` (any caller when
    /// `from` is 0).
    function countCalls(
        Vm.AccountAccess[] memory acc,
        address account,
        bytes4 selector,
        address from
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < acc.length; ++i) {
            if (_isCall(acc[i], account, selector, from)) ++n;
        }
    }

    /// @notice Number of accesses of any kind to `account` (calls, static calls, balance and code reads).
    function touches(
        Vm.AccountAccess[] memory acc,
        address account
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < acc.length; ++i) {
            if (acc[i].account == account) ++n;
        }
    }

    /// @notice Whether a non-reverted storage write to `account` is recorded in an access with index in
    /// `[fromIndex, toIndex)`.
    function wroteStorage(
        Vm.AccountAccess[] memory acc,
        address account,
        uint256 fromIndex,
        uint256 toIndex
    ) internal pure returns (bool) {
        for (uint256 i = fromIndex; i < toIndex && i < acc.length; ++i) {
            Vm.StorageAccess[] memory s = acc[i].storageAccesses;
            for (uint256 j = 0; j < s.length; ++j) {
                if (s[j].account == account && s[j].isWrite && !s[j].reverted) return true;
            }
        }
        return false;
    }

    /// @notice Number of non-reverted storage writes to `account` anywhere in the trace.
    function writes(
        Vm.AccountAccess[] memory acc,
        address account
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < acc.length; ++i) {
            Vm.StorageAccess[] memory s = acc[i].storageAccesses;
            for (uint256 j = 0; j < s.length; ++j) {
                if (s[j].account == account && s[j].isWrite && !s[j].reverted) ++n;
            }
        }
    }

    function _isCall(
        Vm.AccountAccess memory a,
        address account,
        bytes4 selector,
        address from
    ) private pure returns (bool) {
        if (a.account != account || a.reverted) return false;
        if (a.kind != VmSafe.AccountAccessKind.Call && a.kind != VmSafe.AccountAccessKind.StaticCall) return false;
        if (from != address(0) && a.accessor != from) return false;
        return a.data.length >= 4 && bytes4(a.data) == selector;
    }
}
