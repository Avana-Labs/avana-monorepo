// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskTier} from "./RiskTier.sol";

/// @notice CDP Spoke record: one standard, unmodified Aave V4 Spoke per (chain, Hub, AMM integration, risk tier),
/// listing several markets, each one collateral reserve.
/// @dev Written by `deployCdpSpoke`; `hub`, `integrationId`, `riskTier`, `implementation` and `aaveOracle` never change
/// afterwards except `implementation` on a re-approval after an Aave DAO upgrade of the Spoke. Debt reserves are
/// recorded separately per Spoke (`DebtReserveDef`).
/// @custom:spec REQ-CONFIG-016, REQ-CONFIG-074, Q-378
struct SpokeDef {
    // True once deployed and recorded.
    bool approved;
    // Home Hub: the Hub the Spoke's vault-token collateral reserves are supplied to (Stable LP, Correlated LP or Volatile LP).
    address hub;
    // AMM integration whose markets the Spoke lists.
    uint32 integrationId;
    // Risk tier of the Spoke's markets.
    RiskTier riskTier;
    // Approved standard Spoke implementation (the address in the Spoke proxy's EIP-1967 implementation slot).
    address implementation;
    // The Spoke's AaveOracle.
    address aaveOracle;
}
