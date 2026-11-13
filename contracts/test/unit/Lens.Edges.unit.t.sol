// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtPriceView} from "../../src/lens/lens/types/DebtPriceView.sol";
import {LiquidationPreview} from "../../src/lens/lens/types/LiquidationPreview.sol";
import {RecordView} from "../../src/lens/lens/types/RecordView.sol";
import {PendingView} from "../../src/types/PendingView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {LensDebtOracleMock} from "../utils/mocks/LensMocks.sol";

/// @title LensEdgesUnitTest
/// @notice Edge rules of the Lens's shared reads: the smaller collateral price and the larger debt price of
/// SPEC-LIQ-004, a debt route that names no feed, a position out of custody in an account's records, and the
/// pool-share and backing edges.
/// forge-config: default.isolate = false
contract LensEdgesUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    // TEST-069 verifies: SPEC-LIQ-004, REQ-LENS-029, REQ-SWAP-008
    function test_TEST_069_collateralPriceIsTheSmallerOfAaveAndLPOracle() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        LiquidationPreview memory a = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        lpo.setAnswer(true, 1.7e8);
        LiquidationPreview memory b = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        assertEq(b.expectedUnitsSeized, a.expectedUnitsSeized, "Aave sizes with its own price");
        assertLt(b.recoveryFloor, a.recoveryFloor, "the floor values the seizure at the smaller LPOracle price");
        lpo.setAnswer(true, 1.9e8);
        LiquidationPreview memory c = lens.previewLiquidation(aliceProxy, debtReserveId, T0);
        assertEq(c.recoveryFloor, a.recoveryFloor, "a larger LPOracle answer never raises it");
    }

    // TEST-069 verifies: SPEC-LIQ-004, REQ-LENS-026
    function test_TEST_069_debtPriceIsTheLargerOfAaveAndDebtOracle() public {
        _borrow(aliceProxy, 15_000e18);
        _setVtPrice(1.8e8);
        _seizeAndKeep(aliceProxy, 3000e18);
        uint256 owed = _debtOf(aliceProxy, debtReserveId);
        debt.mint(aliceProxy, owed);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, owed);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, owed, aliceProxy);
        vm.stopPrank();
        _withdraw(aliceProxy, _key(1), coll.previewRelease(INTEGRATION, _key(1)));
        reg.setSettlementReserve(MARKET_ID, usdcReserveId);
        uint256 base = lens.getPendingSettlement(vt).valueDebt;
        // The DebtOracle answers above the AaveOracle's price (a different Aave source reads lower).
        vm.mockCall(address(usdcOracle), abi.encodeWithSignature("latestAnswer()"), abi.encode(int256(1.1e8)));
        vm.mockCall(aave.cdpOracle, abi.encodeWithSignature("getReservePrice(uint256)", usdcReserveId), abi.encode(1e8));
        PendingView memory p = lens.getPendingSettlement(vt);
        assertEq(p.valueDebt, p.units * 1.8e8 * 1e6 / (1e6 * 1.1e8), "valued at the larger debt price");
        assertGt(p.units, 0, "units pending");
        assertLt(p.valueDebt, base, "a larger debt price lowers the value");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-030
    function test_TEST_247_debtRouteWithoutFeedIsNeverFresh() public {
        LensDebtOracleMock noFeed = new LensDebtOracleMock(1e8, address(0), address(0));
        vm.mockCall(
            address(reg),
            abi.encodeWithSignature("getDebtReserve(address,uint256)", aave.cdpSpoke, usdcReserveId),
            abi.encode(_def(usdcReserveId, address(usdc), 6, usdcAssetId, address(noFeed), false, usdcCov))
        );
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
        assertEq(v.age, 0, "accepted now");
        assertFalse(v.borrowFresh || v.liquidationFresh, "a route that names no feed has no age limit to meet");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-030
    function test_TEST_247_debtAcceptedInTheFutureCountsAgeZero() public {
        usdcOracle.set(1e8, PriceState.Live, 1e8, uint64(block.timestamp + 100));
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(v.age, 0, "no negative age");
        assertTrue(v.borrowFresh, "fresh");
    }

    // TEST-247 verifies: REQ-LENS-011, REQ-LENS-014
    function test_TEST_247_recordOutOfCustodyReportsZeroLiveUnits() public {
        vm.mockCall(address(lpVault), abi.encodeWithSignature("depositorOf(bytes32)", _key(1)), abi.encode(address(0)));
        RecordView[] memory r = lens.getRecords(aliceProxy, 0, 16);
        assertEq(r[0].liveUnits, 0, "unitsOf is not read for a position out of custody");
        assertEq(r[0].credited, 10_000e6, "the credit is still reported");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-018
    function test_TEST_247_poolShareRoundsUp() public view {
        assertEq(lens.getCapHeadroom(vt, alice).poolShareBps, 1, "credited units round up to 1 bps");
    }

    // TEST-247 verifies: REQ-LENS-012
    function test_TEST_247_feeReceiverAsCdpSpokeFails() public {
        _setAddCap(vtAssetId, aave.treasurySpoke, 0);
        assertTrue(lens.checkBacking(vt).singleBorrowSpoke, "the standard two Spokes");
        vm.mockCall(
            aave.hub,
            abi.encodeWithSignature("getAssetConfig(uint256)", vtAssetId),
            abi.encode(aave.cdpSpoke, uint16(0), aave.irStrategy, address(0))
        );
        assertFalse(lens.checkBacking(vt).singleBorrowSpoke, "a fee receiver that is the CDP Spoke itself");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-009, REQ-LENS-015
    function test_TEST_247_accountPriceStateFollowsTheLPOracle() public {
        lpo.setState(PriceState.Drifting, 0, false);
        assertEq(uint8(lens.getAccount(alice, MARKET_ID).markets[0].priceState), 1, "Drifting");
    }
}
