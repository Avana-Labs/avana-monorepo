// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {RemovalSizing} from "../../src/lens/lens/types/RemovalSizing.sol";
import {RiskModuleMath} from "../../src/policy/risk-module/RiskModuleMath.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensActionsConfigFuzzTest
/// @notice Across collateral-factor changes, rescue units and market settings: the borrow and withdrawal previews follow
/// the dynamic configuration Aave applies, the removal bound subtracts the rescue exclusion exactly, and the market view
/// reports whatever caps and liquidation configuration are set.
/// forge-config: default.isolate = false
contract LensActionsConfigFuzzTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-053
    function testFuzz_TEST_247_previewsFollowTheDynamicConfiguration(
        uint128 units,
        uint256 debtBps,
        uint16 newCf,
        uint256 more
    ) public {
        units = uint128(bound(units, 1000e6, 300_000e6));
        _open(alice, aliceProxy, 1, units);
        _pledge(alice, aliceProxy, _key(2), units / 4 + 1);
        uint256 value = (uint256(units) + units / 4 + 1) * 2e12;
        _borrow(aliceProxy, value * bound(debtBps, 100, 4000) / 1e4);
        newCf = uint16(bound(newCf, 5000, 9500));
        _spokeConfig(
            abi.encodeWithSignature("addCollateralFactor(address,uint256,uint16)", aave.cdpSpoke, vtReserveId, newCf)
        );
        more = bound(more, 1e18, value / 20);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, debtReserveId, more);
        uint256 snap = vm.snapshotState();
        vm.prank(aliceProxy);
        (bool ok,) = aave.cdpSpoke.call(abi.encodeCall(IAaveV4Spoke.borrow, (debtReserveId, more, aliceProxy)));
        if (ok) assertEq(v.healthFactorAfter, _hf(aliceProxy), "borrow at the latest factor");
        else assertLt(v.healthFactorAfter, 1e18, "Aave refused exactly the borrows the preview puts below 1.00");
        vm.revertToState(snap);
        v = lens.previewWithdrawAfter(alice, MARKET_ID, _key(2));
        vm.prank(aliceProxy);
        (ok,) = aave.cdpSpoke.call(abi.encodeCall(IAaveV4Spoke.withdraw, (vtReserveId, v.amount, aliceProxy)));
        if (ok) assertEq(v.healthFactorAfter, _hf(aliceProxy), "withdrawal at the latest factor");
        else assertLt(v.healthFactorAfter, 1e18, "Aave refused exactly the withdrawals the preview puts below 1.00");
    }

    // TEST-247 verifies: REQ-LENS-054, SPEC-CF-005
    function testFuzz_TEST_247_removalSubtractsTheRescueExclusion(
        uint128 units,
        uint256 debtBps,
        uint256 rescue,
        uint256 target
    ) public {
        units = uint128(bound(units, 1000e6, 300_000e6));
        _open(alice, aliceProxy, 1, units);
        uint256 value = uint256(units) * 2e12;
        _borrow(aliceProxy, value * bound(debtBps, 100, 6000) / 1e4);
        target = bound(target, 1e18, 2e18);
        uint256 plain = lens.previewMaxWithdraw(alice, MARKET_ID, target).maxUnits;
        rescue = bound(rescue, 1, units);
        vm.mockCall(
            address(coll),
            abi.encodeCall(ICollateralizationViews.getAccountRescueUnits, (aliceProxy, vt)),
            abi.encode(rescue)
        );
        RemovalSizing memory s = lens.previewMaxWithdraw(alice, MARKET_ID, target);
        vm.clearMockedCalls();
        uint256 e = RiskModuleMath.rescueValue(rescue, 2e8, 8000, VT_DECIMALS);
        // One vault token unit weighs `per / 1e4` in value at CF 80 % and $2, so the excluded value E comes off the
        // bound as E / (per / 1e4) units, within one unit of rounding.
        uint256 per = 2e20 * 8000;
        assertLe(s.maxUnits, plain, "an exclusion never raises the bound");
        if (s.maxUnits > 0 && plain < units) {
            assertApproxEqAbs((plain - s.maxUnits) * per / 1e4, e, per / 1e4 + 1, "the exclusion's value comes off");
        }
    }

    // TEST-247 verifies: REQ-LENS-057
    function testFuzz_TEST_247_marketViewReportsTheSettings(
        uint256 cap,
        uint256 slice,
        uint256 depositorCap,
        uint256 tokenCap,
        uint256 floor,
        uint256 target
    ) public {
        cap = bound(cap, 1, 1e20);
        slice = bound(slice, 0, cap);
        (depositorCap, tokenCap, floor) =
        (bound(depositorCap, 0, 1e20), bound(tokenCap, 0, 1e20), bound(floor, 0, 2e18));
        store.setCaps(MARKET_ID, cap, slice, 1e8);
        store.setDepositorCap(aave.hub, depositorCap);
        store.setTokenCap(aave.hub, address(usdt), tokenCap);
        store.setHardHealthFloor(MARKET_ID, floor);
        target = bound(target, 1.01e18, 2e18);
        _spokeConfig(
            abi.encodeWithSignature("updateLiquidationTargetHealthFactor(address,uint256)", aave.cdpSpoke, target)
        );
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.marketUsdCap, cap, "market cap");
        assertEq(v.topUpSliceUsd, slice, "slice");
        assertEq(v.depositorUsdCap, depositorCap, "depositor cap");
        assertEq(v.tokenUsdCaps[1], tokenCap, "USDT cap");
        assertEq(v.hardHealthFloor, floor, "hard floor");
        assertEq(v.targetHealthFactor, target, "target health factor");
        assertEq(v.marketHeadroomUsd, cap, "nothing pledged");
    }
}
