// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {DebtPriceView} from "../../src/lens/lens/types/DebtPriceView.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceView} from "../../src/types/PriceView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensPriceUnitTest
/// @notice `getPriceState`, `getDebtPriceState`, `getApplicationState` and `getPauseReason`: every price state
/// reported next to the served and accepted prices, never a revert because of a state.
/// forge-config: default.isolate = false
contract LensPriceUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    // ─── getPriceState ───

    // TEST-247 verifies: REQ-LENS-015, REQ-LENS-005
    function test_TEST_247_priceStateLive() public view {
        PriceView memory v = lens.getPriceState(vt);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.timestamp, block.timestamp, "timestamp");
        assertEq(v.vaultToken, vt, "market");
        assertEq(v.feed, address(lpo), "the market's LPOracle");
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
        assertEq(uint8(v.liquidationState), uint8(PriceState.Live), "seizable");
        assertEq(v.price, 2e8, "served = latestAnswer");
        assertEq(v.acceptedPrice, 2e8, "accepted");
        assertEq(v.acceptedAt, T0 - 600, "accepted at");
        assertEq(v.inputs.length, 2, "one leg per token");
        assertEq(v.inputs[0].feed, feedUsdc, "USDC feed");
        assertEq(v.inputs[1].feed, feedUsdt, "USDT feed");
        assertEq(v.inputs[0].updatedAt, T0 - 600, "source timestamp");
        assertEq(v.inputs[0].age, 600, "age");
        assertEq(v.inputs[0].borrowPriceMaxAge, FEED_AGE, "borrow limit from the ParameterStore");
        assertEq(v.inputs[0].liquidationPriceMaxAge, FEED_AGE, "liquidation limit");
        assertTrue(v.inputs[0].borrowFresh && v.inputs[0].liquidationFresh, "fresh");
        assertEq(v.tokenDeviationBps.length, 2, "one deviation per token");
        assertEq(v.graceHealthFactor, 0.95e18, "grace HF from the ParameterStore");
        assertTrue(v.borrowAllowed, "borrow allowed");
    }

    // TEST-247 verifies: REQ-LENS-015, REQ-LENS-007
    function test_TEST_247_priceStateEveryStateReported() public {
        for (uint8 s = 0; s < 4; ++s) {
            lpo.setState(PriceState(s), 0, s >= 2);
            PriceView memory v = lens.getPriceState(vt);
            assertEq(uint8(v.state), s, "state");
            assertEq(uint8(v.liquidationState), s, "no disagreement: the same state");
        }
    }

    // TEST-247 verifies: REQ-LENS-015, REQ-ORACLE-085
    function test_TEST_247_priceStateExpiredServesOne() public {
        lpo.setState(PriceState.Expired, 0, true);
        lpo.setAnswer(true, 1);
        PriceView memory v = lens.getPriceState(vt);
        assertEq(v.price, 1, "worthless collateral");
        assertEq(v.acceptedPrice, 2e8, "the accepted price is kept");
        assertLe(v.price, v.acceptedPrice, "served at most accepted when not Live");
    }

    // TEST-247 verifies: REQ-LENS-015, REQ-LENS-007
    function test_TEST_247_priceStateNegativeAnswerReportsZero() public {
        lpo.setAnswer(true, -5);
        assertEq(lens.getPriceState(vt).price, 0, "a non-positive answer is reported as 0, never a revert");
    }

    // TEST-247 verifies: REQ-LENS-015, Q-208, Q-247
    function test_TEST_247_priceStateDisagreementPauseIsDrifting() public {
        lpo.setDisagreement(1_762_696_000, true, false);
        lpo.setAnswer(true, 197_483_855);
        lpo.setAccepted(199_980_000, uint64(block.timestamp - 100));
        lpo.setTokenRoute(1, 0, 250);
        PriceView memory v = lens.getPriceState(vt);
        assertEq(uint8(v.state), uint8(PriceState.Live), "the market is Live");
        assertEq(uint8(v.liquidationState), uint8(PriceState.Drifting), "the seizure is paused");
        assertTrue(v.disagreementPauseActive, "pause active");
        assertEq(v.disagreeSince, 1_762_696_000, "first observation");
        assertEq(v.price, 197_483_855, "lower route");
        assertEq(v.acceptedPrice, 199_980_000, "accepted");
        assertEq(v.tokenDeviationBps[1], 250, "USDT routes 2.5 % apart");
    }

    // TEST-247 verifies: REQ-LENS-015, Q-208
    function test_TEST_247_priceStateDisagreementExpiredIsExpired() public {
        lpo.setDisagreement(1_762_696_000, false, true);
        PriceView memory v = lens.getPriceState(vt);
        assertTrue(v.disagreementExpired, "past disagreementPauseMax");
        assertEq(uint8(v.liquidationState), uint8(PriceState.Expired), "treated as Expired for liquidation");
        lpo.setState(PriceState.Cached, 0, true);
        assertEq(uint8(lens.getPriceState(vt).liquidationState), uint8(PriceState.Expired), "even when Cached");
    }

    // TEST-247 verifies: REQ-LENS-015, REQ-ORACLE-090
    function test_TEST_247_priceStateAlternatePastBorrowAgeIsCached() public {
        lpo.setState(PriceState.Drifting, 1 << 12, true);
        assertEq(uint8(lens.getPriceState(vt).liquidationState), uint8(PriceState.Cached), "alternate leg too old");
        lpo.setState(PriceState.Live, 1 << 12, true);
        assertEq(uint8(lens.getPriceState(vt).liquidationState), uint8(PriceState.Cached), "from Live too");
        lpo.setState(PriceState.Expired, 1 << 12, true);
        assertEq(uint8(lens.getPriceState(vt).liquidationState), uint8(PriceState.Expired), "Expired stays");
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

    // TEST-247 verifies: REQ-LENS-015, REQ-SWAP-009
    function test_TEST_247_priceStateGraceAndBorrowGate() public {
        lpo.setGrace(true, uint64(block.timestamp - 60), uint64(block.timestamp + 1740));
        lpo.setBorrowAllowed(false);
        store.setGraceHealthFactor(0.97e18);
        PriceView memory v = lens.getPriceState(vt);
        assertEq(v.recoveredAt, block.timestamp - 60, "recovered at");
        assertEq(v.graceEndsAt, block.timestamp + 1740, "recoveredAt + graceDuration");
        assertEq(v.graceHealthFactor, 0.97e18, "grace health factor");
        assertFalse(v.borrowAllowed, "sequencer or second-source gate closed");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_priceStateUnknownVaultTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 0));
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

    // TEST-247 verifies: REQ-LENS-030, Q-248, Q-274
    function test_TEST_247_debtPriceOracleExampleLiveThenCached() public {
        usdcOracle.set(99_990_000, PriceState.Live, 99_990_000, 1_762_696_000);
        vm.warp(1_762_697_800);
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(v.source, address(usdcOracle), "DebtOracle");
        assertFalse(v.fixedPrice, "not fixed");
        assertEq(v.age, 1800, "age");
        assertTrue(v.borrowFresh && v.liquidationFresh, "within 4,200 s");
        assertEq(v.price, 99_990_000, "served");
        vm.warp(1_762_700_500);
        usdcOracle.set(99_990_000, PriceState.Cached, 99_990_000, 1_762_696_000);
        v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(uint8(v.state), uint8(PriceState.Cached), "Cached");
        assertEq(v.price, v.acceptedPrice, "served = accepted while Cached");
        assertFalse(v.borrowFresh || v.liquidationFresh, "neither");
    }

    // TEST-247 verifies: REQ-LENS-030, SPEC-ORC-018
    function test_TEST_247_debtPriceExpiredStress() public {
        usdcOracle.set(104_989_500, PriceState.Expired, 99_990_000, uint64(block.timestamp - 90_000));
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(v.price, 104_989_500, "ceil(99,990,000 x 10,500 / 1e4)");
        assertTrue(v.stressPriced, "served above accepted");
        assertGe(v.price, v.acceptedPrice, "debt served at least accepted");
        assertFalse(v.borrowFresh, "not Live");
    }

    // TEST-247 verifies: REQ-LENS-030
    function test_TEST_247_debtPriceLiveButOld() public {
        usdcOracle.set(1e8, PriceState.Live, 1e8, uint64(block.timestamp - 4201));
        DebtPriceView memory v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertEq(uint8(v.state), uint8(PriceState.Live), "Live");
        assertFalse(v.borrowFresh, "older than borrowPriceMaxAge");
        assertFalse(v.liquidationFresh, "older than liquidationPriceMaxAge");
        store.setAges(feedUsdcDebt, 4000, 5000);
        v = lens.getDebtPriceState(aave.cdpSpoke, usdcReserveId);
        assertFalse(v.borrowFresh, "4,201 > 4,000");
        assertTrue(v.liquidationFresh, "4,201 <= 5,000");
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

    // ─── pause state and reason ───

    // TEST-162 verifies: REQ-LENS-031, Q-227, Q-252
    function test_TEST_162_applicationStateAndReason() public {
        assertEq(uint8(lens.getApplicationState(aave.hub)), uint8(PauseState.None), "None");
        assertEq(lens.getPauseReason(aave.hub), 0, "no reason");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        assertEq(uint8(lens.getApplicationState(aave.hub)), uint8(PauseState.Frozen), "Frozen");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        assertEq(uint8(lens.getApplicationState(aave.hub)), uint8(PauseState.Paused), "Paused");
        assertEq(lens.getPauseReason(aave.hub), 1, "General");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        assertEq(lens.getPauseReason(aave.hub), 2, "MintPathSuspect");
    }

    // TEST-162 verifies: REQ-LENS-031
    function test_TEST_162_pauseStatePerHub() public {
        address hub2 = makeAddr("hub2");
        reg.setPause(hub2, PauseState.Paused, PauseReason.General);
        assertEq(uint8(lens.getApplicationState(aave.hub)), uint8(PauseState.None), "the first Hub is open");
        assertEq(uint8(lens.getApplicationState(hub2)), uint8(PauseState.Paused), "the second is paused");
    }

    // TEST-162 verifies: REQ-LENS-031, REQ-LENS-016
    function test_TEST_162_pauseNeverBlocksTheViews() public {
        _open(alice, aliceProxy, 1, 10_000e6);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        lens.getAccount(alice, MARKET_ID);
        lens.checkBacking(vt);
        lens.getPriceState(vt);
        assertTrue(lens.previewLiquidation(aliceProxy, debtReserveId, T0).pricesUsable, "liquidation open");
    }
}
