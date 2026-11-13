// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ActionPreview} from "../../src/lens/lens/types/ActionPreview.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensActionsDebtPriceUnitTest
/// @notice The after-action previews value debt at the price Aave serves for the reserve: a USDC reserve whose
/// DebtOracle serves a stressed price above its accepted one counts at the stressed price, before and after the borrow;
/// and the market list carries the risk configuration only for listed markets.
/// forge-config: default.isolate = false
contract LensActionsDebtPriceUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 40_000e6);
    }

    function _assertAfter(
        ActionPreview memory v
    ) internal view {
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy);
        assertEq(v.healthFactorAfter, a.healthFactor, "health factor");
        assertEq(v.debtValueAfterRay, a.totalDebtValueRay, "debt value");
    }

    // TEST-247 verifies: REQ-LENS-052, REQ-LENS-030
    function test_TEST_247_stressedDebtPriceCountsInThePreview() public {
        _borrowUsdc(aliceProxy, 20_000e6);
        // Expired with a 5 % stress rise: served 1.049895, accepted 0.9999.
        usdcOracle.set(1.049895e8, PriceState.Expired, 0.9999e8, uint64(block.timestamp - 100_000));
        ActionPreview memory v = lens.previewRepayAfter(alice, MARKET_ID, usdcReserveId, 5000e6);
        assertEq(v.healthFactorBefore, _hf(aliceProxy), "before, at the served price");
        assertEq(v.debtValueAfterRay, uint256(15_000e6) * 1.049895e8 * 1e12 * 1e27, "15,000 USDC at $1.049895");
        vm.startPrank(aliceProxy);
        usdc.mint(aliceProxy, 5000e6);
        usdc.approve(aave.cdpSpoke, 5000e6);
        IAaveV4Spoke(aave.cdpSpoke).repay(usdcReserveId, 5000e6, aliceProxy);
        vm.stopPrank();
        _assertAfter(v);
    }

    // TEST-247 verifies: REQ-LENS-052
    function test_TEST_247_borrowPreviewAtTheServedDebtPrice() public {
        _setUsdcPrice(1.02e8);
        ActionPreview memory v = lens.previewBorrowAfter(alice, MARKET_ID, usdcReserveId, 10_000e6);
        assertEq(v.debtValueAfterRay, uint256(10_000e6) * 1.02e8 * 1e12 * 1e27, "10,000 USDC at $1.02");
        assertEq(v.healthFactorAfter, uint256(64_000e18) * 100 / 102 / 10_000, "0.8 x 80,000 / 10,200");
        _borrowUsdc(aliceProxy, 10_000e6);
        _assertAfter(v);
    }

    // TEST-247 verifies: REQ-LENS-057, REQ-LENS-045
    function test_TEST_247_unlistedPagePositionsCarryNoRiskConfiguration() public view {
        MarketView[] memory page = lens.getMarkets(0, 10);
        assertEq(page.length, MARKET_ID, "markets 1 to 4");
        assertEq(page[0].tokenUsdCaps.length, 0, "an unlisted id has no caps");
        assertEq(page[0].debtReserveIds.length, 0, "and no rates");
        assertEq(page[0].targetHealthFactor, 0, "nor a liquidation configuration");
        assertEq(page[MARKET_ID - 1].tokenUsdCaps.length, 2, "the listed market has them");
        assertEq(page[MARKET_ID - 1].debtReserveIds.length, 2, "both debt reserves");
    }
}
