// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The role of a Spoke registered on a Hub asset.
enum SpokeKind {
    Lend,
    Cdp,
    Coverage,
    FeeReceiver,
    Other,
    DeficitOffset
}
