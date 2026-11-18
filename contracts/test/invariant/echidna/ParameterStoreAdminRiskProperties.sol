// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {ParameterStoreAdminRiskLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreHarnessBase} from "./ParameterStoreHarnessBase.sol";

/// @title ParameterStoreAdminRiskProperties
/// @notice Echidna and Medusa properties of the ParameterStore's fee setter: whatever sequence of fee-share writes
/// runs, Avana's fee share stays within 5,000 bps and a write succeeds exactly within it.
contract ParameterStoreAdminRiskProperties is ParameterStoreHarnessBase {
    address internal immutable ADMIN_RISK;

    constructor() ParameterStoreHarnessBase() {
        ADMIN_RISK = address(new ParameterStoreAdminRiskLogic(address(this), address(_REGISTRY), 12));
        _s().g.avanaFeeShareBps = 2000;
    }

    // ─── Properties ───

    function property_feeShareInRange() external view returns (bool) {
        return _s().g.avanaFeeShareBps <= 5000;
    }

    // ─── Assertion entry points ───

    function setFeeShare(
        uint16 value
    ) external {
        bool ok = _call(ADMIN_RISK, abi.encodeCall(IParameterStore.setAvanaFeeShareBps, (value)));
        assert(ok == (value <= 5000));
    }
}
