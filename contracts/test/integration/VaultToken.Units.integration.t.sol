// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {VaultTokenAaveV4Base} from "./VaultToken.AaveV4.integration.t.sol";

/// @dev Hub error of aave-v4 a3ef63e raised when a supply would take the asset's added assets above the Spoke's cap.
interface IHubAddCapError {
    error AddCapExceeded(uint256 addCap);
}

/// @title VaultTokenUnitsIntegrationTest
/// @notice The 2.4 unit rules on the real local Aave V4 with a 6-decimal full-range USDC/USDT vault token listed at
/// `addCap = 5,500,000` whole tokens: Aave values `n` base units at `n · price8 · 10^(18 − d)` (`SPEC-UNIT-004`), one
/// `addCap` unit is one whole token of `10^d` base units (`SPEC-UNIT-005`), and the cap bounds what the Hub holds far
/// below `2^120` (`SPEC-UNIT-006`).
/// @dev The AaveAdapter is a pranked address (its contract comes later); the proxy is a pranked registered address.
contract VaultTokenUnitsIntegrationTest is VaultTokenAaveV4Base {
    uint256 internal constant ADD_CAP = 5_500_000; // whole tokens, as listed in `_listReserves`
    uint256 internal constant CAP_UNITS = ADD_CAP * 10 ** VT_DECIMALS;

    function _supplyMore(
        uint256 units
    ) internal {
        vm.startPrank(adapter);
        if (!token.isValidProxy(proxy)) token.addValidProxy(proxy);
        token.mint(proxy, units);
        vm.stopPrank();
        vm.startPrank(proxy);
        token.approve(aave.cdpSpoke, units);
        IAaveV4Spoke(aave.cdpSpoke).supply(vtReserveId, units, proxy);
        vm.stopPrank();
    }

    /// @notice The 2.4 example: 5,000,000,000 base units at `price8 = 200,000,000` are worth $10,000.00000000
    /// (`n · price8 / 10^d = 10^12` in 8 decimals); Aave's own value is `n · price8 · 10^(18 − d) = 10^30`.
    // TEST-071 verifies: SPEC-UNIT-004
    function test_TEST_071_aaveValueOfABalanceExample() public {
        _pledge();
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(vtReserveId, true, proxy);
        uint256 value = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).totalCollateralValue;
        assertEq(value, 1e30, "Aave value 10^30");
        assertEq(value / 10 ** 18, UNITS * 2e8 / 10 ** VT_DECIMALS, "USD 8 decimals: $10,000.00000000");
        assertEq(UNITS * 2e8 / 10 ** VT_DECIMALS, 1_000_000_000_000);
    }

    /// @notice Aave's value of any balance the Hub cap admits, at any `price8` up to `1e20`, is exactly
    /// `n · price8 · 10^(18 − d)` and does not overflow.
    // TEST-071 verifies: SPEC-UNIT-004, SPEC-UNIT-006
    function testFuzz_TEST_071_aaveValueExactUpToTheCap(
        uint256 units,
        uint256 price8
    ) public {
        units = bound(units, 1, CAP_UNITS);
        price8 = bound(price8, 1, 1e20);
        _supplyMore(units);
        vm.prank(proxy);
        IAaveV4Spoke(aave.cdpSpoke).setUsingAsCollateral(vtReserveId, true, proxy);
        // Bounded to 1e20 above.
        // forge-lint: disable-next-line(unsafe-typecast)
        vtPrice.set(int256(price8));
        uint256 value = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(proxy).totalCollateralValue;
        assertEq(value, units * price8 * 10 ** (18 - VT_DECIMALS), "n * price8 * 10^(18 - d)");
    }

    /// @notice One `addCap` unit is one whole token: the Hub accepts supplies up to `addCap · 10^d` base units and
    /// refuses one more with `AddCapExceeded(addCap)`; the cap in base units stays below `2^120` for every finite
    /// `addCap < 2^40 − 1` and `d ≤ 18`, so the Hub's `uint120` shares never bind first.
    /// @dev Kills: a listing that sized `addCap` in base units (the Hub would then admit `10^6` times more units).
    // TEST-125 verifies: SPEC-UNIT-005, SPEC-UNIT-006
    function test_TEST_125_addCapIsInWholeTokens() public {
        _pledge();
        _supplyMore(CAP_UNITS - UNITS);
        uint256 assetId = _vtAssetId();
        assertEq(IAaveV4Hub(aave.hub).getAddedAssets(assetId), CAP_UNITS, "cap reached in base units");

        vm.prank(adapter);
        token.mint(proxy, 1);
        vm.startPrank(proxy);
        token.approve(aave.cdpSpoke, 1);
        vm.expectRevert(abi.encodeWithSelector(IHubAddCapError.AddCapExceeded.selector, ADD_CAP));
        IAaveV4Spoke(aave.cdpSpoke).supply(vtReserveId, 1, proxy);
        vm.stopPrank();

        uint256 maxFiniteCap = uint256(IAaveV4Hub(aave.hub).MAX_ALLOWED_SPOKE_CAP()) - 1;
        assertEq(maxFiniteCap, 2 ** 40 - 2, "finite caps are below 2^40 - 1");
        assertLt(maxFiniteCap * 10 ** 18, 2 ** 120, "addCap * 10^d < 2^120 at d = 18");
        assertLt(CAP_UNITS, 2 ** 120);
    }
}
