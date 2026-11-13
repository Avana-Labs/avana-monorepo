// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";

/// @title LensActionsFuzzTest
/// @notice For any collateral, debts on both reserves, interest time, risk premium and action size, the after-action
/// previews equal Aave's account data once the action has run in the same block.
/// forge-config: default.isolate = false
contract LensActionsFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    function _world(
        uint128 units,
        uint256 gho,
        uint256 usdcDebt,
        uint256 risk,
        uint256 dt
    ) internal returns (uint256 ghoDebt) {
        units = uint128(bound(units, 1000e6, 400_000e6));
        _open(alice, aliceProxy, 1, units);
        risk = bound(risk, 0, 5000);
        if (risk > 0) {
            _spokeConfig(
                abi.encodeWithSignature(
                    "updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, risk
                )
            );
        }
        // Up to 30 % of the collateral value in each debt, so the account stays healthy through a year of interest.
        uint256 value = uint256(units) * 2;
        ghoDebt = bound(gho, 1e18, value * 0.3e12);
        _borrow(aliceProxy, ghoDebt);
        usdcDebt = bound(usdcDebt, 0, value * 30 / 100);
        if (usdcDebt > 0) _borrowUsdc(aliceProxy, usdcDebt);
        vm.warp(block.timestamp + bound(dt, 0, 365 days));
    }

    function _assertAfter(
        ActionPreview memory v
    ) internal view {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy);
        assertEq(v.healthFactorAfter, a.healthFactor, "health factor");
        assertEq(v.debtValueAfterRay, a.totalDebtValueRay, "debt value");
        assertEq(v.collateralValueAfter, a.totalCollateralValue, "collateral value");
        assertEq(v.liquidationPriceAfter, lens.getAccountRisk(alice, MARKET_ID).liquidationPrice, "liquidation price");
    }

    // TEST-247 verifies: REQ-LENS-052
    function testFuzz_TEST_247_borrowAfterEqualsAave(
        uint128 units,
        uint256 gho,
        uint256 usdcDebt,
        uint256 risk,
        uint256 dt,
        uint256 more
    ) public {
        _world(units, gho, usdcDebt, risk, dt);
        uint256 room = lens.previewBorrowMax(alice, MARKET_ID, debtReserveId, block.timestamp);
        vm.assume(room > 1);
        more = bound(more, 1, room);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, more);
        assertEq(v.healthFactorBefore, _hf(aliceProxy), "before");
        _borrow(aliceProxy, more);
        _assertAfter(v);
    }

    // TEST-247 verifies: REQ-LENS-052
    function testFuzz_TEST_247_repayAfterEqualsAave(
        uint128 units,
        uint256 gho,
        uint256 usdcDebt,
        uint256 risk,
        uint256 dt,
        uint256 amount
    ) public {
        _world(units, gho, usdcDebt, risk, dt);
        uint256 total = _debtOf(aliceProxy, debtReserveId);
        amount = bound(amount, 1, total + 10);
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, debtReserveId, amount);
        uint256 paid = amount < total ? amount : total;
        assertEq(v.amount, paid, "repaid part");
        CollPoolToken(address(debt)).mint(aliceProxy, paid);
        vm.startPrank(aliceProxy);
        CollPoolToken(address(debt)).approve(aave.cdpSpoke, paid);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, paid, aliceProxy);
        vm.stopPrank();
        _assertAfter(v);
    }

    // TEST-247 verifies: REQ-LENS-053
    function testFuzz_TEST_247_pledgeAndWithdrawAfterEqualAave(
        uint128 units,
        uint256 gho,
        uint256 dt,
        uint128 added
    ) public {
        _world(units, gho, 0, 0, dt);
        added = uint128(bound(added, 1e6, 100_000e6));
        vault.mintPosition(_key(2), alice, MARKET_ID, added);
        ActionPreview memory v = lens.previewPledgeAfter(alice, MARKET_ID, _key(2));
        _pledge(alice, aliceProxy, _key(2), added);
        _assertAfter(v);
        v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(2));
        assertEq(v.amount, added, "the record's units");
        _withdraw(aliceProxy, _key(2), added);
        _assertAfter(v);
    }
}
