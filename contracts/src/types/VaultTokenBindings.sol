// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Constructor bindings of one market's vault token, in the order of the 2.4 Inputs table.
/// @dev The VaultTokenFactory builds it in `deployVaultToken`: `integration = lpVaultOf(integrationId)` and its own
/// `ADAPTER`, `LP_VAULT_SWAP` and `COLLATERALIZATION`; the other fields are the listing's arguments and the market key
/// it computes. One struct argument keeps the constructor's ABI decoding within the EVM stack.
/// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-022, REQ-VTOKEN-046
struct VaultTokenBindings {
    // The market's key, `SPEC-AMM-CORE-002`.
    bytes32 marketKey;
    // The market's AMM integration identifier.
    uint32 integrationId;
    // The LPVault registered for `integrationId`.
    address integration;
    // The home Hub of the CDP Spoke.
    address hub;
    // The CDP Spoke holding the token's reserve.
    address spoke;
    // The market's MarketRegistry `marketId`.
    uint256 marketId;
    // The market's LPOracle fixed proxy address.
    address lpOracle;
    // The chain's AaveAdapter fixed proxy address.
    address adapter;
    // The chain's LPVaultSwap fixed proxy address.
    address lpVaultSwap;
    // The chain's Collateralization.
    address collateralization;
    // Token decimals `d` per `SPEC-UNIT-001`.
    uint8 decimals;
    // Token name.
    string name;
    // Token symbol.
    string symbol;
}
