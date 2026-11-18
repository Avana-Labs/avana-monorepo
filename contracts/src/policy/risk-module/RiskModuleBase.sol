// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {IPositionProxy} from "../../proxy/position-proxy/IPositionProxy.sol";
import {Market} from "../../types/MarketTypes.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

/// @title RiskModuleBase
/// @notice Implementation immutables and the reads shared by the RiskModule and its logic contracts.
/// @dev Holds no state.
abstract contract RiskModuleBase is IRiskModuleErrors {
    address internal immutable _MARKET_REGISTRY;
    address internal immutable _PARAMETER_STORE;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _ADAPTER;
    address internal immutable _LP_VAULT_SWAP;
    /// @dev `keccak256(abi.encode(im))`, compared between the RiskModule and its logic contracts.
    bytes32 internal immutable _IMMUTABLES_HASH;

    constructor(
        RiskModuleImmutables memory im
    ) {
        _MARKET_REGISTRY = im.marketRegistry;
        _PARAMETER_STORE = im.parameterStore;
        _COLLATERALIZATION = im.collateralization;
        _ADAPTER = im.adapter;
        _LP_VAULT_SWAP = im.lpVaultSwap;
        _IMMUTABLES_HASH = keccak256(abi.encode(im));
    }

    function _requireLogic(
        address logic,
        bytes32 kind
    ) internal view {
        (bytes32 k, bytes32 h) = IRiskModuleLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert InvalidLogic(logic);
    }

    function _registry() internal view returns (IMarketRegistry) {
        return IMarketRegistry(_MARKET_REGISTRY);
    }

    function _store() internal view returns (IParameterStore) {
        return IParameterStore(_PARAMETER_STORE);
    }

    function _market(
        uint256 marketId
    ) internal view returns (Market memory m) {
        // The MarketRegistry is an Avana contract; callers loop over bounded market and reserve lists.
        // forge-lint: disable-next-line(calls-loop)
        m = _registry().getMarket(marketId);
    }

    /// @dev The account's Spoke and market: the proxy's immutables (one proxy per wallet and market).
    function _account(
        address proxy
    ) internal view returns (address spoke, uint256 marketId) {
        spoke = IPositionProxy(proxy).SPOKE();
        marketId = IPositionProxy(proxy).MARKET_ID();
    }

    function _accountData(
        address spoke,
        address proxy
    ) internal view returns (IAaveV4Spoke.UserAccountData memory a) {
        a = IAaveV4Spoke(spoke).getUserAccountData(proxy);
    }

    /// @dev The LPOracle's price, 8 decimals, used for the cap charges.
    function _capPrice(
        address lpOracle
    ) internal view returns (uint256 price8) {
        return _served(lpOracle);
    }

    /// @dev The LPOracle's served price, 8 decimals, at least 1.
    function _served(
        address lpOracle
    ) internal view returns (uint256 price8) {
        int256 a = ILPOracle(lpOracle).latestAnswer();
        // `latestAnswer` is at least 1 in every state; a non-positive value reads as 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        price8 = a > 0 ? uint256(a) : 1;
    }

    /// @dev Collateral factor of the market's reserve on its latest dynamic key, bps.
    function _latestCf(
        address spoke,
        Market memory m
    ) internal view returns (uint256 cfBps) {
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        cfBps = sp.getDynamicReserveConfig(m.reserveId, sp.getReserve(m.reserveId).dynamicConfigKey).collateralFactor;
    }
}
