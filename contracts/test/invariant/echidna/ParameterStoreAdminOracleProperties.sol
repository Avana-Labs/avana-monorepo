// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {ParameterStoreAdminOracleLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreHarnessBase} from "./ParameterStoreHarnessBase.sol";

/// @title ParameterStoreAdminOracleProperties
/// @notice Echidna and Medusa properties of the ParameterStore's oracle-configuration setters on an L2: the market's
/// TWAP window stays non-zero and within the 3,600-second sequencer grace (REQ-PSTORE-034, REQ-PSTORE-027), the USD
/// band brackets $1, the cached window and grace values stay in range, and each setter succeeds exactly when its
/// predicate holds and the LPOracle's `checkConfig` passes.
contract ParameterStoreAdminOracleProperties is ParameterStoreHarnessBase {
    address internal immutable ADMIN_ORACLE;

    constructor() ParameterStoreHarnessBase(true) {
        ADMIN_ORACLE = address(new ParameterStoreAdminOracleLogic(address(this), address(_REGISTRY), 12, true));
        _s().sequencer.gracePeriod = 3600;
        _s().market[M].twapWindow = 1800;
        _s().g.graceDuration = 1800;
    }

    // ─── Properties ───

    function property_windowWithinGrace() external view returns (bool) {
        return _windowsFitGrace() && _s().market[M].twapWindow != 0;
    }

    function property_usdBandAroundOneDollar() external view returns (bool) {
        return _s().g.usdBandLow < 1e8 && _s().g.usdBandHigh > 1e8;
    }

    function property_chainValuesInRange() external view returns (bool) {
        return _s().g.cachedWindow != 0 && _s().g.graceDuration <= 7200 && _s().g.disagreementPauseMax <= 3600;
    }

    // ─── Assertion entry points ───

    function setTwapWindow(
        uint32 window
    ) external {
        bool ok = _call(ADMIN_ORACLE, abi.encodeCall(IParameterStoreAdmin.setTwapWindow, (M, window)));
        assert(ok == (window != 0 && window <= 3600 && ORACLE.failed() == 0));
    }

    function setUsdBand(
        uint256 low,
        uint256 high
    ) external {
        bool ok = _call(ADMIN_ORACLE, abi.encodeCall(IParameterStoreAdmin.setUsdBand, (low, high)));
        assert(ok == (low < 1e8 && high > 1e8 && ORACLE.failed() == 0));
    }

    function setCachedWindow(
        uint32 value
    ) external {
        bool ok = _call(ADMIN_ORACLE, abi.encodeCall(IParameterStoreAdmin.setCachedWindow, (value)));
        assert(ok == (value != 0 && ORACLE.failed() == 0));
    }

    function setGraceDuration(
        uint32 value
    ) external {
        bool ok = _call(ADMIN_ORACLE, abi.encodeCall(IParameterStoreAdmin.setGraceDuration, (value)));
        assert(ok == (value <= 7200 && ORACLE.failed() == 0));
    }

    function setDisagreementPauseMax(
        uint32 value
    ) external {
        bool ok = _call(ADMIN_ORACLE, abi.encodeCall(IParameterStoreAdmin.setDisagreementPauseMax, (value)));
        assert(ok == (value <= 3600 && ORACLE.failed() == 0));
    }
}
