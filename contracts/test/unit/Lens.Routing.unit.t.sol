// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensActions} from "../../src/lens/lens/ILensActions.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {ILensFees} from "../../src/lens/lens/ILensFees.sol";
import {ILensHubAssets} from "../../src/lens/lens/ILensHubAssets.sol";
import {ILensMarkets} from "../../src/lens/lens/ILensMarkets.sol";
import {ILensSizing} from "../../src/lens/lens/ILensSizing.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensRoutingUnitTest
/// @notice The views added to the Lens are served by the module the Storage table names: the entry point returns the
/// module's answer and revert data byte for byte, every other module does not answer them, and each module refuses
/// them while the Lock is held when called directly.
/// forge-config: default.isolate = false
contract LensRoutingUnitTest is LensFixture {
    uint256 internal constant ACCOUNT = 0;
    uint256 internal constant PRICE = 2;
    uint256 internal constant RISK = 4;
    uint256 internal constant MARKETS = 6;
    uint256 internal constant POSITIONS = 7;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
        _borrow(aliceProxy, 6000e18);
    }

    function _calls() internal view returns (bytes[] memory c, uint256[] memory m) {
        c = new bytes[](11);
        m = new uint256[](11);
        (c[0], m[0]) = (abi.encodeCall(ILensFees.getAccountFees, (bob, MARKET_ID)), MARKETS);
        (c[1], m[1]) =
        (abi.encodeCall(ILensActions.previewBorrowAfter, (alice, MARKET_ID, debtReserveId, 1e18)), POSITIONS);
        (c[2], m[2]) =
        (abi.encodeCall(ILensActions.previewRepayAfter, (alice, MARKET_ID, debtReserveId, 1e18)), POSITIONS);
        (c[3], m[3]) = (abi.encodeCall(ILensActions.previewWithdrawAfter, (alice, MARKET_ID, _key(1))), POSITIONS);
        (c[4], m[4]) = (abi.encodeCall(ILensSizing.previewMaxWithdraw, (alice, MARKET_ID, 1.2e18)), POSITIONS);
        (c[5], m[5]) =
        (abi.encodeCall(ILensSizing.previewDeleverageTo, (alice, MARKET_ID, _key(1), debtReserveId, 3e18)), PRICE);
        (c[6], m[6]) = (abi.encodeCall(ILensSizing.previewCloseAccount, (alice, MARKET_ID, T0 + 600)), ACCOUNT);
        (c[7], m[7]) = (abi.encodeCall(ILensHubAssets.getHubAsset, (aave.hub, ghoAssetId)), RISK);
        (c[8], m[8]) = (abi.encodeCall(ILensMarkets.getMarket, (MARKET_ID)), MARKETS);
        (c[9], m[9]) = (abi.encodeCall(ILensHubAssets.getHubAsset, (aave.hub, vtAssetId)), RISK);
        (c[10], m[10]) = (abi.encodeCall(ILensActions.previewPledgeAfter, (bob, MARKET_ID, _key(1))), POSITIONS);
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-050, REQ-LENS-052, REQ-LENS-054, REQ-LENS-055, REQ-LENS-056, REQ-LENS-058
    function test_TEST_247_newViewsAreServedByTheirModules() public view {
        (bytes[] memory c, uint256[] memory m) = _calls();
        for (uint256 i = 0; i < c.length; ++i) {
            (bool okLens, bytes memory viaLens) = address(lens).staticcall(c[i]);
            (bool okModule, bytes memory direct) = modules[m[i]].staticcall(c[i]);
            assertEq(okLens, okModule, "same outcome");
            assertEq(keccak256(viaLens), keccak256(direct), "same bytes");
            for (uint256 j = 0; j < 8; ++j) {
                if (j == m[i]) continue;
                (bool other,) = modules[j].staticcall(c[i]);
                assertFalse(other, "no other module answers");
            }
        }
    }

    // TEST-247 verifies: REQ-LENS-001, REQ-LENS-007, REQ-LENS-053
    function test_TEST_247_revertDataPassesThroughUnchanged() public view {
        // Bob owns no position 1: the integration's error comes back unchanged through the entry point.
        (, bytes memory viaLens) =
            address(lens).staticcall(abi.encodeCall(ILensActions.previewPledgeAfter, (bob, MARKET_ID, _key(1))));
        (, bytes memory direct) =
            modules[POSITIONS].staticcall(abi.encodeCall(ILensActions.previewPledgeAfter, (bob, MARKET_ID, _key(1))));
        assertEq(viaLens, direct, "same revert data");
        assertGt(viaLens.length, 0, "a reason");
        (, viaLens) = address(lens).staticcall(abi.encodeCall(ILensHubAssets.getHubAsset, (aave.hub, 500)));
        assertEq(
            viaLens, abi.encodeWithSelector(ILensErrors.UnknownHubAsset.selector, aave.hub, 500), "UnknownHubAsset"
        );
    }

    // TEST-247 verifies: REQ-LENS-006, REQ-LENS-021
    function test_TEST_247_everyModuleRefusesTheNewViewsWhileLocked() public {
        (bytes[] memory c, uint256[] memory m) = _calls();
        _holdLock();
        for (uint256 i = 0; i < c.length; ++i) {
            (bool ok, bytes memory ret) = modules[m[i]].staticcall(c[i]);
            assertFalse(ok, "refused");
            assertEq(ret, abi.encodeWithSelector(ILensErrors.Locked.selector), "Locked()");
            (ok, ret) = address(lens).staticcall(c[i]);
            assertEq(ret, abi.encodeWithSelector(ILensErrors.Locked.selector), "Locked() through the Lens");
        }
    }
}
