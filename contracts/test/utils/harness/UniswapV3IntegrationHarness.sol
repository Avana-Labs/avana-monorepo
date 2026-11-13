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
    ) UniswapV3Integration(integrationId, collateralization, marketRegistry, lock, timelock, nfpm, factory, 12) {
        _INIT_CODE_HASH = initCodeHash;
    }

    function _poolInitCodeHash() internal view override returns (bytes32) {
        return _INIT_CODE_HASH;
    }
}

/// @title UniswapV3IntegrationChainHarness
/// @notice `UniswapV3IntegrationHarness` with the chain's block interval as a constructor argument (`REQ-AMM-V3-012`), for
/// suites that run the TWAP observation check at another chain's interval.
contract UniswapV3IntegrationChainHarness is UniswapV3Integration {
    bytes32 private immutable _INIT_CODE_HASH;

    constructor(
        address[6] memory bindings,
        bytes32 initCodeHash,
        uint256 blockTime
    ) UniswapV3Integration(1, bindings[0], bindings[1], bindings[2], bindings[3], bindings[4], bindings[5], blockTime) {
        _INIT_CODE_HASH = initCodeHash;
    }

    function _poolInitCodeHash() internal view override returns (bytes32) {
        return _INIT_CODE_HASH;
    }
}
