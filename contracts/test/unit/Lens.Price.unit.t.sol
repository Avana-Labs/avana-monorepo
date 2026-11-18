// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {DebtPriceView} from "../../src/lens/lens/types/LensTypes.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {PriceState, PriceView} from "../../src/types/OracleTypes.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensPriceUnitTest
/// @notice `getPriceState` and `getDebtPriceState`: every price state reported next to the served and accepted prices,
/// never a revert because of a state.
/// forge-config: default.isolate = false
contract LensPriceUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // ─── getPriceState ───

    // TEST-247 verifies: REQ-LENS-015, REQ-LENS-007
    function test_TEST_247_priceStateNegativeAnswerReportsZero() public {
        lpo.setAnswer(true, -5);
        assertEq(lens.getPriceState(vt).price, 0, "a non-positive answer is reported as 0, never a revert");
    }

    // TEST-247 verifies: REQ-LENS-015
    function test_TEST_247_priceStateInputAgesAgainstBothLimits() public {
        store.setAges(feedUsdt, 3600, 4200);
        lpo.setTokenAt(1, uint64(block.timestamp - 4000), 0);
        PriceView memory v = lens.getPriceState(vt);
        assertEq(v.inputs[1].age, 4000, "age");
        assertFalse(v.inputs[1].borrowFresh, "older than the borrow limit");
        assertTrue(v.inputs[1].liquidationFresh, "within the liquidation limit");
        lpo.setTokenAt(1, uint64(block.timestamp - 4201), 0);
        assertFalse(lens.getPriceState(vt).inputs[1].liquidationFresh, "past both");
        lpo.setTokenAt(1, uint64(block.timestamp + 30), 0);
        assertEq(lens.getPriceState(vt).inputs[1].age, 0, "a source time ahead of the block counts age 0");
    }

    // TEST-247 verifies: REQ-LENS-015
    function test_TEST_247_priceStateTwoLegRoute() public {
        address eth = makeAddr("feed ETH/USD");
        store.setAges(eth, 3600, 3600);
        lpo.addToken(address(debt), makeAddr("feed GHO/ETH"), eth, uint64(block.timestamp - 10), 1e8);
        PriceView memory v = lens.getPriceState(vt);
        assertEq(v.inputs.length, 4, "one input per leg of the route in use");
        assertEq(v.inputs[3].feed, eth, "second leg");
        assertEq(v.inputs[3].borrowPriceMaxAge, 3600, "its own limit");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_priceStateUnknownVaultTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryBase.UnknownMarket.selector, 0));
        lens.getPriceState(makeAddr("x"));
    }

    // ─── getDebtPriceState ───

    // TEST-247 verifies: REQ-LENS-030, REQ-LENS-005, Q-238
    function test_TEST_247_debtPriceFixedGho() public view {
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, debtReserveId);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.timestamp, block.timestamp, "timestamp");
        assertEq(v.debtReserveId, debtReserveId, "reserve");
        assertEq(v.source, address(debtPrice), "AaveOracle source");
        assertEq(v.price, 1e8, "$1.00");
        assertTrue(v.fixedPrice, "fixed");
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
        assertEq(v.acceptedPrice, v.price, "accepted = price");
        assertEq(v.updatedAt, block.timestamp, "never stale");
        assertEq(v.age, 0, "age 0");
        assertTrue(v.borrowFresh && v.liquidationFresh, "both fresh");
        assertFalse(v.stressPriced, "never stress-priced");
    }

    // TEST-247 verifies: REQ-LENS-030, REQ-LENS-032
    function test_TEST_247_debtPriceUnknownReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, vtReserveId));
        lens.getDebtPriceState(aave.cdpSpoke, vtReserveId);
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.lendSpoke, 0));
        lens.getDebtPriceState(aave.lendSpoke, 0);
    }

    // TEST-247 verifies: REQ-LENS-030
    function test_TEST_247_debtPriceSourceReportedAsFound() public {
        _spokeConfig(
            abi.encodeWithSignature(
                "updateReservePriceSource(address,uint256,address)", aave.cdpSpoke, usdcReserveId, address(debtPrice)
            )
        );
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(v.source, address(debtPrice), "a different source is reported as found");
        assertEq(uint8(v.state), uint8(PriceState.Live), "state from the recorded DebtOracle");
    }
}
