// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {LensLiquidationModule} from "../../src/lens/lens/LensLiquidationModule.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensLiquidationBranchesUnitTest
/// @notice `previewLiquidation` edges: the liquidation module's sizing address check, and the caller-loss estimate
/// when the unwound composition rounds every leg to nothing.
/// forge-config: default.isolate = false
contract LensLiquidationBranchesUnitTest is LensFixture {
    uint128 internal constant UNITS = 10_000e6;
    uint256 internal constant DEADLINE = T0 + 120;

    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, UNITS);
    }

    // TEST-247 verifies: REQ-LENS-017
    /// @notice The liquidation module pins `LensAaveSizing` at construction: the zero address is refused with
    /// `InvalidModules`, and the fixture's module reports the sizing it was built with.
    function test_TEST_247_liquidationModuleRejectsZeroSizing() public {
        vm.expectRevert(ILensErrors.InvalidModules.selector);
        new LensLiquidationModule(core, address(0));
        LensLiquidationModule built = new LensLiquidationModule(core, sizing);
        assertEq(built.AAVE_SIZING(), sizing, "a non-zero sizing is pinned");
    }

    // TEST-069 verifies: REQ-LENS-029, SPEC-LIQ-018
    /// @notice Alice owes 15,000 GHO against 10,000 whole vault tokens priced $1.80: liquidatable. With the fair
    /// composition at its real rates the unwound value covers the repayment (no caller loss). When the AMM reports at
    /// most one raw unit per token (1 USDC unit, 0 USDT units), one unit less per token leaves nothing to value, so
    /// `Rv = 0` and the caller may lose the whole expected repayment `D`.
    function test_TEST_069_callerLossWhenEveryUnwoundLegRoundsToZero() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertGt(p.expectedUnitsSeized, 0, "liquidatable");
        assertEq(p.expectedCallerLoss, 0, "real composition: the unwound value covers D");
        uint256[] memory dust = new uint256[](2);
        (dust[0], dust[1]) = (1, 0);
        vm.mockCall(
            address(vault), abi.encodeWithSelector(IAmmIntegration.composition.selector), abi.encode(dust, true)
        );
        p = lens.previewLiquidation(aliceProxy, debtReserveId, DEADLINE);
        assertGt(p.expectedDebtRepaid, 0, "a repayment is still sized");
        assertEq(p.expectedCallerLoss, p.expectedDebtRepaid, "Rv = 0: the whole repayment is at risk");
        vm.clearMockedCalls();
    }
}
