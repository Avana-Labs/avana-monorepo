// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice ParameterStore rows of the 2.15 restricted-function matrix that hold because a selector does not exist: no
/// approved/live split or restore path (REQ-ACCESS-042), no buy-leg parameters (REQ-ACCESS-151), no opening health
/// floor setter (REQ-ACCESS-180). Each absence is checked twice: a call from the timelock reverts with no data (no
/// function matched, so no role or bounds check ran), and no bytecode of the store, its implementation or its five
/// logic contracts pushes the selector.
contract ParameterStoreGovernanceRowsUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore();
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
    }
}
