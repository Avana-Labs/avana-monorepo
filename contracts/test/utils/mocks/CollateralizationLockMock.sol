// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title CollateralizationLockMock
/// @notice Stand-in Collateralization for the VaultTokenFactory: answers only the getters `registerIntegration`
/// reads, `LOCK()` (compared with the LPVault's Lock) and `VAULT_TOKEN_FACTORY()`, `ADAPTER()` and `LP_VAULT_SWAP()`
/// (compared with the factory and its bindings).
/// @dev The Lock is fixed at construction; `setCore` sets the other three once the factory exists.
contract CollateralizationLockMock {
    address public immutable LOCK;
    address public VAULT_TOKEN_FACTORY;
    address public ADAPTER;
    address public LP_VAULT_SWAP;

    constructor(
        address lock
    ) {
        LOCK = lock;
    }

    function setCore(
        address factory,
        address adapter,
        address lpVaultSwap
    ) external {
        VAULT_TOKEN_FACTORY = factory;
        ADAPTER = adapter;
        LP_VAULT_SWAP = lpVaultSwap;
    }
}
