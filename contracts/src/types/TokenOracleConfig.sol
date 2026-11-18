// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleRoute} from "./OracleRoute.sol";
import {SecondSource} from "./SecondSource.sol";

/// @notice Oracle configuration of one pool token inside a market's `OracleConfig`.
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
