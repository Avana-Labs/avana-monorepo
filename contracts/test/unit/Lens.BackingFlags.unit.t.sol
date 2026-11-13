// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingView} from "../../src/lens/lens/types/BackingView.sol";
import {WithdrawPreview} from "../../src/lens/lens/types/WithdrawPreview.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensBackingFlagsUnitTest
/// @notice The configuration flags of `checkBacking` that a drifted Aave listing turns false (a draw cap on the vault
/// token, a liquidation fee on an older dynamic configuration key, a borrowable or share-receiving reserve), and the
/// withdrawal preview's gate against the latest collateral factor and the market's hard floor.
/// forge-config: default.isolate = false
contract LensBackingFlagsUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    function _spokeCall(
        string memory sig,
        uint256 value
    ) internal {
        _spokeConfig(abi.encodeWithSignature(sig, aave.cdpSpoke, vtReserveId, value));
    }

    // ─── checkBacking ───

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-013
    function test_TEST_247_healthyListingPassesEveryFlag() public view {
        BackingView memory b = lens.checkBacking(vt);
        assertTrue(b.noDrawCap, "no draw cap");
        assertTrue(b.reserveFlags, "standard-Spoke settings");
        assertTrue(b.supplyEqualsCredited, "supply = credited");
        assertEq(b.stranded, 0, "nothing stranded");
    }

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-013
    function test_TEST_247_aDrawCapOnTheVaultTokenFailsNoDrawCap() public {
        _setDrawCap(vtAssetId, aave.cdpSpoke, 1);
        BackingView memory b = lens.checkBacking(vt);
        assertFalse(b.noDrawCap, "a Spoke could draw vault tokens");
        _setDrawCap(vtAssetId, aave.cdpSpoke, 0);
        assertTrue(lens.checkBacking(vt).noDrawCap, "restored");
    }

    // TEST-247 verifies: REQ-LENS-012, REQ-LENS-013
    function test_TEST_247_aLiquidationFeeOnAnyKeyFailsReserveFlags() public {
        _spokeCall("addLiquidationFee(address,uint256,uint256)", 100);
        assertFalse(lens.checkBacking(vt).reserveFlags, "the latest key charges a fee");
        // A newer key back at 0 still leaves the older key's fee for accounts that hold it.
        _spokeCall("addLiquidationFee(address,uint256,uint256)", 0);
        assertFalse(lens.checkBacking(vt).reserveFlags, "an older key still charges it");
    }

    // TEST-247 verifies: REQ-LENS-012
    function test_TEST_247_borrowableOrShareReceivingReserveFailsReserveFlags() public {
        _spokeConfig(
            abi.encodeWithSignature("updateBorrowable(address,uint256,bool)", aave.cdpSpoke, vtReserveId, true)
        );
        assertFalse(lens.checkBacking(vt).reserveFlags, "borrowable");
        _spokeConfig(
            abi.encodeWithSignature("updateBorrowable(address,uint256,bool)", aave.cdpSpoke, vtReserveId, false)
        );
        assertTrue(lens.checkBacking(vt).reserveFlags, "back to the standard settings");
        _spokeConfig(
            abi.encodeWithSignature(
                "updateReceiveSharesEnabled(address,uint256,bool)", aave.cdpSpoke, vtReserveId, true
            )
        );
        assertFalse(lens.checkBacking(vt).reserveFlags, "receive shares enabled");
    }

    // ─── previewWithdraw against the latest collateral factor ───

    // TEST-247 verifies: REQ-LENS-049
    function test_TEST_247_withdrawPreviewUsesTheLatestFactor() public {
        _pledge(alice, aliceProxy, _key(2), 6000e6);
        _borrow(aliceProxy, 7000e18);
        _spokeCall("addCollateralFactor(address,uint256,uint16)", 6000);
        WithdrawPreview memory w = lens.previewWithdraw(alice, MARKET_ID, _key(2), 0);
        // 10,000 tokens x $2 x 0.6 / 7,000 GHO: the withdrawal moves the account from 80 % to 60 %.
        assertEq(w.healthFactorAfter, uint256(12_000e18) / 7000, "HF at the latest 60 %");
        assertTrue(w.allowed, "1.714 >= 1.00");
        _withdraw(aliceProxy, _key(2), 6000e6);
        assertEq(_hf(aliceProxy), w.healthFactorAfter, "Aave agrees");
    }

    // TEST-247 verifies: REQ-LENS-049
    function test_TEST_247_withdrawPreviewRefusedByTheLatestFactor() public {
        _pledge(alice, aliceProxy, _key(2), 6000e6);
        _borrow(aliceProxy, 11_000e18);
        // At the account's own 80 % the withdrawal would pass (16,000 / 11,000); at the latest 50 % it would not.
        _spokeCall("addCollateralFactor(address,uint256,uint16)", 5000);
        WithdrawPreview memory w = lens.previewWithdraw(alice, MARKET_ID, _key(2), 0);
        assertLt(w.healthFactorAfter, 1e18, "10,000 / 11,000");
        assertFalse(w.allowed, "Aave would refuse it");
    }

    // TEST-247 verifies: REQ-LENS-049, Q-398
    function test_TEST_247_withdrawPreviewHardFloorAndOversizedUnits() public {
        _pledge(alice, aliceProxy, _key(2), 6000e6);
        _borrow(aliceProxy, 10_000e18);
        assertTrue(lens.previewWithdraw(alice, MARKET_ID, _key(2), 0).allowed, "1.60 >= 1.00");
        store.setHardHealthFloor(MARKET_ID, 1.7e18);
        WithdrawPreview memory w = lens.previewWithdraw(alice, MARKET_ID, _key(2), 0);
        assertEq(w.healthFactorAfter, 1.6e18, "16,000 / 10,000");
        assertFalse(w.allowed, "below the market's hard floor");
        store.setHardHealthFloor(MARKET_ID, 1.6e18);
        assertTrue(lens.previewWithdraw(alice, MARKET_ID, _key(2), 0).allowed, "exactly at the floor");
        w = lens.previewWithdraw(alice, MARKET_ID, _key(2), 6000e6 + 1);
        assertFalse(w.allowed, "more than the record's credited units");
        assertEq(w.units, 6000e6 + 1, "the units asked");
    }
}
