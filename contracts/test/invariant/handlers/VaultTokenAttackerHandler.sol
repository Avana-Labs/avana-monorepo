// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IVaultToken} from "../../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title VaultTokenAttackerHandler
/// @notice Sends vault-token transfers off the three paths (proxy → Hub, Hub → proxy, Hub → LPVaultSwap) between the
/// suite's holders and bystanders: the Hub, both proxies, LPVaultSwap, the Adapter, the LPVault, Collateralization and
/// an outside attacker, by `transfer` from the sender or `transferFrom` by any of them, for any amount (0 included, which
/// is on no path). Every such call must revert `UnauthorizedTransfer(from, to)`; the ghosts count calls that succeeded
/// and calls that reverted with any other data.
contract VaultTokenAttackerHandler is CommonBase, StdUtils {
    VaultToken internal immutable TOKEN;
    address[8] internal actors;

    uint256 public offPathAccepted;
    uint256 public wrongRevert;
    uint256 public attempts;

    constructor(
        VaultToken token,
        address[8] memory actors_
    ) {
        TOKEN = token;
        actors = actors_;
    }

    /// @notice One off-path move: `transfer` from `from`, or `transferFrom(from, to)` called by `caller`. Pairs on an
    /// allowed path with a non-zero amount are skipped (the honest handler moves those).
    function attempt(
        uint256 fromSeed,
        uint256 toSeed,
        uint256 callerSeed,
        uint256 amount,
        bool viaTransferFrom
    ) external {
        address from = actors[fromSeed % 8];
        address to = actors[toSeed % 8];
        amount = bound(amount, 0, 1e12);
        if (amount != 0 && TOKEN.isAllowedTransfer(from, to)) return;
        ++attempts;
        // A handler call that reverted inside a `startPrank` leaves that prank active (cheatcode state is not rolled
        // back); end it so this call is made by `caller`.
        (VmSafe.CallerMode mode,,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.RecurrentPrank) vm.stopPrank();
        address caller = viaTransferFrom ? actors[callerSeed % 8] : from;
        vm.prank(caller);
        bool ok;
        bytes memory ret;
        if (viaTransferFrom) {
            (ok, ret) = address(TOKEN).call(abi.encodeCall(TOKEN.transferFrom, (from, to, amount)));
        } else {
            (ok, ret) = address(TOKEN).call(abi.encodeCall(TOKEN.transfer, (to, amount)));
        }
        if (ok) {
            ++offPathAccepted;
        } else if (
            keccak256(ret) != keccak256(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, from, to))
        ) {
            ++wrongRevert;
        }
    }
}
