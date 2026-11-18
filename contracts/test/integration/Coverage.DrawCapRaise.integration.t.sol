// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationPreview} from "../../src/lens/lens/types/LensTypes.sol";
import {LiquidationParams, LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";

/// @title CoverageDrawCapRaiseIntegrationTest
/// @notice First-loss coverage on the summed Spoke draw caps, on the real stack: the Aave DAO can raise a CDP Spoke's
/// draw cap on the Hub without Avana, and once the summed caps outgrow the First-Loss Reserve's cover, new borrows of
/// that asset revert `CoverageBelowRatio` while repay, the other asset's borrows and liquidation stay open; a cut back
/// within the cover reopens borrowing.
/// forge-config: default.isolate = false
contract CoverageDrawCapRaiseIntegrationTest is RealStackFlows {
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        // A 10 % cover: the 100,000 USDC First-Loss Reserve covers exactly the CDP Spoke's 1,000,000 USDC draw cap.
        vm.prank(address(timelock));
        store.setCoverageRatioBps(1000);
    }

    /// @dev The Aave DAO sets the CDP Spoke's USDC draw cap on the Hub (whole USDC), as on Aave.
    function _setUsdcDrawCap(
        uint256 cap
    ) internal {
        vm.prank(aaveDao);
        (bool ok,) = aave.hubConfigurator
            .call(
                abi.encodeWithSignature(
                    "updateSpokeDrawCap(address,uint256,address,uint256)", aave.hub, usdcAssetId, aave.cdpSpoke, cap
                )
            );
        assertTrue(ok, "the DAO sets the draw cap");
    }

    function _usdcBorrowError() internal view returns (bytes memory) {
        (, uint256 required, uint256 funded) = registry.drawCapCoverage(aave.hub, address(usdc));
        return
            abi.encodeWithSelector(
                IMarketRegistry.CoverageBelowRatio.selector, aave.hub, address(usdc), required, funded
            );
    }

    // TEST-273 verifies: REQ-CONFIG-081, SPEC-CAP-010
    function test_TEST_273_drawCapRaisePastCoverStopsOnlyNewBorrows() public {
        (, address proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 5880e6);
        (uint256 sum, uint256 required, uint256 funded) = registry.drawCapCoverage(aave.hub, address(usdc));
        assertEq(sum, DEBT_DRAW_CAP, "the CDP Spoke's draw cap is the covered sum");
        assertLe(required, funded, "covered at listing");

        // The DAO raises the cap a hundredfold, past what the First-Loss Reserve covers.
        _setUsdcDrawCap(uint256(DEBT_DRAW_CAP) * 100);
        (sum, required, funded) = registry.drawCapCoverage(aave.hub, address(usdc));
        assertEq(sum, uint256(DEBT_DRAW_CAP) * 100, "the raise is read live");
        assertGt(required, funded, "no longer covered");
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 d = _deadline();
        vm.expectRevert(_usdcBorrowError());
        vm.prank(bob);
        adapterC.borrow(mA, usdcReserveId, 1e6, bob, d, 0, nonce);

        // The other asset still borrows; repay of the uncovered asset stays open.
        _borrowAs(bob, mA, ghoReserveId, 1e18);
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        _repayVia(bob, bob, mA, usdcReserveId, 1e6, false);
        assertLt(_debtOf(proxy, usdcReserveId), debtBefore, "repay is open");

        // Liquidation stays open: USDT falls and the account goes under.
        _depegUsdt(93_000_000);
        LiquidationPreview memory pv = lens.previewLiquidation(proxy, usdcReserveId, block.timestamp + 120);
        assertTrue(pv.aaveLiquidatable, "liquidatable on Aave");
        LiquidationParams memory p = _liqParams(proxy, mA, usdcReserveId, pv.params.debtToCover);
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertGt(r.debtRepaid, 0, "liquidation is open");

        // A cut back within the cover reopens borrowing.
        _setUsdcDrawCap(DEBT_DRAW_CAP);
        (, required, funded) = registry.drawCapCoverage(aave.hub, address(usdc));
        assertLe(required, funded, "covered again");
        _pledgeAs(carol, mA, UNITS);
        _borrowAs(carol, mA, usdcReserveId, 100e6);
    }
}
