// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserveErrors} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserveErrors.sol";
import {AvanaFirstLossReserveFixture, ICoverageHubSpokeCalls} from "../utils/fixtures/AvanaFirstLossReserveFixture.sol";

/// @title AvanaFirstLossReserveDeficitDrawCapUnitTest
/// @notice A recorded deficit on the real local Aave V4 Hub counts against the CDP Spoke's `drawCap` on that asset
/// until the First-Loss Reserve of the deficit's asset covers it (2.14 REQ-FLR-021): a draw that fits the cap only without
/// the deficit is refused while the deficit stands, the GHO First-Loss Reserve has nothing to cover on the USDC deficit,
/// the USDC First-Loss Reserve's `COVERAGE_ROLE` holder covers it from the funded balance, and the same draw then fits.
contract AvanaFirstLossReserveDeficitDrawCapUnitTest is AvanaFirstLossReserveFixture {
    function setUp() public {
        _deployCoverage();
    }

    // TEST-199 verifies: REQ-FLR-021, REQ-FLR-040, SPEC-FLR-001
    function test_TEST_199_deficitCountsAgainstDrawCapUntilCovered() public {
        _reportDeficit(usdcAssetId, aave.cdpSpoke, 1000e6);
        uint256 amount = uint256(DRAW_CAP) * 1e6 - 1000e6 + 1;

        vm.prank(aave.cdpSpoke);
        vm.expectRevert(abi.encodeWithSignature("DrawCapExceeded(uint256)", uint256(DRAW_CAP)));
        ICoverageHubSpokeCalls(aave.hub).draw(usdcAssetId, amount, aave.cdpSpoke);

        vm.prank(coverageCaller);
        vm.expectRevert(abi.encodeWithSelector(IAvanaFirstLossReserveErrors.NothingToCover.selector, aave.cdpSpoke));
        ghoCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);

        uint256 funded = usdcCoverage.fundedBalance();
        vm.prank(coverageCaller);
        (, uint256 covered) = usdcCoverage.coverDeficit(aave.cdpSpoke, type(uint256).max);
        assertEq(covered, 1000e6, "the whole deficit, within the funded balance");
        assertEq(usdcCoverage.fundedBalance(), funded - 1000e6, "paid from the USDC reserve");
        assertEq(hub.getSpokeDeficitRay(usdcAssetId, aave.cdpSpoke), 0, "deficit cleared");

        vm.prank(aave.cdpSpoke);
        ICoverageHubSpokeCalls(aave.hub).draw(usdcAssetId, amount, aave.cdpSpoke);
    }
}
