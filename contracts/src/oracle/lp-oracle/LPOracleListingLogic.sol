// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {Evaluation, InitParams, LPOracleCodes} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";

// Every external call is a static call or a delegatecall into this feed's own logic, so none can reenter.
// forge-lint: disable-start(reentrancy-events)
/// @title LPOracleListingLogic
/// @notice The market part of `initialize` and `checkConfig`, run by delegatecall from the implementation.
abstract contract LPOracleListingLogic is LPOracleLogicBase {
    /// @inheritdoc ILPOracleLogic
    function poke() external pure override returns (PriceState) {
        revert NotDelegated();
    }

    /// @inheritdoc ILPOracleLogic
    function checkConfig(
        OracleConfig calldata config
    ) external view virtual override returns (uint256 failedChecks) {
        failedChecks = _checkConfig(config);
    }

    /// @inheritdoc ILPOracleLogic
    function initializeMarket(
        InitParams calldata params
    ) external virtual override onlyDelegated {
        _storeVaultDecimals(params.config);
        uint256 failed = _initCheck(params.config);
        if (failed != 0) revert ConfigCheckFailed(failed);
        Evaluation memory e = _evaluateSeed(params.config);
        if (e.state != PriceState.Live) revert NotLive(uint8(e.state), e.reasons);
        Layout storage $ = _s();
        _storeAccepted(e);
        _writeSeen(e);
        uint256 n = e.tokens.length;
        for (uint256 i = 0; i < n; ++i) {
            $.lastRoute[i] = e.tokens[i].used;
        }
        $.lastCachedWindow = e.cfg.cachedWindow;
        emit PriceSeeded($.accepted.answer, e.servedUpdatedAt, e.prices);
        _storeCheckpoint();
    }

    /// @dev `checkConfig` of `config` for `initialize`; overridden where the listing checks live in another contract.
    function _initCheck(
        OracleConfig calldata config
    ) internal virtual returns (uint256 failed) {
        failed = _checkConfig(config);
    }

    /// @dev Stores `d`; reverts `ConfigCheckFailed` when no route quotes a token or no `d` exists.
    function _storeVaultDecimals(
        OracleConfig calldata config
    ) private {
        Evaluation memory e;
        _allocate(e);
        _loadSeed(e, config);
        if (!e.failed) _selectQuotes(e);
        if (e.failed) revert ConfigCheckFailed(LPOracleCodes.CHECK_QUOTES);
        (bool found, uint8 d) = LPPriceMath.vaultDecimals(_compositionOrEmpty, e.prices, _s().tokenDecimals);
        if (!found) revert ConfigCheckFailed(LPOracleCodes.CHECK_VAULT_DECIMALS);
        Layout storage $ = _s();
        $.vaultDecimals = d;
        uint256 n = e.prices.length;
        for (uint256 i = 0; i < n; ++i) {
            // Valuation prices are at most MAX_ROUTE_ANSWER < 2^128.
            // forge-lint: disable-next-line(unsafe-typecast)
            $.listingPrices.push(uint128(e.prices[i]));
        }
    }
}
// forge-lint: disable-end(reentrancy-events)
