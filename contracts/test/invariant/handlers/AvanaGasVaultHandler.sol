// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaGasVault} from "../../../src/periphery/gas-vault/AvanaGasVault.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title AvanaGasVaultHandler
/// @notice Actors of the AvanaGasVault invariant suite (TEST-335): anyone funds and triggers `topUp`/`topUpAll`;
/// signers spend gas; the timelock adds signers, sets values either way, unpauses and withdraws; the guardian removes,
/// lowers and pauses; strangers try every privileged call. The handler keeps its own ledger of every send (time,
/// amount, cap in force) and of every balance change, so the suite can check the vault against it.
contract AvanaGasVaultHandler is CommonBase, StdUtils {
    error Skipped();

    AvanaGasVault public immutable VAULT;
    address public immutable TREASURY;
    address public immutable TIMELOCK;
    address public immutable GUARDIAN;
    address internal constant SINK = address(0x514E4B);

    /// @dev Candidate signers (more than `MAX_SIGNERS`) and outsiders who call and must never be paid.
    address[] public candidates;
    address[] public strangers;

    struct Send {
        uint256 at;
        uint256 amount;
        uint256 cap;
    }

    mapping(address signer => Send[]) internal _sends;

    uint256 public funded;
    uint256 public sent;
    uint256 public withdrawn;
    /// @dev ETH that reached an address other than a then-listed signer or TREASURY, or a listed signer above target.
    uint256 public wrongPayments;
    /// @dev A send that took the window ending at it above the cap in force.
    uint256 public capBreaches;
    /// @dev A privileged call by the wrong caller, or a guardian raise, that succeeded.
    uint256 public forbiddenSuccesses;
    /// @dev A top-up that succeeded while paused, or for a signer not below its minimum.
    uint256 public ruleBreaches;

    constructor(
        AvanaGasVault vault,
        address[] memory candidates_,
        address[] memory strangers_
    ) {
        VAULT = vault;
        TREASURY = vault.TREASURY();
        TIMELOCK = vault.TIMELOCK();
        GUARDIAN = vault.GUARDIAN();
        candidates = candidates_;
        strangers = strangers_;
    }

    function sendCount(
        address signer
    ) external view returns (uint256) {
        return _sends[signer].length;
    }

    function sendAt(
        address signer,
        uint256 i
    ) external view returns (Send memory) {
        return _sends[signer][i];
    }

    function candidateCount() external view returns (uint256) {
        return candidates.length;
    }

    // ─── Anyone ───

    function fund(
        uint256 seed,
        uint256 amount
    ) external {
        amount = bound(amount, 1, 20 ether);
        address from = strangers[seed % strangers.length];
        vm.deal(from, from.balance + amount);
        vm.prank(from);
        VAULT.fund{value: amount}();
        funded += amount;
    }

    function spend(
        uint256 seed,
        uint256 amount
    ) external {
        address signer = candidates[seed % candidates.length];
        amount = bound(amount, 0, signer.balance);
        if (amount == 0) revert Skipped();
        vm.prank(signer);
        (bool ok,) = SINK.call{value: amount}("");
        require(ok, "spend");
    }

    function topUp(
        uint256 seed,
        uint256 callerSeed
    ) external {
        address signer = candidates[seed % candidates.length];
        address caller = strangers[callerSeed % strangers.length];
        (uint256[] memory before, uint256[] memory beforeOut, uint256 held) = _snapshot();
        bool listed = VAULT.isSigner(signer);
        uint256 minBalance = VAULT.signerConfig(signer).minBalance;
        bool due = signer.balance < minBalance;
        bool wasPaused = VAULT.paused();
        vm.prank(caller);
        try VAULT.topUp(signer) returns (uint256 amount) {
            if (wasPaused || !listed || !due) ++ruleBreaches;
            _settle(before, beforeOut, held);
            if (amount == 0) ++ruleBreaches;
        } catch {}
    }

    function topUpAll(
        uint256 callerSeed
    ) external {
        address caller = strangers[callerSeed % strangers.length];
        (uint256[] memory before, uint256[] memory beforeOut, uint256 held) = _snapshot();
        bool wasPaused = VAULT.paused();
        vm.prank(caller);
        try VAULT.topUpAll() {
            if (wasPaused) ++ruleBreaches;
            _settle(before, beforeOut, held);
        } catch {}
    }

    function warp(
        uint256 secs
    ) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 hours));
    }

    // ─── TIMELOCK ───

    function addSigner(
        uint256 seed,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external {
        address signer = candidates[seed % candidates.length];
        targetBalance = bound(targetBalance, 0.01 ether, 3 ether);
        minBalance = bound(minBalance, 1, targetBalance);
        periodCap = bound(periodCap, 1, 4 ether);
        vm.prank(TIMELOCK);
        VAULT.addSigner(signer, minBalance, targetBalance, periodCap);
    }

    function setSignerConfig(
        uint256 seed,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external {
        address signer = candidates[seed % candidates.length];
        targetBalance = bound(targetBalance, 0.01 ether, 3 ether);
        minBalance = bound(minBalance, 1, targetBalance);
        periodCap = bound(periodCap, 1, 4 ether);
        vm.prank(TIMELOCK);
        VAULT.setSignerConfig(signer, minBalance, targetBalance, periodCap);
    }

    function unpause() external {
        vm.prank(TIMELOCK);
        VAULT.unpause();
    }

    function withdraw(
        uint256 amount
    ) external {
        uint256 held = address(VAULT).balance;
        if (held == 0) revert Skipped();
        amount = bound(amount, 1, held);
        uint256 treasuryBefore = TREASURY.balance;
        vm.prank(TIMELOCK);
        VAULT.withdraw(amount);
        withdrawn += amount;
        if (TREASURY.balance != treasuryBefore + amount) ++wrongPayments;
    }

    // ─── GUARDIAN ───

    function removeSigner(
        uint256 seed
    ) external {
        address signer = candidates[seed % candidates.length];
        vm.prank(GUARDIAN);
        VAULT.removeSigner(signer);
    }

    function tighten(
        uint256 seed,
        uint256 minCut,
        uint256 targetCut,
        uint256 capCut
    ) external {
        address signer = candidates[seed % candidates.length];
        AvanaGasVault.SignerConfig memory c = VAULT.signerConfig(signer);
        uint256 targetBalance = c.targetBalance - bound(targetCut, 0, c.targetBalance);
        uint256 minBalance = c.minBalance - bound(minCut, 0, c.minBalance);
        if (minBalance > targetBalance) minBalance = targetBalance;
        uint256 periodCap = c.periodCap - bound(capCut, 0, c.periodCap);
        vm.prank(GUARDIAN);
        VAULT.tightenSigner(signer, minBalance, targetBalance, periodCap);
    }

    function pause() external {
        vm.prank(GUARDIAN);
        VAULT.pause();
    }

    // ─── Forbidden ───

    /// @notice A stranger tries a timelock call, or the guardian tries a timelock call or a raise.
    function forbidden(
        uint256 seed,
        uint256 which,
        uint256 value
    ) external {
        address caller = seed % 2 == 0 ? strangers[seed % strangers.length] : GUARDIAN;
        address signer = candidates[value % candidates.length];
        which = bound(which, 0, 7);
        AvanaGasVault.SignerConfig memory c = VAULT.signerConfig(signer);
        bytes memory data;
        if (which == 0) {
            data = abi.encodeCall(VAULT.addSigner, (signer, 1, 1 ether, 1 ether));
        } else if (which == 1) {
            data = abi.encodeCall(VAULT.setSignerConfig, (signer, 1, 1 ether, 1 ether));
        } else if (which == 2) {
            data = abi.encodeCall(VAULT.unpause, ());
        } else if (which == 3) {
            data = abi.encodeCall(VAULT.withdraw, (bound(value, 1, 1 ether)));
        } else if (which == 4) {
            data =
                abi.encodeCall(VAULT.tightenSigner, (signer, c.minBalance, uint256(c.targetBalance) + 1, c.periodCap));
        } else if (which == 5) {
            data =
                abi.encodeCall(VAULT.tightenSigner, (signer, c.minBalance, c.targetBalance, uint256(c.periodCap) + 1));
        } else if (caller != GUARDIAN) {
            data = which == 6 ? abi.encodeCall(VAULT.pause, ()) : abi.encodeCall(VAULT.removeSigner, (signer));
        } else {
            revert Skipped();
        }
        vm.prank(caller);
        (bool ok,) = address(VAULT).call(data);
        if (ok) ++forbiddenSuccesses;
    }

    // ─── Ledger ───

    function _snapshot() internal view returns (uint256[] memory before, uint256[] memory out, uint256 held) {
        before = new uint256[](candidates.length);
        for (uint256 i; i < candidates.length; ++i) {
            before[i] = candidates[i].balance;
        }
        out = new uint256[](strangers.length + 1);
        for (uint256 i; i < strangers.length; ++i) {
            out[i] = strangers[i].balance;
        }
        out[strangers.length] = TREASURY.balance;
        held = address(VAULT).balance;
    }

    /// @dev Books every balance change of a top-up: each candidate paid must be listed, below target before and at most
    /// at target after, and the send is recorded against the cap in force; nobody else may gain.
    function _settle(
        uint256[] memory before,
        uint256[] memory out,
        uint256 held
    ) internal {
        uint256 paid;
        for (uint256 i; i < candidates.length; ++i) {
            address signer = candidates[i];
            if (signer.balance <= before[i]) continue;
            uint256 amount = signer.balance - before[i];
            paid += amount;
            AvanaGasVault.SignerConfig memory c = VAULT.signerConfig(signer);
            if (!VAULT.isSigner(signer) || signer.balance > c.targetBalance) ++wrongPayments;
            _sends[signer].push(Send(block.timestamp, amount, c.periodCap));
            uint256 window;
            for (uint256 k; k < _sends[signer].length; ++k) {
                if (_sends[signer][k].at + 1 days > block.timestamp) window += _sends[signer][k].amount;
            }
            if (window > c.periodCap) ++capBreaches;
        }
        for (uint256 i; i < strangers.length; ++i) {
            if (strangers[i].balance != out[i]) ++wrongPayments;
        }
        if (TREASURY.balance != out[strangers.length]) ++wrongPayments;
        if (held - address(VAULT).balance != paid) ++wrongPayments;
        sent += paid;
    }
}
