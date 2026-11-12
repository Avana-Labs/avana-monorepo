// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice ParameterStore rows of the 2.15 restricted-function matrix that hold because a selector does not exist: no
/// approved/live split or restore path (REQ-ACCESS-042), no buy-leg parameters (REQ-ACCESS-151), no opening health
/// floor setter (REQ-ACCESS-180), no tighten selector for the USD band or the grace values (REQ-ACCESS-044) and no
/// setter for the implementation's liveness constants (REQ-ACCESS-101). Each absence is checked twice: a call from the
/// timelock reverts with no data (no function matched, so no role or bounds check ran), and no bytecode of the store,
/// its implementation or its five logic contracts pushes the selector.
contract ParameterStoreGovernanceRowsUnitTest is ParameterStoreFixture {
    bytes32 internal constant ADMIN = AvanaRoles.APPLICATION_ADMIN;
    bytes32 internal constant STEWARD = AvanaRoles.APPLICATION_RISK_STEWARD;
    address internal safe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _codes() internal view returns (address[7] memory) {
        return [
            address(store),
            address(implementation),
            logics.tighten,
            logics.loosen,
            logics.listing,
            logics.adminOracle,
            logics.adminRisk
        ];
    }

    /// @dev `sig` matches no function: the timelock's call reverts with empty data and no code pushes the selector.
    function _assertAbsent(
        string memory sig
    ) internal {
        bytes4 sel = bytes4(keccak256(bytes(sig)));
        vm.prank(address(timelock));
        (bool ok, bytes memory ret) = address(store).call(abi.encodePacked(sel, new bytes(128)));
        assertFalse(ok, sig);
        assertEq(ret.length, 0, sig);
        address[7] memory codes = _codes();
        for (uint256 j = 0; j < codes.length; ++j) {
            bytes memory code = codes[j].code;
            assertFalse(BytecodeInspector.pushesSelector(code, 0, code.length, sel), sig);
        }
    }

    // TEST-062 verifies: REQ-ACCESS-042
    function test_TEST_062_noRestoreSelectorAndOneValuePerParameter() public {
        _assertAbsent("restoreApproved(bytes32)");
        _assertAbsent("restoreApproved(bytes32,bytes32)");
        _assertAbsent("restoreApproved(uint256)");
        _assertAbsent("approvedValue(bytes32)");
        _assertAbsent("approvedValue(bytes32,bytes32)");
        // One value per parameter, the last one written: a tightening is undone by a loosening, not by a restore.
        _tl();
        store.tightenSlippageAllowanceBps(M, 60);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 60);
        _tl();
        store.loosenSlippageAllowanceBps(M, 85);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 85);
    }

    // TEST-062 verifies: REQ-ACCESS-151
    function test_TEST_062_noBuyLegParameterSelectors() public {
        _assertAbsent("tightenBuySlippageAllowanceBps(uint256,uint16)");
        _assertAbsent("tightenBuySlippageAllowanceBps(uint256,uint256)");
        _assertAbsent("setBuySlippageAllowanceMinBps(uint256,uint16)");
        _assertAbsent("setBuySlippageAllowanceMinBps(uint256,uint256)");
        _assertAbsent("buySlippageAllowanceMinBps(uint256)");
        _assertAbsent("tightenBuyRouteDepthThreshold(uint256,uint256)");
        _assertAbsent("loosenBuyRouteDepthThreshold(uint256,uint256)");
        _assertAbsent("tightenBuyRouteDepthThreshold(uint256,address,uint256)");
        _assertAbsent("loosenBuyRouteDepthThreshold(uint256,address,uint256)");
        // The one conversion leg is bounded by the market's slippage allowance and its swap-route depth thresholds.
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 100);
        _tl();
        store.tightenRouteDepthThreshold(M, usdc, gho, 0, 1_000_000e8);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 0), 1_000_000e8);
    }

    // TEST-062 verifies: REQ-ACCESS-180
    function test_TEST_062_noOpeningHealthFloorSetter() public {
        _assertAbsent("setMinOpeningHealthFactor(uint256)");
        _assertAbsent("setMinOpeningHealthFactor(uint256,uint256)");
        _assertAbsent("minOpeningHealthFactor(uint256)");
        _assertAbsent("setProxyHealthFactorFloor(uint256)");
        _assertAbsent("PROXY_HEALTH_FACTOR_FLOOR()");
        // The only on-chain floor is the optional per-market hard floor, off at listing; the grace value is unchanged.
        assertEq(store.hardHealthFloor(M), 0);
        assertEq(store.graceHealthFactor(), 0.95e18);
    }

    // TEST-063 verifies: REQ-ACCESS-044
    function test_TEST_063_bandAndGraceHaveNoTightenSelector() public {
        _assertAbsent("tightenUsdBand(uint256,uint256)");
        _assertAbsent("tightenUsdBandLow(uint256)");
        _assertAbsent("tightenUsdBandHigh(uint256)");
        _assertAbsent("tightenGraceDuration(uint32)");
        _assertAbsent("tightenGraceDuration(uint256)");
        _assertAbsent("tightenGraceHealthFactor(uint256)");
        // The risk steward reaches none of the four values, in either direction.
        vm.prank(address(timelock));
        store.grantRole(STEWARD, safe);
        bytes memory unauthorized =
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, ADMIN);
        bytes[3] memory stewardCalls = [
            abi.encodeCall(store.setUsdBand, (0.95e8, 1.01e8)),
            abi.encodeCall(store.setGraceDuration, (3600)),
            abi.encodeCall(store.setGraceHealthFactor, (0.97e18))
        ];
        for (uint256 i = 0; i < stewardCalls.length; ++i) {
            vm.prank(safe);
            (bool ok, bytes memory ret) = address(store).call(stewardCalls[i]);
            assertFalse(ok, "steward moved a band or grace value");
            assertEq(ret, unauthorized);
        }
        // The timelock moves each of them both ways through the one setter.
        vm.startPrank(address(timelock));
        store.setUsdBand(0.95e8, 1.01e8);
        store.setUsdBand(0.9e8, 1.02e8);
        store.setGraceDuration(600);
        store.setGraceDuration(3600);
        store.setGraceHealthFactor(0.92e18);
        store.setGraceHealthFactor(0.97e18);
        vm.stopPrank();
        assertEq(store.usdBandLow(), 0.9e8);
        assertEq(store.usdBandHigh(), 1.02e8);
        assertEq(store.graceDuration(), 3600);
        assertEq(store.graceHealthFactor(), 0.97e18);
    }

    // TEST-062 verifies: REQ-ACCESS-101, REQ-ACCESS-067
    function test_TEST_062_livenessConstantsHaveNoSetter() public {
        _assertAbsent("setGraceHealthFactorMin(uint256)");
        _assertAbsent("setGraceDurationMax(uint32)");
        _assertAbsent("setGraceDurationMax(uint256)");
        _assertAbsent("setConsistencyToleranceMinBps(uint16)");
        _assertAbsent("setConsistencyToleranceMinBps(uint256)");
        _assertAbsent("setConsistencyToleranceMinBps(uint256,uint16)");
        // The bounds are code of the implementation, not storage: the uninitialized implementation reports them too.
        IParameterStore impl = IParameterStore(address(implementation));
        assertEq(impl.graceHealthFactorMin(), 0.9e18);
        assertEq(impl.graceDurationMax(), 7200);
        assertEq(impl.consistencyToleranceMinBps(), 10);
        // One value for every market, unchanged by writing the bounded values at their limits.
        vm.startPrank(address(timelock));
        store.setGraceHealthFactor(0.9e18);
        store.setGraceDuration(7200);
        store.setConsistencyToleranceBps(M, 10);
        vm.stopPrank();
        assertEq(store.graceHealthFactorMin(), 0.9e18);
        assertEq(store.graceDurationMax(), 7200);
        assertEq(store.consistencyToleranceMinBps(), 10);
    }
}
