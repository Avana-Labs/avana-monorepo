// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {ParameterStoreAdminRiskLogic} from "../../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../../src/types/SecondSourceKind.sol";
import {MockAggregator} from "../../utils/mocks/ParameterStoreMocks.sol";
import {ParameterStoreHarnessBase} from "./ParameterStoreHarnessBase.sol";

/// @title ParameterStoreAdminRiskProperties
/// @notice Echidna and Medusa properties of the ParameterStore's second-source and fee setters on an L2 (grace 1,800
/// s): whatever sequence of second-source records, guardian switches, restores and LPOracle failures runs, no recorded
/// or standby pool-TWAP source of a market token reads the market's own pool (REQ-PSTORE-028), every window fits the
/// grace (REQ-PSTORE-034), an empty standby has every field zero and is never in force (REQ-PSTORE-029), the switch
/// succeeds only while the LPOracle accepts the standby, and Avana's fee share stays within 5,000 bps.
contract ParameterStoreAdminRiskProperties is ParameterStoreHarnessBase {
    uint32 internal constant GRACE = 1800;

    address internal immutable ADMIN_RISK;
    MockAggregator internal immutable NET_A;
    MockAggregator internal immutable NET_B;

    constructor() ParameterStoreHarnessBase(true) {
        ADMIN_RISK = address(new ParameterStoreAdminRiskLogic(address(this), address(_REGISTRY), 12, true));
        NET_A = new MockAggregator(8, 1e6, 1e12);
        NET_B = new MockAggregator(8, 1e6, 1e12);
        Layout storage $ = _s();
        $.feeds[address(NET_A)].decimals = 8;
        $.feeds[address(NET_B)].decimals = 8;
        $.sequencer.gracePeriod = GRACE;
        $.g.avanaFeeShareBps = 2000;
    }

    // ─── Properties ───

    function property_noSourceReadsTheOwnPool() external view returns (bool) {
        Layout storage $ = _s();
        return !_readsOwnPool($.secondSource[USDC]) && !_readsOwnPool($.standby[USDC])
            && !_readsOwnPool($.secondSource[USDT]) && !_readsOwnPool($.standby[USDT]);
    }

    function property_windowsWithinGrace() external view returns (bool) {
        return _windowsFitGrace();
    }

    function property_emptyStandbyIsZeroAndNeverInForce() external view returns (bool) {
        SecondSource storage b = _s().standby[USDC];
        if (b.kind != SecondSourceKind.None) return true;
        return !_s().onStandby[USDC] && b.source == address(0) && b.poolRef == bytes32(0) && b.maxAge == 0
            && b.twapWindow == 0 && b.toleranceBps == 0;
    }

    function property_feeShareInRange() external view returns (bool) {
        return _s().g.avanaFeeShareBps <= 5000;
    }

    // ─── Assertion entry points ───

    /// @dev Concrete source forms: 0 and 1 the two oracle networks, 2 a pool TWAP of another pool, 3 a pool TWAP of
    /// the market's own pool, 4 a pool TWAP through another reader, 5 the empty source, 6 an empty source with a
    /// field set.
    function _form(
        uint256 which,
        uint32 window
    ) internal view returns (SecondSource memory s) {
        which %= 7;
        if (which == 0) {
            return SecondSource(SecondSourceKind.OracleNetwork, address(NET_A), bytes32(0), 88_200, 0, 100);
        }
        if (which == 1) {
            return SecondSource(SecondSourceKind.OracleNetwork, address(NET_B), bytes32(0), 88_200, 0, 100);
        }
        if (which == 2) {
            return SecondSource(SecondSourceKind.PoolTwap, address(INTEGRATION), bytes32(uint256(7)), 0, window, 120);
        }
        if (which == 3) {
            bytes32 own = bytes32(uint256(uint160(address(POOL))));
            return SecondSource(SecondSourceKind.PoolTwap, address(INTEGRATION), own, 0, window, 120);
        }
        if (which == 4) {
            return SecondSource(SecondSourceKind.PoolTwap, address(POOL), bytes32(uint256(9)), 0, window, 120);
        }
        if (which == 6) s.toleranceBps = 1;
    }

    function setSecondSource(
        uint8 src,
        uint8 standby,
        uint32 window
    ) external {
        SecondSource memory s = _form(src, window);
        SecondSource memory b = _form(standby, window);
        bool ok = _call(ADMIN_RISK, abi.encodeCall(IParameterStoreAdmin.setSecondSource, (USDC, s, b)));
        if (ok) {
            assert(s.kind != SecondSourceKind.None && !_onPool(s) && !_onPool(b));
            assert(s.twapWindow <= GRACE && b.twapWindow <= GRACE && ORACLE.failed() == 0);
            assert(b.kind != SecondSourceKind.None || b.toleranceBps == 0);
            assert(!_s().onStandby[USDC]);
        }
        if (src % 7 == 3 || standby % 7 == 3 || standby % 7 == 6) assert(!ok);
    }

    function useStandby() external {
        bool before = _s().onStandby[USDC];
        bool ok = _call(ADMIN_RISK, abi.encodeCall(IParameterStoreAdmin.useStandbySecondSource, (USDC)));
        if (ok) assert(!before && _s().onStandby[USDC] && ORACLE.failed() == 0);
        if (ORACLE.failed() != 0) assert(!ok && _s().onStandby[USDC] == before);
    }

    function restore() external {
        bool ok = _call(ADMIN_RISK, abi.encodeCall(IParameterStoreAdmin.restoreSecondSource, (USDC)));
        if (ok) assert(!_s().onStandby[USDC]);
    }

    function setFeeShare(
        uint16 value
    ) external {
        bool ok = _call(ADMIN_RISK, abi.encodeCall(IParameterStoreAdmin.setAvanaFeeShareBps, (value)));
        assert(ok == (value <= 5000));
    }

    function _onPool(
        SecondSource memory s
    ) internal view returns (bool) {
        return s.kind == SecondSourceKind.PoolTwap && s.poolRef == bytes32(uint256(uint160(address(POOL))));
    }
}
