// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleLeg} from "./OracleLeg.sol";

/// @notice One Chainlink price route of a token: a direct TOKEN/USD leg, or two legs multiplied (TOKEN/X then X/USD).
/// @dev Only `legs[0 .. legCount - 1]` are used. The route value is the normalised single leg, or
/// `mulDiv(aA, aB, 10^(fA + fB - 8))` for two legs, and its timestamp is the oldest leg `updatedAt`.
/// @custom:spec SPEC-ORC-002, REQ-ORACLE-004, REQ-CONFIG-021
struct OracleRoute {
    // Number of legs in use, 1 or 2.
    uint8 legCount;
    // Legs in multiplication order.
    OracleLeg[2] legs;
}
