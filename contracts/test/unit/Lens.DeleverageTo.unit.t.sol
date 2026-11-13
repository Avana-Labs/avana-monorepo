// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeleverageSizing} from "../../src/lens/lens/types/DeleverageSizing.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensDeleverageToUnitTest
/// @notice `previewDeleverageTo` for a 6-decimal debt, an account already below 1.00, a record too small for the target
/// and a stale debt price; and the market's borrow rates when the collateral risk is high or a debt reserve is
/// disabled.
/// forge-config: default.isolate = false
contract LensDeleverageToUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    function _assertConsistent(
        DeleverageSizing memory s,
        uint256 reserve,
        uint256 target
    ) internal view {
        (uint256 x, uint256 out, uint256 hf) =
            lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units), reserve);
        assertEq(x, s.debtRepaid, "x");
        assertEq(out, s.debtAssetToWallet, "payout");
        assertEq(hf, s.healthFactorAfter, "health factor");
        assertGe(hf, target, "reaches the target");
        (,, uint256 below) = lens.previewRepayWithCollateral(alice, MARKET_ID, _key(1), uint128(s.units - 1), reserve);
        assertLt(below, target, "one unit fewer does not");
    }

    // TEST-247 verifies: REQ-LENS-055
    function test_TEST_247_deleverageToWithASixDecimalDebt() public {
        _borrowUsdc(aliceProxy, 13_000e6);
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), usdcReserveId, 1.5e18);
        assertTrue(s.reachable, "reachable");
        assertGt(s.units, 0, "some units");
        assertLt(s.units, 10_000e6, "fewer than the record");
        _assertConsistent(s, usdcReserveId, 1.5e18);
    }

    // TEST-247 verifies: REQ-LENS-055
    function test_TEST_247_deleverageToFromBelowOneRaisesTheTargetToOne() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.85e8);
        assertLt(_hf(aliceProxy), 1e18, "liquidatable now");
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 0.2e18);
        assertTrue(s.reachable, "a deleverage restores 1.00");
        assertGe(s.healthFactorAfter, 1e18, "the target is never below 1.00");
        _assertConsistent(s, debtReserveId, 1e18);
    }

    // TEST-247 verifies: REQ-LENS-055
    function test_TEST_247_deleverageToBeyondTheRecordIsUnreachable() public {
        _pledge(alice, aliceProxy, _key(2), 500e6);
        _borrow(aliceProxy, 12_000e18);
        // The 500-unit record alone cannot lift HF from 1.4 to 3.0.
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(2), debtReserveId, 3e18);
        assertFalse(s.reachable, "too small");
        assertEq(s.units, 0, "no units");
        s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), debtReserveId, 3e18);
        assertTrue(s.reachable, "the large record can");
    }

    // TEST-247 verifies: REQ-LENS-055, REQ-LENS-038
    function test_TEST_247_deleverageToClosedByAStaleDebtPrice() public {
        _borrowUsdc(aliceProxy, 13_000e6);
        usdcOracle.set(0.9999e8, PriceState.Cached, 0.9999e8, uint64(block.timestamp - 5000));
        DeleverageSizing memory s = lens.previewDeleverageTo(alice, MARKET_ID, _key(1), usdcReserveId, 1.5e18);
        assertFalse(s.reachable, "the repaid reserve's price must be liquidation-fresh");
        usdcOracle.set(0.9999e8, PriceState.Live, 0.9999e8, uint64(block.timestamp));
        assertTrue(lens.previewDeleverageTo(alice, MARKET_ID, _key(1), usdcReserveId, 1.5e18).reachable, "fresh again");
    }

    // TEST-247 verifies: REQ-LENS-057
    function test_TEST_247_highCollateralRiskDoublesTheRate() public {
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, 10_000)
        );
        _borrow(aliceProxy, 5000e18);
        vm.warp(block.timestamp + 1 days);
        MarketView memory v = lens.getMarket(MARKET_ID);
        uint256 drawn = lens.getDebtReserve(aave.cdpSpoke, debtReserveId).drawnRateRay;
        assertEq(v.borrowRatesRay[0], Math.mulDiv(drawn, 20_000, 1e4, Math.Rounding.Ceil), "drawn x 2");
        assertEq(v.collateralRiskBps, 10_000, "100 %");
    }

    // TEST-247 verifies: REQ-LENS-057
    function test_TEST_247_disabledDebtReserveLeavesTheRateList() public {
        reg.disableDebtReserve(aave.cdpSpoke, usdcReserveId);
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.debtReserveIds.length, 1, "GHO only");
        assertEq(v.borrowRatesRay.length, 1, "one rate");
        assertEq(v.debtReserveIds[0], debtReserveId, "GHO");
        assertEq(v.hardHealthFloor, 0, "no hard floor by default");
    }
}
