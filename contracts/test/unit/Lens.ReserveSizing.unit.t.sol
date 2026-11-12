// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../src/types/Market.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensReserveSizingUnitTest
/// @notice The tail term of SPEC-FLR-005 and the per-asset sizing of REQ-FLR-041 as `Lens.getTailCoverage` reports
/// them on the real Aave V4 Hub and Spoke: the worked examples of spec 2.14 (a $1,600,000 token cap with $80,000 of
/// slices at a 3,120 bps collateral factor against a 400,000 GHO reserve), the cap and reserve that close the gap,
/// the draw-capacity bound, the unbounded draw cap, and the independence of one asset's ratio from another
/// asset's reserve. The fixture's USDT plays the example's USDe: a non-GHO pool token of a GHO-debt market.
/// forge-config: default.isolate = false
contract LensReserveSizingUnitTest is LensFixture {
    uint16 internal constant CF_BPS = 3120;

    function setUp() public {
        _deployLens();
        _setCollateralFactor(CF_BPS);
        // USDe cap $1,600,000 with $80,000 of slices; USDC capped at 0 so its tail is the slices alone.
        store.setCaps(MARKET_ID, 1_000_000e8, 80_000e8, 1e8);
        store.setTokenCap(aave.hub, address(usdc), 0);
        store.setTokenCap(aave.hub, address(usdt), 1_600_000e8);
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 2_000_000);
        ghoCov.set(400_000e18, 400_000e18);
    }

    // TEST-247 verifies: SPEC-FLR-005, REQ-LENS-034, SPEC-CAP-008
    function test_TEST_247_tailTermWorkedExample() public view {
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.worstToken, address(usdt), "the USDe token");
        assertEq(t.drawCapUsd, 2_000_000e8, "2,000,000 GHO of draw capacity");
        // min(ceil(1,680,000 x 3,120 / 1e4), 2,000,000) = 524,160 GHO at $1.00.
        assertEq(t.tailUsd, 524_160e8, "tail_GHO");
        assertEq(t.fundedUsd, 400_000e8, "funded");
        // floor(400,000 x 1e4 / 524,160) = 7,631.
        assertEq(t.ratioBps, 7631, "tailCoverageBps_GHO");
    }

    // TEST-247 verifies: SPEC-FLR-005, REQ-FLR-041
    function test_TEST_247_capCutOrFundedMinimumClosesTheGap() public {
        // The DAO lowers the USDe cap to $1,202,051: tail = ceil(1,282,051 x 0.312) = 399,999.912 GHO, covered.
        store.setTokenCap(aave.hub, address(usdt), 1_202_051e8);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.tailUsd, 399_999.912e8, "tail at the largest covered cap");
        assertEq(t.ratioBps, 10_000, "fully covered");
        // One dollar more and the tail exceeds the reserve.
        store.setTokenCap(aave.hub, address(usdt), 1_202_052e8);
        assertEq(lens.getTailCoverage(aave.hub, address(debt)).ratioBps, 9999, "one dollar past the reserve");
        // Or the cap stays and the minimum is raised to 524,160 GHO and funded.
        store.setTokenCap(aave.hub, address(usdt), 1_600_000e8);
        ghoCov.set(524_160e18, 524_160e18);
        t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.minimum, 524_160e18, "minimum raised");
        assertEq(t.ratioBps, 10_000, "funded to the tail");
    }

    // TEST-247 verifies: REQ-FLR-041, SPEC-FLR-005, REQ-LENS-034
    function test_TEST_247_listingProposalShowsTheGap() public {
        // An $800,000 USDe market added slice-free: tokenUsdCap rises to $2,400,000.
        _listUsdeMarket();
        store.setTokenCap(aave.hub, address(usdt), 2_400_000e8);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.tailUsd, 773_760e8, "2,480,000 x 0.312");
        assertEq(t.ratioBps, 5169, "floor(400,000 x 1e4 / 773,760)");
        assertLt(t.ratioBps, 10_000, "the gap is visible before approval");
    }

    // TEST-247 verifies: SPEC-FLR-005, REQ-LENS-034
    function test_TEST_247_tailCappedByDrawCapacity() public {
        // 500,000 GHO of draw capacity: the tail never asks for more than can be lent.
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 500_000);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.tailUsd, 500_000e8, "min(524,160, 500,000)");
        assertEq(t.ratioBps, 8000, "floor(400,000 x 1e4 / 500,000)");
    }

    // TEST-247 verifies: SPEC-FLR-005, REQ-LENS-034
    function test_TEST_247_unboundedDrawCapLeavesTheCappedExposure() public {
        _setDrawCap(ghoAssetId, aave.cdpSpoke, type(uint40).max);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.drawCapUsd, type(uint256).max, "unbounded draw capacity");
        assertEq(t.tailUsd, 524_160e8, "the capped-exposure term alone");
        assertEq(t.ratioBps, 7631, "same ratio");
    }

    // TEST-247 verifies: REQ-FLR-041, REQ-FLR-040, SPEC-FLR-005
    function test_TEST_247_anotherAssetsReserveCountsNothing() public {
        // Funding the USDC Coverage Spoke far above the GHO tail leaves the GHO ratio where it was.
        usdcCov.set(10_000_000e6, 10_000_000e6);
        TailCoverageView memory gho = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(gho.coverageSpoke, address(ghoCov), "GHO's own Coverage Spoke");
        assertEq(gho.ratioBps, 7631, "unchanged by the USDC reserve");
        TailCoverageView memory usdcView = lens.getTailCoverage(aave.hub, address(usdc));
        assertEq(usdcView.coverageSpoke, address(usdcCov), "USDC's own Coverage Spoke");
        assertEq(usdcView.funded, 10_000_000e6, "the USDC reserve");
    }

    // ─── helpers ───

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

    /// @dev A second USDe/GHO market on the same Spoke and vault-token reserve (same collateral factor), no slice.
    function _listUsdeMarket() internal {
        Market memory m = reg.getMarket(MARKET_ID);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdt), address(debt));
        (m.tokens, m.status) = (tokens, MarketStatus.Active);
        m.vaultToken = makeAddr("usdeVaultToken");
        uint256 id = reg.marketCount() + 1;
        reg.setMarket(id, m);
        store.setCaps(id, 800_000e8, 0, 1e8);
    }
}
