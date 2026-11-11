// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILock
/// @notice Chain-wide reentrancy lock shared by every Avana contract on the chain that moves assets or changes
/// accounting.
/// @dev Immutable: no owner, admin, setter, upgrade proxy, pause or `selfdestruct`. The holder is a single address in
/// EIP-1153 transient storage at `LockSlot.HOLDER_SLOT`, so the lock is free at the start of every transaction and a
/// revert rolls it back. Exactly two members, both constructor immutables at fixed proxy addresses: the chain's
/// AaveAdapter and LPVaultSwap. Every LPVault (one per AMM protocol) and Collateralization entry point that moves value
/// is reachable only inside a call tree one of these two members opened, so a CDP Spoke, market or LPVault added later
/// never needs a Lock redeploy (Q-377). Outer entry points (Adapter `pledge`, `recredit`, `borrow`, `repay`,
/// `withdraw`, `removeLiquidity`, `repayAllAndWithdraw`, `repayWithCollateral`, `releaseZeroCredit`, `collectFees`;
/// LPVaultSwap `liquidate`, `settlePending`) acquire it before any other external call and release it before every
/// successful return. Inner callees (Collateralization and every LPVault entry point that moves value; Adapter
/// `burnSeized`, `deleverageRepay`, `deleverageRelease`; LPVaultSwap `deleverage` and its flash callback;
/// swap-route calls; PayoutEscrow (payout escrow) `deposit`) check `holder()` against the member that must
/// hold it and their named caller, and never call `acquire()`. During a repay with collateral the AaveAdapter holds
/// the lock while LPVaultSwap's `deleverage`, its flash callback and its swap-route calls run, keyed to the Adapter's
/// transient deleverage session and LPVaultSwap's transient deleverage flag. PositionProxies, the ProxyManager,
/// LPVaults, Collateralization, the IFlashSource implementation and vault tokens are not members; they check their
/// caller and run only inside a member's call tree. The PayoutEscrow's `claim` and each LPVault's timelock-only stray-position
/// return neither acquire nor join the lock: they revert while the lock is held. LPOracle `poke()`, called inside a held lock (by Collateralization, the RiskModule and LPVaultSwap) and by keepers outside it, neither acquires nor
/// checks it. The Lock emits no events. Constructor arguments: `aaveAdapter`, `lpVaultSwap`, two distinct non-zero addresses
/// (`InvalidMembers` otherwise); the constructor also stores `address(this)` as `SELF`. Deployment uses the CREATE3-predicted proxy addresses of both members and the
/// deployment check verifies each immutable.
/// @custom:spec REQ-LOCK-001, REQ-LOCK-002, REQ-LOCK-007, REQ-LOCK-010, REQ-LOCK-011, REQ-LOCK-012, REQ-LOCK-013, REQ-LOCK-014, REQ-LOCK-015, REQ-LOCK-016, REQ-LOCK-017, REQ-LOCK-018, REQ-LOCK-023, REQ-LOCK-024, REQ-LOCK-026, REQ-LOCK-027, REQ-LOCK-029, REQ-LOCK-030, INV-054, Q-148, Q-201, Q-223, Q-224, Q-254, Q-255, Q-377
interface ILock {
    /// @notice The constructor was given a zero member or the same address for both members.
    /// @dev The member set is always two distinct, non-zero addresses; neither needs code at deployment, because the
    /// Lock fixes the members' predicted proxy addresses, whether it is deployed before or after them.
    /// @custom:spec REQ-LOCK-029
    error InvalidMembers();

    /// @notice A Lock function was reached through `delegatecall`.
    /// @dev Every function checks `address(this) == SELF`, so the transient slot is never written in another
    /// contract's context.
    /// @custom:spec REQ-LOCK-003, REQ-LOCK-022
    error DelegateCallNotAllowed();

    /// @notice `acquire()` was called by an address outside the fixed member set.
    /// @param caller The rejected `msg.sender`.
    /// @custom:spec REQ-LOCK-004, REQ-LOCK-019, REQ-LOCK-025
    error NotMember(address caller);

    /// @notice `acquire()` was called while the lock is held by any address, including the caller.
    /// @param holder The current holder.
    /// @custom:spec REQ-LOCK-005, REQ-LOCK-020
    error LockHeld(address holder);

    /// @notice `release()` was called by an address that is not the current holder.
    /// @param caller The rejected `msg.sender`.
    /// @custom:spec REQ-LOCK-008, REQ-LOCK-021
    error NotHolder(address caller);

    /// @notice Takes the lock for `msg.sender`.
    /// @dev Accepted only from `AAVE_ADAPTER` or `LP_VAULT_SWAP`; otherwise the call reverts with `NotMember`. If the
    /// lock is held by any address the call reverts with `LockHeld`; there is no nesting, counting or re-entry by the
    /// same holder. On success writes `msg.sender` to the holder slot. Constant gas: the delegatecall check, at most two
    /// member comparisons, one `TLOAD` and one `TSTORE`, with no external call.
    /// @custom:spec REQ-LOCK-004, REQ-LOCK-005, REQ-LOCK-006, REQ-LOCK-018, REQ-LOCK-019, REQ-LOCK-020, REQ-LOCK-024, REQ-LOCK-025
    function acquire() external;

    /// @notice Frees the lock.
    /// @dev The call reverts with `NotHolder` unless `msg.sender` is the address in the holder slot; on success
    /// writes `address(0)` to the slot. No role and no member can clear the lock on behalf of another holder.
    /// @custom:spec REQ-LOCK-008, REQ-LOCK-015, REQ-LOCK-021
    function release() external;

    /// @notice Returns the current holder.
    /// @dev View; never reverts outside a delegatecall.
    /// @return currentHolder The address in the holder slot, or `address(0)` when the lock is free.
    /// @custom:spec REQ-LOCK-009
    function holder() external view returns (address currentHolder);

    /// @notice Returns whether the lock is held.
    /// @dev Equals `holder() != address(0)`. The Lens, Collateralization and LPVault views refuse to answer while this
    /// is true, except Collateralization's views for the current holder, `getAccountRescueUnits` while the AaveAdapter holds
    /// the lock, and an LPVault's `liquidityOf` for Collateralization (REQ-LOCK-016).
    /// @return locked True while an Avana call is in flight.
    /// @custom:spec REQ-LOCK-009, REQ-LOCK-016
    function isLocked() external view returns (bool locked);

    /// @notice Returns the AaveAdapter fixed proxy address, one of the two members.
    /// @return aaveAdapter The Adapter proxy.
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-004
    function AAVE_ADAPTER() external view returns (address aaveAdapter);

    /// @notice Returns the LPVaultSwap fixed proxy address, one of the two members.
    /// @return lpVaultSwap The LPVaultSwap proxy.
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-004
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the Lock's own deployed address, used for the delegatecall check.
    /// @return self The Lock address.
    /// @custom:spec REQ-LOCK-001, REQ-LOCK-003
    function SELF() external view returns (address self);
}
