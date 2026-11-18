// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ITetherFee
/// @notice The transfer-fee switch of Tether USD (`TetherToken`), read by the USDT issuer probes.
/// @dev A fee rate above 0 means transfers deliver less than the amount sent.
interface ITetherFee {
    /// @notice The transfer fee, in basis points of the amount sent.
    /// @return rate Fee rate, bps.
    function basisPointsRate() external view returns (uint256 rate);
}
