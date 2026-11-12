// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Exposure counter named in a `CounterSaturated` event.
/// @dev `MarketRegular` and `MarketSlice` are `marketUsd[vaultToken][Regular | Slice]` (key = the market's vault token);
/// `Token` is `tokenUsd[hub][token]` (key = pool token, scoped to the market's Hub); `Depositor` is
/// `depositorUsd[hub][depositor]` (key = wallet, scoped to the market's Hub). Hub-wide counters live in this one ledger
/// per chain, so adding a Spoke or a market never multiplies them (AMMN-RT-05).
/// @custom:spec REQ-VAULT-034, REQ-VAULT-037, Q-369
enum CounterKind {
    MarketRegular,
    MarketSlice,
    Token,
    Depositor
}
