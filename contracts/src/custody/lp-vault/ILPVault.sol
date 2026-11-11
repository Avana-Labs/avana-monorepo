// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../../amm/IAmmIntegrationHooks.sol";
import {ILPVaultErrors} from "./ILPVaultErrors.sol";
import {ILPVaultEvents} from "./ILPVaultEvents.sol";

/// @title ILPVault
/// @notice AMM-neutral custody interface: the immutable LPVault of one AMM protocol on one chain (for example the
/// Uniswap v3 LPVault on Ethereum, the Slipstream LPVault on Base). It takes a position from its owner on
/// Collateralization's instruction, returns it whole only to its depositor of record, unwinds exactly the units
/// Collateralization debited for seizures, reconciliations and deleverage releases, releases part of a position to its
/// depositor, collects fees for the depositor, prices the composition of a unit at an oracle price vector, and returns
/// stray positions through a timelock operation.
/// @dev Non-upgradeable: no proxy, no `delegatecall`, no `selfdestruct`, no owner, no pause, no sweep or rescue
/// function, no generic call, multicall or ERC-1271, no approval or operator on any position manager. Holds no vault
/// token and no pool token between calls; reads no pause, breaker, address freeze, price or policy. Constructor
/// arguments: `integrationId`, the AMM protocol's canonical contracts (factory or singleton, position manager),
/// `collateralization`, `marketRegistry`, `lock`, `timelock` (the chain's AvanaTimelock). Every position-moving entry
/// point (receive, return, unwind, partial release, fee collection) requires `msg.sender == COLLATERALIZATION` and
/// `LOCK.holder()` equal to the AaveAdapter or LPVaultSwap, the Lock's only two members, so it runs only inside a call
/// tree opened by a Lock member (INV-091); `returnStray` is timelock-only with the Lock free, and `bindMarket` is
/// MarketRegistry-only and moves no position; fee collection reaches it through `AaveAdapter.collectFees` and then
/// `Collateralization.collectFees`, so a new LPVault never needs a Lock redeploy. Upstream position-manager, pool, token and Lock errors pass through unchanged.
/// Protocol specifics extend this interface: `IClIntegration` (Uniswap v3, Slipstream).
/// @custom:spec REQ-VAULT-001, REQ-VAULT-002, REQ-VAULT-003, REQ-VAULT-004, REQ-VAULT-005, REQ-VAULT-039, REQ-VAULT-040, REQ-VAULT-041, REQ-VAULT-044, REQ-VAULT-045, REQ-VAULT-077, REQ-VAULT-085, REQ-VAULT-093, REQ-VAULT-094, REQ-VAULT-095, REQ-VAULT-096, REQ-VAULT-097, REQ-VAULT-098, REQ-VAULT-099, REQ-VAULT-150, REQ-VAULT-152, REQ-VAULT-153, REQ-VAULT-154, REQ-AMM-CORE-001, INV-005, INV-007, INV-017, INV-052, Q-224, Q-226, Q-240, Q-371, INV-091
interface ILPVault is IAmmIntegration, IAmmIntegrationHooks, ILPVaultEvents, ILPVaultErrors {
    /// @notice Sends a stray position (held by the LPVault with no depositor of record) to the address governance
    /// established as its owner.
    /// @dev Requires `msg.sender == TIMELOCK` (`NotTimelock`): the chain's governance Safe schedules the call at the
    /// timelock's normal delay, any `CANCELLER_ROLE` holder can cancel it, and the LPVault keeps no timer or queue.
    /// Does not acquire the Lock: requires `!LOCK.isLocked()` and touches no record. Evaluates the stray condition at
    /// execution (`NotStray`), requires `recipient` neither zero nor the LPVault
    /// (`InvalidRecipient`), transfers the position and emits `StrayReturned`.
    /// @param positionKey The stray position.
    /// @param recipient Its rightful owner, established off-chain.
    /// @custom:spec REQ-VAULT-079, REQ-VAULT-080, REQ-VAULT-081, REQ-VAULT-082, REQ-VAULT-083, REQ-VAULT-084, REQ-VAULT-122, REQ-VAULT-123, INV-007, INV-091, Q-104, Q-228
    function returnStray(
        bytes32 positionKey,
        address recipient
    ) external;

    /// @notice Returns whether a position is in custody for an open record.
    /// @dev Equals `depositorOf(positionKey) != address(0)`. Reverts with `Locked` while the lock is held.
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-152, REQ-VAULT-160
    function isInCustody(
        bytes32 positionKey
    ) external view returns (bool inCustody);

    /// @notice Returns Collateralization, the only caller of the custody, unwind and fee functions.
    /// @return collateralization Constructor immutable.
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-002
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the MarketRegistry, the only caller of `bindMarket`.
    /// @return marketRegistry Constructor immutable.
    /// @custom:spec REQ-VAULT-155, REQ-AMM-CORE-004
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the chain's Lock.
    /// @return lock Constructor immutable.
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-150
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's AvanaTimelock, the only caller of `returnStray`.
    /// @return timelock Constructor immutable.
    /// @custom:spec REQ-VAULT-155, REQ-VAULT-080
    function TIMELOCK() external view returns (address timelock);
}
