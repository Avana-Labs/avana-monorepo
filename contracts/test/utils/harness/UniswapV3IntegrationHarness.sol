// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV3Integration} from "../../../src/amm/uniswap-v3/UniswapV3Integration.sol";

/// @title UniswapV3IntegrationHarness
/// @notice The Uniswap v3 LPVault with one change for local suites: the pool init code hash is the mock pool's
/// (`MockV3Factory.poolInitCodeHash()`), so the CREATE2 check of `REQ-AMM-V3-002` runs against `MockV3Factory`. Every
/// other line is the deployed contract; the canonical hash is checked on the Ethereum fork (TEST-264).
contract UniswapV3IntegrationHarness is UniswapV3Integration {
    bytes32 private immutable _INIT_CODE_HASH;

    constructor(
        uint32 integrationId,
        address collateralization,
        address marketRegistry,
        address lock,
        address timelock,
        address nfpm,
        address factory,
        bytes32 initCodeHash
    ) UniswapV3Integration(integrationId, collateralization, marketRegistry, lock, timelock, nfpm, factory) {
        _INIT_CODE_HASH = initCodeHash;
    }

    function _poolInitCodeHash() internal view override returns (bytes32) {
        return _INIT_CODE_HASH;
    }
}
