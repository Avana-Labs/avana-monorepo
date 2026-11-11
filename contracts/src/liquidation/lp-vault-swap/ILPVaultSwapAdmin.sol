// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapAdmin
/// @notice Initialization of the LPVaultSwap proxy and governance of the committed-operator registry (the keeper list).
/// The registry gates no call: every address that is not frozen may call `liquidate` (Q-404). It feeds `KEEPER_FLOOR`,
/// the RiskModule's borrowing halt at zero active committed operators, and monitoring. The selectors keep their names
/// (`addKeeper`, `removeKeeper`), so the timelock's delay classes stay as registered.
/// @dev Every governance call comes from the AvanaTimelock holding `APPLICATION_ADMIN`; the selectors' delay classes
/// are registered in the timelock (`addKeeper` normal, `removeKeeper` short). Upgrades go through UUPS
/// `upgradeToAndCall`, whose `_authorizeUpgrade` requires `APPLICATION_ADMIN` (normal delay). `_grantRole` reverts
/// `AdminRoleOnlyTimelock(role, account)` for `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` granted to any account
/// other than the timelock (REQ-ACCESS-153, Q-259).
interface ILPVaultSwapAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, atomically with the proxy deployment (later versions run a reinitializer inside
    /// `upgradeToAndCall`). Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `timelock` only. The launch registry
    /// holds Avana's own keeper as the committed operator (`KEEPER_FLOOR = 1`, Q-400); others can be added later. The call reverts with
    /// `KeeperFloor` for fewer than `KEEPER_FLOOR` keepers, `TooManyKeepers` above `MAX_KEEPERS` and `InvalidKeeper` for a zero or duplicate
    /// address.
    /// @param timelock The AvanaTimelock.
    /// @param initialKeepers Committed operators at launch.
    /// @custom:spec REQ-SWAP-032, REQ-SWAP-034, REQ-SWAP-040, Q-226, Q-228
    function initialize(
        address timelock,
        address[] calldata initialKeepers
    ) external;

    /// @notice Registers a committed operator, which commits to liquidate every account below HF 1 on the chain.
    /// @dev `APPLICATION_ADMIN` (the AvanaTimelock) at the normal delay, cancellable only by `DAO_CANCELLER_ROLE`
    /// (Q-263); reverts `InvalidKeeper` for `address(0)` or an already registered operator, `AddressIsFrozen` for a
    /// frozen address and `TooManyKeepers(MAX_KEEPERS)` when 32 operators are already registered. Registration grants no
    /// power over `liquidate`. Emits `KeeperAdded`.
    /// @param keeper The operator's address (its key, Safe or per-operator flash liquidation helper).
    /// @custom:spec REQ-SWAP-033, REQ-SWAP-085, REQ-SWAP-107, REQ-SWAP-117, Q-228, Q-242, Q-263, Q-400, Q-404
    function addKeeper(
        address keeper
    ) external;

    /// @notice Removes a committed operator from the registry.
    /// @dev `APPLICATION_ADMIN` (the AvanaTimelock) at the short delay. The call reverts with `InvalidKeeper` if
    /// `keeper` is not registered and with `KeeperFloor(activeAfter, KEEPER_FLOOR)` if `activeAfter < KEEPER_FLOOR`, with
    /// `activeAfter` the active (unfrozen) committed operators after the removal. Removal never stops the address's
    /// `liquidate` calls. Emits `KeeperRemoved`.
    /// @param keeper The operator's address.
    /// @custom:spec REQ-SWAP-035, REQ-SWAP-038, REQ-SWAP-065, REQ-SWAP-085, REQ-SWAP-107, Q-228, Q-242, Q-404
    function removeKeeper(
        address keeper
    ) external;
}
