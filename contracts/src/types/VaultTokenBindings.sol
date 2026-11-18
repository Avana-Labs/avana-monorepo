// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Constructor bindings of one market's vault token.
struct VaultTokenBindings {
    bytes32 marketKey;
    uint32 integrationId;
    // The LPVault registered for `integrationId`.
    address integration;
    // The home Hub of the CDP Spoke.
    address hub;
    // The CDP Spoke holding the token's reserve.
    address spoke;
    uint256 marketId;
    // The market's LPOracle fixed proxy address.
    address lpOracle;
    // The chain's AaveAdapter fixed proxy address.
    address adapter;
    // The chain's LPVaultSwap fixed proxy address.
    address lpVaultSwap;
    address collateralization;
    uint8 decimals;
    string name;
    string symbol;
}
