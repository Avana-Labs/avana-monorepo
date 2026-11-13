// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensRemovalUncountedUnitTest
/// @notice `previewMaxWithdraw` with debt open when the vault tokens count for nothing on the real Aave V4 Spoke: the
/// vault-token reserve is not used as collateral (USDC backs the loan), or its latest collateral factor is 0. Either
/// way nothing is counted and `maxUnits` is 0.
/// forge-config: default.isolate = false
contract LensRemovalUncountedUnitTest is LensFixture {
    IAaveV4Spoke internal spoke;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
        spoke = IAaveV4Spoke(aave.cdpSpoke);
    }

    /// @dev The proxy supplies `amount` USDC on the CDP Spoke as collateral (USDC at CF 80 %).
    function _usdcCollateral(
        uint256 amount
    ) internal {
        _spokeConfig(
            abi.encodeWithSignature("addCollateralFactor(address,uint256,uint16)", aave.cdpSpoke, usdcReserveId, 8000)
        );
        _setAddCap(usdcAssetId, aave.cdpSpoke, 1_000_000);
        usdc.mint(aliceProxy, amount);
        vm.startPrank(aliceProxy);
        usdc.approve(aave.cdpSpoke, amount);
        spoke.supply(usdcReserveId, amount, aliceProxy);
        spoke.setUsingAsCollateral(usdcReserveId, true, aliceProxy);
        vm.stopPrank();
    }

    /// @notice 5,000 USDC at CF 80 % back a 1,000 GHO loan and the proxy turns its 10,000 vault tokens off as
    /// collateral. With debt open the vault tokens are not counted (`assets = 0`), so `maxUnits` is 0: the 10,000
    /// record does not fit and no record is best, while the target is still raised to the floor of 1.00.
    // TEST-247 verifies: REQ-LENS-054
    function test_TEST_247_maxWithdrawVaultTokenNotCollateralCountsNothing() public {
        _usdcCollateral(5000e6);
        _borrow(aliceProxy, 1000e18);
        vm.prank(aliceProxy);
        spoke.setUsingAsCollateral(vtReserveId, false, aliceProxy);
        (bool enabled,) = spoke.getUserReserveStatus(vtReserveId, aliceProxy);
        assertFalse(enabled, "the vault token is not collateral");
        assertGt(spoke.getUserAccountData(aliceProxy).totalDebtValueRay, 0, "debt open");

        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 0.5e18);
        assertEq(s.proxy, aliceProxy, "proxy");
        assertEq(s.target, 1e18, "with debt the target is at least 1.00");
        assertEq(s.maxUnits, 0, "nothing counted: no removal bound");
        assertEq(s.records.length, 1, "one record");
        assertEq(s.records[0].units, 10_000e6, "the record's units");
        assertFalse(s.records[0].fits, "the record does not fit");
        assertEq(s.bestIndex, type(uint256).max, "none fits");

        vm.prank(aliceProxy);
        spoke.setUsingAsCollateral(vtReserveId, true, aliceProxy);
        assertGt(lens.previewMaxWithdraw(alice, MARKET_ID, 1e18).maxUnits, 0, "counted again once it is collateral");
    }

    /// @notice 10,000 vault tokens at $2.00 back 1,000 GHO, then the reserve's latest collateral factor becomes 0. The
    /// withdrawal moves the account to that factor, so `per = $2 × 10¹² × 0 = 0` and `maxUnits` is 0; at 50 % the same
    /// account may remove `(0.5 × 20,000 − 1,000) / (0.5 × 2) = 9,000` vault tokens.
    // TEST-247 verifies: REQ-LENS-054, SPEC-CF-005
    function test_TEST_247_maxWithdrawLatestFactorZeroCountsNothing() public {
        _borrow(aliceProxy, 1000e18);
        _spokeConfig(
            abi.encodeWithSignature("addCollateralFactor(address,uint256,uint16)", aave.cdpSpoke, vtReserveId, 5000)
        );
        assertEq(lens.previewMaxWithdraw(alice, MARKET_ID, 1e18).maxUnits, 9000e6, "latest 50 %: 9,000");

        _spokeConfig(
            abi.encodeWithSignature("addCollateralFactor(address,uint256,uint16)", aave.cdpSpoke, vtReserveId, 0)
        );
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, 1e18);
        assertEq(s.target, 1e18, "target");
        assertEq(s.maxUnits, 0, "a latest factor of 0 counts nothing");
        assertFalse(s.records[0].fits, "the record does not fit");
        assertEq(s.bestIndex, type(uint256).max, "none fits");
    }
}
