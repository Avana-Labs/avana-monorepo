// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ParameterStoreStorage} from "../../../src/policy/parameter-store/ParameterStoreStorage.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {HarnessMarketRegistry} from "../../utils/mocks/HarnessMarketRegistry.sol";
import {MockIntegration, MockLPOracle, MockPool} from "../../utils/mocks/ParameterStoreMocks.sol";

/// @title ParameterStoreHarnessBase
/// @notice Shared state of the ParameterStore logic harnesses: the harness plays the ParameterStore proxy (the shared
/// ERC-7201 layout, delegatecalls into one logic contract, `TIMELOCK` and `normalDelay()`), over a mocked registry with
/// one Registered market (USDC/USDT in an address-keyed pool, default parameters of 1.5) and a mocked LPOracle.
abstract contract ParameterStoreHarnessBase is ParameterStoreStorage {
    uint256 internal constant M = 1;
    uint256 internal constant NORMAL_DELAY = 432_000;
    address internal constant USDC = address(0x5DC);
    address internal constant USDT = address(0x5D7);

    MockLPOracle internal immutable ORACLE;
    MockIntegration internal immutable INTEGRATION;
    MockPool internal immutable POOL;

    /// @notice Number of setter calls attempted in assertion mode; written so each call is a transaction.
    uint256 public calls;

    constructor() ParameterStoreStorage(address(this), address(new HarnessMarketRegistry()), 12) {
        ORACLE = new MockLPOracle();
        INTEGRATION = new MockIntegration();
        POOL = new MockPool();
        HarnessMarketRegistry(address(_REGISTRY)).set(address(POOL), address(INTEGRATION), address(ORACLE), USDC, USDT);
        Layout storage $ = _s();
        MarketParams storage p = $.market[M];
        p.slippageAllowanceBps = 100;
        p.slippageAllowanceMinBps = 30;
        p.poolRiskFactor = 4000;
        p.minPledgeUsd = 10e8;
        $.tokenCollateralFactorBps[USDC] = 7800;
        $.tokenCollateralFactorBps[USDT] = 7500;
    }

    /// @notice The timelock's normal delay, read by the logic to space loosenings.
    function normalDelay() external pure returns (uint256) {
        return NORMAL_DELAY;
    }

    function _call(
        address logic,
        bytes memory data
    ) internal returns (bool ok) {
        ++calls;
        (ok,) = logic.delegatecall(data);
    }
}
