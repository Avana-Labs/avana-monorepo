// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../../src/oracle/ILPOracle.sol";
import {LPOracle} from "../../../src/oracle/LPOracle.sol";
import {IMarketRegistry} from "../../../src/policy/market-registry/IMarketRegistry.sol";

/// @title LPOracleTestDeployer
/// @notice Deploys a market's stateless LPOracle with each token's primary Chainlink route from the MarketRegistry.
library LPOracleTestDeployer {
    function deploy(
        uint256 marketId,
        address integration,
        address parameterStore,
        address registry,
        address[] memory tokens,
        bool[] memory isUsdStable,
        uint8 vaultDecimals,
        string memory description
    ) internal returns (LPOracle) {
        ILPOracle.TokenRoute[] memory routes = new ILPOracle.TokenRoute[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            (address[] memory primary,,) = IMarketRegistry(registry).activePriceRoutes(tokens[i]);
            routes[i] = ILPOracle.TokenRoute({token: tokens[i], isUsdStable: isUsdStable[i], feeds: primary});
        }
        return new LPOracle(
            ILPOracle.Params({
                marketId: marketId,
                integration: integration,
                parameterStore: parameterStore,
                description: description,
                vaultDecimals: vaultDecimals,
                routes: routes
            })
        );
    }
}
