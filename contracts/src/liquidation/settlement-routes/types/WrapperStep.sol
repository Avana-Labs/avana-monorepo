// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Unwrap or redeem step of a `WrapperThenDex` route.
enum WrapperKind {
    Erc4626Redeem,
    UsdsToDai
}

/// @notice The unwrap step a `WrapperThenDex` route runs before its DEX hops.
/// @dev When `underlying` is the debt asset the route has no hops.
struct WrapperStep {
    WrapperKind kind;
    // The ERC-4626 vault (the input token itself) or the DAI/USDS converter.
    address wrapper;
    // Token the step produces: the vault's asset, or DAI.
    address underlying;
}
