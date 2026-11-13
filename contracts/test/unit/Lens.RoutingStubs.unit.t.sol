// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILens} from "../../src/lens/lens/ILens.sol";
import {ILensActions} from "../../src/lens/lens/ILensActions.sol";
import {ILensFees} from "../../src/lens/lens/ILensFees.sol";
import {ILensHubAssets} from "../../src/lens/lens/ILensHubAssets.sol";
import {ILensSizing} from "../../src/lens/lens/ILensSizing.sol";
import {ILensSpeed} from "../../src/lens/lens/ILensSpeed.sol";
import {Lens} from "../../src/lens/lens/Lens.sol";
import {LensModuleStub, LensProperties} from "../invariant/echidna/LensProperties.sol";
import {Test} from "forge-std/Test.sol";

/// @title LensRoutingStubsUnitTest
/// @notice With nine stand-in modules that answer with their own index and the calldata hash, every view added for the
/// app reaches the module the Storage table names with its calldata unchanged, and a reverting module's data comes back
/// unchanged; the Echidna routing property holds for every representative.
contract LensRoutingStubsUnitTest is Test {
    Lens internal lens;
    Lens internal reverting;

    function setUp() public {
        address[9] memory m;
        address[9] memory r;
        for (uint256 i = 0; i < 9; ++i) {
            m[i] = address(new LensModuleStub(i, false));
            r[i] = address(new LensModuleStub(i, true));
        }
        lens = new Lens(m);
        reverting = new Lens(r);
    }

    function _route(
        bytes memory data,
        uint256 expected
    ) internal view {
        (bool ok, bytes memory ret) = address(lens).staticcall(data);
        assertTrue(ok, "answered");
        assertEq(ret, abi.encode(expected, keccak256(data)), "the expected module, calldata unchanged");
        (ok, ret) = address(reverting).staticcall(data);
        assertFalse(ok, "reverted");
        assertEq(ret, abi.encode(expected, keccak256(data)), "revert data unchanged");
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-050, REQ-LENS-051, REQ-LENS-052, REQ-LENS-053
    function test_TEST_247_feesAndActionsReachTheirModules() public view {
        address w = address(0xA11CE);
        _route(abi.encodeCall(ILensFees.getPositionFees, (4, bytes32(uint256(7)))), 6);
        _route(abi.encodeCall(ILensFees.getAccountFees, (w, 4)), 6);
        _route(abi.encodeCall(ILensActions.previewBorrowAfter, (w, 4, 2, 1e18)), 7);
        _route(abi.encodeCall(ILensActions.previewRepayAfter, (w, 4, 2, 1e18)), 7);
        _route(abi.encodeCall(ILensActions.previewPledgeAfter, (w, 4, bytes32(uint256(9)))), 7);
        _route(abi.encodeCall(ILensActions.previewWithdrawAfter, (w, 4, bytes32(uint256(9)))), 7);
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-054, REQ-LENS-055, REQ-LENS-056, REQ-LENS-058
    function test_TEST_247_sizingAndHubAssetReachTheirModules() public view {
        address w = address(0xB0B);
        _route(abi.encodeCall(ILensSizing.previewMaxWithdraw, (w, 4, 1.2e18)), 7);
        _route(abi.encodeCall(ILensSizing.previewDeleverageTo, (w, 4, bytes32(uint256(1)), 2, 1.5e18)), 2);
        _route(abi.encodeCall(ILensSizing.previewCloseAccount, (w, 4, 1_800_000_000)), 0);
        _route(abi.encodeCall(ILensHubAssets.getHubAsset, (address(0x4B), 3)), 4);
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-061
    function test_TEST_247_speedViewsReachTheSpeedModule() public view {
        _route(abi.encodeCall(ILensSpeed.getBorrowSpeed, (4, 2)), 8);
        _route(abi.encodeCall(ILensSpeed.getPledgeSpeed, (4)), 8);
    }

    // TEST-247 verifies: REQ-LENS-001
    function test_TEST_247_echidnaRoutingPropertyHolds() public {
        LensProperties p = new LensProperties();
        for (uint8 which = 0; which < 16; ++which) {
            p.checkRoute(which, uint256(which) * 7919);
            p.checkRouteAdded(which, uint256(which) * 104_729);
        }
        assertTrue(p.property_coreAndModules(), "core and modules");
        assertEq(ILens(address(lens)).MODULES().length, 9, "nine modules");
    }
}
