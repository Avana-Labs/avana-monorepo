// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ParameterStoreStorage} from "../../../src/policy/parameter-store/ParameterStoreStorage.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {OracleConfig} from "../../../src/types/OracleConfig.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {HarnessMarketRegistry} from "../../utils/mocks/HarnessMarketRegistry.sol";
import {MockIntegration, MockLPOracle, MockPool} from "../../utils/mocks/ParameterStoreMocks.sol";

/// @title ParameterStoreHarnessBase
/// @notice Shared state of the ParameterStore logic harnesses: the harness plays the ParameterStore proxy (the shared
/// ERC-7201 layout, delegatecalls into one logic contract, `TIMELOCK` and `normalDelay()`), over a mocked registry with
/// one Registered market (USDC/USDT in an address-keyed pool, launch parameters of 1.5) and a mocked LPOracle.
/// @dev The proxy's own `getOracleConfig` lives in the AdminOracle logic; deploying it beside the subject would pass
/// the 49,152-byte initcode limit, so the harness answers it with an empty configuration and the mocked LPOracle's
/// `checkConfig` answers with the failures a handler sets. Every `checkConfig` re-run of the subject still runs.
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

    constructor(
        bool hasSequencer
    ) ParameterStoreStorage(address(this), address(new HarnessMarketRegistry()), 12, hasSequencer) {
        ORACLE = new MockLPOracle();
        INTEGRATION = new MockIntegration();
        POOL = new MockPool();
        HarnessMarketRegistry(address(_REGISTRY)).set(address(POOL), address(INTEGRATION), address(ORACLE), USDC, USDT);
        Layout storage $ = _s();
        MarketParams storage p = $.market[M];
        p.consistencyToleranceBps = 50;
        p.slippageAllowanceBps = 100;
        p.slippageAllowanceMinBps = 30;
        p.poolRiskFactor = 4000;
        p.minPledgeUsd = 10e8;
        $.tokenCollateralFactorBps[USDC] = 7800;
        $.tokenCollateralFactorBps[USDT] = 7500;
        $.feedAgreementToleranceBps[USDC] = 150;
        $.feedAgreementToleranceBps[USDT] = 150;
        $.g.cachedWindow = 3600;
        $.g.usdBandLow = 0.9e8;
        $.g.usdBandHigh = 1.02e8;
        $.g.feedAgreementMarginBps = 50;
    }

    /// @notice The timelock's normal delay, read by the logic to space loosenings.
    function normalDelay() external pure returns (uint256) {
        return NORMAL_DELAY;
    }

    /// @notice The configuration the store serves an LPOracle, empty here (see the contract notes).
    function getOracleConfig(
        address
    ) external pure returns (OracleConfig memory config) {}

    /// @notice Makes every `checkConfig` of the market's LPOracle fail (or pass again).
    function breakOracle(
        bool broken
    ) external {
        ORACLE.setFailed(broken ? 1 : 0);
    }

    /// @dev Whether second source `s` reads the market's own pool.
    function _readsOwnPool(
        SecondSource storage s
    ) internal view returns (bool) {
        return s.kind == SecondSourceKind.PoolTwap && s.poolRef == bytes32(uint256(uint160(address(POOL))));
    }

    /// @dev Whether every TWAP window the store governs fits the sequencer grace (REQ-PSTORE-034).
    function _windowsFitGrace() internal view returns (bool) {
        Layout storage $ = _s();
        if (!_HAS_SEQUENCER) return true;
        uint32 grace = $.sequencer.gracePeriod;
        return $.market[M].twapWindow <= grace && $.secondSource[USDC].twapWindow <= grace
            && $.standby[USDC].twapWindow <= grace && $.secondSource[USDT].twapWindow <= grace
            && $.standby[USDT].twapWindow <= grace;
    }

    function _call(
        address logic,
        bytes memory data
    ) internal returns (bool ok) {
        ++calls;
        (ok,) = logic.delegatecall(data);
    }
}
