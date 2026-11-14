// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryStandby} from "../../src/policy/market-registry/IMarketRegistryStandby.sol";
import {IMarketRegistryViews} from "../../src/policy/market-registry/IMarketRegistryViews.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";

contract CallGasProbe {
    function used(
        address t,
        bytes calldata d
    ) external view returns (bool ok, uint256 gasUsed) {
        uint256 g = gasleft();
        (ok,) = t.staticcall(d);
        gasUsed = g - gasleft();
    }
}

/// @dev Measurement only: cold gas of the MarketRegistry reads the DebtOracle makes with CONFIG_CALL_GAS = 40,000.
contract RegistryReadGasTest is MarketRegistryFixture {
    CallGasProbe internal probe;

    function setUp() public {
        _setUpWorld();
        probe = new CallGasProbe();
    }

    function test_measure_getToken() public {
        (bool ok, uint256 g) =
            probe.used(address(registry), abi.encodeCall(IMarketRegistryViews.getToken, (address(usdc))));
        assertTrue(ok);
        emit log_named_uint("getToken cold gas incl. 2,600 cold access", g);
    }

    function test_measure_activePriceRoutes() public {
        (bool ok, uint256 g) =
            probe.used(address(registry), abi.encodeCall(IMarketRegistryStandby.activePriceRoutes, (address(usdc))));
        assertTrue(ok);
        emit log_named_uint("activePriceRoutes cold gas incl. 2,600 cold access", g);
    }
}
