// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtPriceView, LiquidationPreview, RecordView} from "../../src/lens/lens/types/LensTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {PendingView} from "../../src/types/PositionTypes.sol";
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
}
