// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Which speed window a key names: a market's borrow window (key `bytes32(marketId)`), a (funding Hub, asset)
/// borrow window (key `keccak256(abi.encode(hub, asset))`) or a market's pledge window (key `bytes32(marketId)`).
/// @custom:spec REQ-RISK-092, REQ-RISK-093, REQ-RISK-097
enum SpeedScope {
    MarketBorrow,
    DebtBorrow,
    MarketPledge
}
