// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {DeleverageSizing} from "../../src/lens/lens/types/DeleverageSizing.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensInverseSizingFuzzTest
/// @notice For any collateral, debt, interest time, price and target: the largest removal keeps Aave's health factor at
/// or above the target and one unit more takes it below (unless every unit is removed); the deleverage sizing reaches
/// the target with a repay with collateral that the preview confirms, and one unit fewer does not.
/// forge-config: default.isolate = false
contract LensInverseSizingFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    function _world(
        uint128 units,
        uint256 debtShare,
        uint256 dt,
        uint256 price
    ) internal {
        // At most $1,000,000 of collateral, so 70 % of it stays within the GHO draw cap and liquidity.
        units = uint128(bound(units, 100e6, 500_000e6));
        _open(alice, aliceProxy, 1, units);
        uint256 value = uint256(units) * 2e12;
        _borrow(aliceProxy, bound(debtShare, value / 1000, value * 7 / 10));
        // Within the price feeds' age limits, so the repay with collateral stays open.
        vm.warp(block.timestamp + bound(dt, 0, 20 hours));
        _setVtPrice(int256(bound(price, 1.9e8, 2.3e8)));
    }

    function _hfAfterSpokeWithdraw(
        uint256 units
    ) internal returns (uint256 hf) {
        uint256 snap = vm.snapshotState();
        vm.prank(aliceProxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, units, aliceProxy);
        hf = _hf(aliceProxy);
        vm.revertToState(snap);
    }

    // TEST-247 verifies: REQ-LENS-054
    function testFuzz_TEST_247_maxWithdrawIsTightAgainstAave(
        uint128 units,
        uint256 debtShare,
        uint256 dt,
        uint256 price,
        uint256 target
    ) public {
        _world(units, debtShare, dt, price);
        target = bound(target, 1e18, 3e18);
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, target);
        assertEq(s.target, target, "no floor set");
        uint256 shares = _shares(aliceProxy);
        assertLe(s.maxUnits, shares, "never more than the account holds");
        if (s.maxUnits > 0) assertGe(_hfAfterSpokeWithdraw(s.maxUnits), target, "the bound keeps the target");
        if (s.maxUnits < shares && _hf(aliceProxy) >= target) {
            uint256 snap = vm.snapshotState();
            vm.prank(aliceProxy);
            (bool ok,) =
                aave.cdpSpoke.call(abi.encodeCall(IAaveV4Spoke.withdraw, (vtReserveId, s.maxUnits + 1, aliceProxy)));
            if (ok) assertLt(_hf(aliceProxy), target, "one unit more misses it");
            vm.revertToState(snap);
        }
        assertEq(s.records[0].fits, s.records[0].units <= s.maxUnits, "fits iff within the bound");
    }

    // TEST-247 verifies: REQ-LENS-055
    function testFuzz_TEST_247_deleverageToReachesTheTarget(
        uint128 units,
        uint256 debtShare,
        uint256 dt,
        uint256 price,
        uint256 target
    ) public {
        _world(units, debtShare, dt, price);
        uint256 hf0 = _hf(aliceProxy);
        target = bound(target, 1e18, 4e18);
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, target);
        if (!s.reachable) {
            assertEq(s.units + s.debtRepaid + s.healthFactorAfter + s.debtAssetToWallet, 0, "all zero");
            (uint256 xAll,, uint256 hfAll) =
                lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(_shares(aliceProxy)), debtReserveId);
            // Either the repay with collateral is closed (nothing repaid) or even the whole record misses the target.
            if (xAll > 0) assertLt(hfAll, target, "even the whole record misses it");
            return;
        }
        if (hf0 >= target) {
            assertEq(s.units, 0, "already there");
            return;
        }
        (uint256 x, uint256 out, uint256 hf) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units), debtReserveId);
        assertEq(x, s.debtRepaid, "x");
        assertEq(out, s.debtAssetToWallet, "payout");
        assertEq(hf, s.healthFactorAfter, "health factor");
        assertGe(hf, target, "reaches the target");
        if (s.units > 1) {
            (,, uint256 below) =
                lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units - 1), debtReserveId);
            assertLt(below, target, "one unit fewer does not");
        }
    }
}
