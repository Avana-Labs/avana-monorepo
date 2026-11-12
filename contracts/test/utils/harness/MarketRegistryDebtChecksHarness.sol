// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistryDebtChecks} from "../../../src/policy/market-registry/MarketRegistryDebtChecks.sol";
import {MarketRegistryStorage} from "../../../src/policy/market-registry/MarketRegistryStorage.sol";
import {MarketRegistryImmutables} from "../../../src/policy/market-registry/types/MarketRegistryImmutables.sol";

/// @title MarketRegistryDebtChecksHarness
/// @notice External wrapper of the enablement fee read (`_feeRateZero`), so a unit test can call it with a chosen gas
/// limit and show the gas floor before the read.
contract MarketRegistryDebtChecksHarness is MarketRegistryDebtChecks {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    function feeRateZero(
        address token
    ) external view returns (bool zero) {
        return _feeRateZero(token);
    }
}
