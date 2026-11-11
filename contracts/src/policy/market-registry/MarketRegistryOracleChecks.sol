// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {PriceState} from "../../types/PriceState.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";

/// @title MarketRegistryOracleChecks
/// @notice The LPOracle checks of setPriceSource and activation: the oracle's `checkConfig` on the configuration the
/// ParameterStore serves it, and its price state.
/// @dev Both are static calls. The configuration is passed through as the ParameterStore returns it, without decoding:
/// the ABI encoding of a `returns (OracleConfig memory)` value is exactly the argument encoding of
/// `checkConfig(OracleConfig)`, and decoding the struct into memory exceeds the legacy pipeline's stack.
/// @custom:spec REQ-CONFIG-027, REQ-CONFIG-047, REQ-CONFIG-038
// The LPOracle configuration check runs per market in setPriceSource's loop; static calls only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryOracleChecks is MarketRegistryStorage {
    /// @dev True when the ParameterStore serves the LPOracle a configuration and the LPOracle's `checkConfig` returns
    /// 0 for it; any failed call counts as a failed check.
    function _oracleConfigPasses(
        address lpOracle
    ) internal view returns (bool) {
        (bool ok, bytes memory cfg) =
            _PARAMETER_STORE.staticcall(abi.encodeCall(IParameterStoreViews.getOracleConfig, (lpOracle)));
        if (!ok) return false;
        bytes memory ret;
        (ok, ret) = lpOracle.staticcall(bytes.concat(ILPOracle.checkConfig.selector, cfg));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 0;
    }

    /// @dev True when the LPOracle reports `Live`. The report's first head word is the offset of the struct (it holds
    /// a dynamic array) and the struct's first field is the state.
    function _oracleLive(
        address lpOracle
    ) internal view returns (bool) {
        (bool ok, bytes memory ret) = lpOracle.staticcall(abi.encodeCall(ILPOracle.getPriceState, ()));
        if (!ok || ret.length < 64) return false;
        (, uint256 state) = abi.decode(ret, (uint256, uint256));
        return state == uint256(PriceState.Live);
    }
}
// forge-lint: disable-end(calls-loop)
