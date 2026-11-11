// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {Evaluation, LPOracleCodes} from "./LPOracleTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {InitParams} from "./types/InitParams.sol";

// Every external call of the LPOracle is a static call (STATICCALL, or a delegatecall into its own logic, which makes
// only static calls), so no call can reenter and reorder the events emitted after it (REQ-ORACLE-025).
// forge-lint: disable-start(reentrancy-events)
/// @title LPOracleListingLogic
/// @notice The market part of `initialize` and `checkConfig`, run by delegatecall from the implementation.
/// @dev `initializeMarket` runs after the implementation stored the market from the arguments (`MKT-019`); it computes `d` (`SPEC-ORC-005`) at the
/// listing valuation prices; requires `checkConfig == 0` and a Live evaluation of the configuration; and seeds the
/// accepted price, `seen`, the last routes and the checkpoint.
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-010, REQ-ORACLE-047, REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-076, REQ-ORACLE-088, SPEC-ORC-005, MKT-019
abstract contract LPOracleListingLogic is LPOracleLogicBase {
    /// @inheritdoc ILPOracleLogic
    function poke() external pure override returns (PriceState) {
        revert NotDelegated();
    }

    /// @inheritdoc ILPOracleLogic
    /// @custom:spec REQ-ORACLE-046
    function checkConfig(
        OracleConfig calldata config
    ) external view override returns (uint256 failedChecks) {
        failedChecks = _checkConfig(config);
    }

    /// @inheritdoc ILPOracleLogic
    /// @custom:spec REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-076, REQ-ORACLE-088
    function initializeMarket(
        InitParams calldata params
    ) external override onlyDelegated {
        _storeVaultDecimals(params.config);
        uint256 failed = _checkConfig(params.config);
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

    /// @dev `d`: the smallest decimals in `[6, 18]` whose whole token is worth at least $1 at the listing valuation
    /// prices (`SPEC-ORC-005`); reverts `ConfigCheckFailed` when no route quotes a token or no `d` exists.
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
        _s().vaultDecimals = d;
    }
}
// forge-lint: disable-end(reentrancy-events)
