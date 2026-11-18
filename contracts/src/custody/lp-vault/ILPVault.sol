// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../../amm/IAmmIntegrationHooks.sol";
import {ILPVaultErrors} from "./ILPVaultErrors.sol";
import {ILPVaultEvents} from "./ILPVaultEvents.sol";

/// @title ILPVault
/// @notice Custody of one AMM protocol's LP positions on one chain, on Collateralization's instruction.
/// @dev Not upgradeable, no owner. Position-moving functions are Collateralization-only, under the Lock.
interface ILPVault is IAmmIntegration, IAmmIntegrationHooks, ILPVaultEvents, ILPVaultErrors {
    /// @notice Sends a stray position (held with no depositor of record) to the owner governance established.
    /// @dev Timelock only, with the Lock free.
    function returnStray(
        bytes32 positionKey,
        address recipient
    ) external;

    /// @notice Returns whether a position is in custody for an open record.
    /// @dev Reverts with `Locked` while the lock is held.
    function isInCustody(
        bytes32 positionKey
    ) external view returns (bool inCustody);

    /// @notice Returns Collateralization, the only caller of the custody, unwind and fee functions.
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the MarketRegistry, the only caller of `bindMarket`.
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the chain's Lock.
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's AvanaTimelock, the only caller of `returnStray`.
    function TIMELOCK() external view returns (address timelock);
}
