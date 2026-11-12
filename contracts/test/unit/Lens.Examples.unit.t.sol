// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensExamplesUnitTest
/// @notice The worked examples of spec 2.17 on the real Aave V4 Spoke: the borrow maximum and recommendation, the
/// repay-all quote and the repay with collateral, with the example's collateral factor set on the vault-token reserve
/// and its 8 % drawn rate on the Hub.
/// forge-config: default.isolate = false
contract LensExamplesUnitTest is LensFixture {
    uint256 internal constant RATE_8_PCT = 0.08e27;

    function setUp() public {
        _deployLens();
    }

    // TEST-247 verifies: REQ-LENS-035, Q-268
    function test_TEST_247_borrowMaxBobExample() public {
        // 50,000 vault tokens at $2.00, CF 2,812 bps: $28,120 weighted; 10,000 GHO owed; 8 % a year; 1,200 s.
        _setCollateralFactor(2812);
        _open(bob, bobProxy, 1, 50_000e6);
        _borrow(bobProxy, 10_000e18);
        _rate(ghoAssetId, RATE_8_PCT);
        uint256 amount = lens.previewBorrowMax(bob, MARKET_ID, debtReserveId, block.timestamp + 1200);
        assertApproxEqAbs(amount, 17_980.014e18, 0.001e18, "17,980.014 GHO");
        (uint256 rec,) = lens.previewBorrowRecommended(bob, MARKET_ID, debtReserveId, block.timestamp + 1200);
        assertApproxEqAbs(rec, 15_563.6363e18, 0.001e18, "28,120 / 1.10 - 10,000");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-044, Q-398
    function test_TEST_247_recommendedSeventyPercentExample() public {
        // $100,000 of collateral at a 70 % collateral factor and no debt.
        _setCollateralFactor(7000);
        _open(alice, aliceProxy, 1, 50_000e6);
        (uint256 rec, uint256 max) = lens.previewBorrowRecommended(alice, MARKET_ID, debtReserveId, block.timestamp);
        assertEq(rec, uint256(70_000e18) * 1e18 / 1.1e18, "floor(70,000 / 1.10) = $63,636");
        assertEq(max, uint256(70_000e18) * 1e18 / 1.005e18, "floor(70,000 / 1.005) = $69,651 at a zero rate");
    }

    // TEST-248 verifies: REQ-LENS-036, Q-269
    function test_TEST_248_repayAllUsdcExample() public {
        // 10,000 USDC owed at 8 % a year, deadline 1,200 s ahead: 10,010.030472 USDC.
        _open(alice, aliceProxy, 1, 50_000e6);
        _borrowUsdc(aliceProxy, 10_000e6);
        _rate(usdcAssetId, RATE_8_PCT);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).riskPremium, 0, "no risk premium");
        assertEq(lens.quoteRepayAll(alice, MARKET_ID, usdcReserveId, block.timestamp + 1200), 10_010_030_472, "quote");
        vm.clearMockedCalls();
    }

    // TEST-239 verifies: REQ-LENS-038, SPEC-LIQ-020, Q-255
    function test_TEST_239_repayWithCollateralBobExample() public {
        // 20,000 GHO owed on 50,000 vault tokens at $2.00, CF 2,812 bps (HF 1.406); 1,000 tokens repay with
        // epsilon 1 GHO, maxFlashFeeBps 5 and a 5 bps flash premium.
        _setCollateralFactor(2812);
        _open(bob, bobProxy, 1, 50_000e6);
        _borrow(bobProxy, 20_000e18);
        store.setFees(2000, 5);
        assertEq(_hf(bobProxy), 1.406e18, "HF 1.406");
        (uint256 x, uint256 out, uint256 hfAfter) =
            lens.previewRepayWithCollateral(bob, MARKET_ID, _key(1), 1000e6, debtReserveId);
        assertEq(x, 1_978_010_992_503_748_125_937, "x = floor(1,978.999998 x 1e4 / 10,005)");
        assertEq(out, 21.000002e18, "2,000 - x - premium");
        assertApproxEqAbs(hfAfter, 1.5291e18, 0.0001e18, "27,557.6 / 18,021.989007");
    }

    // TEST-247 verifies: REQ-LENS-041, Q-381
    function test_TEST_247_noMinimumBorrow() public {
        // An account with $2.00 of borrowing capacity: the preview still returns it.
        _setCollateralFactor(1000);
        _open(alice, aliceProxy, 1, 10e6);
        uint256 usdcAmount = lens.previewBorrowMax(alice, MARKET_ID, usdcReserveId, block.timestamp);
        assertGt(usdcAmount, 0, "a small capacity is not zeroed");
        assertEq(usdcAmount, uint256(2e26) * 1e18 / 1.005e18 / (0.9999e8 * 1e12), "$2.00 / 1.005 at $0.9999");
        _borrowUsdc(aliceProxy, usdcAmount);
        assertGe(_hf(aliceProxy), 1e18, "the RiskModule's smallest accepted borrow is one base unit");
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

    function _rate(
        uint256 assetId,
        uint256 rate
    ) internal {
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAssetDrawnRate(uint256)", assetId), abi.encode(rate));
    }
}
