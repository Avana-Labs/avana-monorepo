// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleRoute} from "./OracleRoute.sol";
import {SecondSource} from "./SecondSource.sol";

/// @notice Oracle configuration of one pool token inside a market's `OracleConfig`.
/// @dev `routes[0]` is the primary route and `routes[1]` the alternate; failover to the alternate is automatic and a
/// standby switch acts only through the MarketRegistry's routes in force. `feedAgreementToleranceBps` is the
/// primary-versus-alternate tolerance, applied exactly. `secondSource` is the independent source a borrow or a
/// withdrawal also requires (`SecondSource`).
/// @custom:spec REQ-ORACLE-005, REQ-ORACLE-007, REQ-ORACLE-100, SPEC-ORC-003, SPEC-ORC-020, Q-323
struct TokenOracleConfig {
    // Pool token (must equal Market.tokens[i]).
    address token;
    // Primary and alternate Chainlink routes.
    OracleRoute[2] routes;
    // Primary-versus-alternate agreement tolerance, bps.
    uint16 feedAgreementToleranceBps;
    // Independent second source for borrow and withdraw.
    SecondSource secondSource;
}
