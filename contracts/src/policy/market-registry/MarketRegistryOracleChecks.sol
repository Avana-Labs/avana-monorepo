// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {PriceState} from "../../types/PriceState.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";

/// @title MarketRegistryOracleChecks
/// @notice LPOracle checks for setPriceSource and activation: `checkConfig` on its stored config, and Live state.
/// @dev The configuration bytes are forwarded undecoded; decoding the struct would exceed the stack.
// The LPOracle configuration check runs per market in setPriceSource's loop; static calls only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryOracleChecks is MarketRegistryStorage {
    /// @dev True when the LPOracle's `checkConfig` returns 0 for its stored configuration; any failed call fails.
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

    /// @dev True when the LPOracle reports `Live`. The first word is the struct offset; the second is the state.
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
