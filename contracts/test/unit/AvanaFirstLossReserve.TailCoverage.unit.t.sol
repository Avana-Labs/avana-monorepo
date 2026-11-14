// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {CollHubSpokeConfig, ICollHubConfigurator} from "../utils/fixtures/CollateralizationFixture.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title AvanaFirstLossReserveTailCoverageUnitTest
/// @notice The tail coverage of SPEC-FLR-005 against a real GHO First-Loss Reserve on the real local Aave V4 Hub: the
/// funded balance `Lens.getTailCoverage` divides by is the First-Loss Reserve's own `fundedBalance()` (its added assets on
/// the Hub), so the ratio `⌊fundedBalance × 10⁴ / tail⌋` moves only with what is funded into that asset's reserve. The
/// worked example of spec 2.14: a $1,600,000 token cap with $80,000 of slices at a 3,120 bps collateral factor gives
/// `tail_GHO = 524,160` GHO; 400,000 GHO funded gives 7,631 bps, and funding the remaining 124,160 GHO closes the gap.
/// forge-config: default.isolate = false
contract AvanaFirstLossReserveTailCoverageUnitTest is LensFixture {
    uint16 internal constant CF_BPS = 3120;
    AvanaFirstLossReserve internal ghoReserve;
    address internal funder = makeAddr("avanaLabsFunder");

    function setUp() public {
        _deployLens();
        _setCollateralFactor(CF_BPS);
        store.setCaps(MARKET_ID, 1_000_000e8, 80_000e8, 1e8);
        store.setTokenCap(aave.hub, address(usdc), 0);
        store.setTokenCap(aave.hub, address(usdt), 1_600_000e8);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 2_000_000);

        ghoReserve = new AvanaFirstLossReserve(aave.hub, address(debt), ghoAssetId, aave.accessManager, 1_209_600);
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(ghoReserve), ghoAssetId, CollHubSpokeConfig(1_000_000, 0, maxRp, true, false));
        reg.setAvanaFirstLossReserve(aave.hub, address(debt), address(ghoReserve));
        DebtReserveDef memory d = _def(debtReserveId, address(debt), 18, ghoAssetId, address(0), true, ghoCov);
        d.firstLossReserve = address(ghoReserve);
        reg.setDebtReserve(aave.cdpSpoke, d);
    }

    /// @dev The market's collateral factor on its vault-token reserve key 0, set by the Aave DAO.
    function _setCollateralFactor(
        uint16 cf
    ) internal {
        _spokeConfig(
            abi.encodeWithSignature(
                "updateDynamicReserveConfig(address,uint256,uint32,(uint16,uint32,uint16))",
                aave.cdpSpoke,
                vtReserveId,
                uint32(0),
                cf,
                uint32(10_500),
                uint16(0)
            )
        );
    }

    function _fund(
        uint256 amount
    ) internal {
        debt.mint(funder, amount);
        vm.startPrank(funder);
        debt.approve(address(ghoReserve), amount);
        ghoReserve.fund(amount);
        vm.stopPrank();
    }

    // TEST-247 verifies: SPEC-FLR-005, REQ-FLR-041, REQ-LENS-034, SPEC-CAP-008
    function test_TEST_247_tailCoverageReadsTheRealReserve() public {
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.firstLossReserve, address(ghoReserve), "the asset's own First-Loss Reserve");
        assertEq(t.tailUsd, 524_160e8, "tail_GHO = min(ceil(1,680,000 x 0.312), 2,000,000)");
        assertEq(t.funded, 0, "nothing funded yet");
        assertEq(t.ratioBps, 0, "no coverage");

        _fund(400_000e18);
        assertEq(ghoReserve.fundedBalance(), 400_000e18, "the Hub holds the funded GHO for the reserve");
        t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.funded, ghoReserve.fundedBalance(), "funded is the reserve's fundedBalance");
        assertEq(t.fundedUsd, 400_000e8, "funded in USD");
        assertEq(t.ratioBps, 7631, "floor(400,000 x 1e4 / 524,160)");
        assertEq(t.minimum, ghoReserve.firstLossReserveMinimum(), "the reserve's own minimum");

        _fund(124_159e18);
        assertEq(lens.getTailCoverage(aave.hub, address(debt)).ratioBps, 9999, "one GHO short: rounded down");
        _fund(1e18);
        assertEq(lens.getTailCoverage(aave.hub, address(debt)).ratioBps, 10_000, "funded to the tail");
    }
}
