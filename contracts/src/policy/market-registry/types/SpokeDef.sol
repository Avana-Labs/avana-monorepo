// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskTier} from "./RiskTier.sol";

/// @notice CDP Spoke record: one standard Aave V4 Spoke per (Hub, AMM integration, risk tier).
/// @dev Written by `deployCdpSpoke`; only `implementation` changes afterwards, on re-approval after an Aave upgrade.
struct SpokeDef {
    // True once deployed and recorded.
    bool approved;
    // Home Hub that the Spoke's vault-token collateral reserves are supplied to.
    address hub;
    // AMM integration whose markets the Spoke lists.
    uint32 integrationId;
    RiskTier riskTier;
    // Approved standard Spoke implementation behind the Spoke proxy.
    address implementation;
    address aaveOracle;
}
