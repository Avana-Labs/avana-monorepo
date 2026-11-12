// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title RiskModuleBoundariesUnitTest
/// @notice Every numeric gate of the borrow-side checks at its boundary, with the exact error one unit past it: the
/// per-feed collateral age, the debt price age, the health-factor floor, the frozen-reserve supply, Hub shares ==
/// assets, the keeper count and the sequencer grace end (REQ-ADAPTER-016, REQ-RISK-061, REQ-RISK-059, REQ-ADAPTER-019,
/// REQ-ADAPTER-021, REQ-ADAPTER-010, REQ-RISK-081).
contract RiskModuleBoundariesUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
    }

    function _borrow() internal {
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    function _withdraw() internal {
        riskModule.preWithdrawCheck(address(proxy));
    }

    /// @dev Report with the two tokens' legs at their own times.
    function _reportAt(
        uint64 at0,
        uint64 at1
    ) internal {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (at0, at1);
        oracle.setTokens(toks, feeds, ats, new uint256[](2), new uint32[](2));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Collateral feed age (REQ-ADAPTER-016)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-028 verifies: REQ-ADAPTER-016, INV-024
    // Sources: 2.7 REQ-ADAPTER-016 (t_i <= now and now - t_i <= borrowPriceMaxAge(f_i))
    function test_TEST_028_feedAgeBoundaryPerLeg() public {
        uint64 edge = uint64(block.timestamp - FEED_AGE);
        _reportAt(edge, edge);
        _borrow();
        _withdraw();
        // The second leg one second past its limit: its own feed and age are reported.
        _reportAt(edge, edge - 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdt, FEED_AGE + 1));
        _borrow();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdt, FEED_AGE + 1));
        _withdraw();
        // Both past: the first leg in pool order is reported.
        _reportAt(edge - 2, edge - 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, FEED_AGE + 2));
        _borrow();
    }

    // TEST-028 verifies: REQ-ADAPTER-016, REQ-CONFIG-023
    function test_TEST_028_feedAgeUsesEachFeedsOwnLimit() public {
        // USDT's feed has a one-hour heartbeat plus margin; USDC's keeps 88,200 s.
        store.setBorrowAge(feedUsdt, 3600);
        _reportAt(uint64(block.timestamp - 80_000), uint64(block.timestamp - 3600));
        _borrow();
        _reportAt(uint64(block.timestamp - 80_000), uint64(block.timestamp - 3601));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdt, 3601));
        _borrow();
        // A limit of 0 fails every input that is not from this second.
        store.setBorrowAge(feedUsdc, 0);
        _reportAt(uint64(block.timestamp), uint64(block.timestamp));
        _borrow();
        _reportAt(uint64(block.timestamp - 1), uint64(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, 1));
        _borrow();
    }

    // TEST-028 verifies: REQ-ADAPTER-016, INV-024
    function testFuzz_TEST_028_feedAge(
        uint32 age0,
        uint32 age1
    ) public {
        age0 = uint32(bound(age0, 0, 2 * FEED_AGE));
        age1 = uint32(bound(age1, 0, 2 * FEED_AGE));
        _reportAt(uint64(block.timestamp - age0), uint64(block.timestamp - age1));
        if (age0 > FEED_AGE) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, age0));
        } else if (age1 > FEED_AGE) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdt, age1));
        }
        _withdraw();
    }

    // TEST-028 verifies: REQ-ADAPTER-016
    function testFuzz_TEST_028_futureInputNeverFresh(
        uint32 ahead
    ) public {
        ahead = uint32(bound(ahead, 1, type(uint32).max));
        _reportAt(uint64(block.timestamp), uint64(block.timestamp + ahead));
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdt, 0));
        _borrow();
    }

    // TEST-028 verifies: REQ-ADAPTER-016
    function test_TEST_028_unusedLegIsSkipped() public {
        // A token priced through one leg leaves its second slot empty: no age check for address(0).
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        feeds[0] = feedUsdc;
        uint64[] memory ats = new uint64[](2);
        ats[0] = uint64(block.timestamp);
        oracle.setTokens(toks, feeds, ats, new uint256[](2), new uint32[](2));
        _borrow();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Debt price age (REQ-RISK-061)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-201 verifies: REQ-RISK-061, REQ-ADAPTER-055
    function test_TEST_201_debtPriceAgeBoundary() public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        uint32 maxAge = usdcOracle.borrowPriceMaxAge();
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - maxAge), true);
        _borrow();
        _withdraw();
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - maxAge - 1), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), maxAge + 1
            )
        );
        _borrow();
        // Live and fresh but the oracle's own borrow gate closed: refused with the measured age.
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 5), false);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), 5)
        );
        _withdraw();
    }

    // TEST-201 verifies: REQ-RISK-061
    function testFuzz_TEST_201_debtPriceState(
        uint8 state,
        uint32 age,
        bool allowed
    ) public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        state = uint8(bound(state, 0, 3));
        age = uint32(bound(age, 0, 200_000));
        usdcOracle.setReport(PriceState(state), uint64(block.timestamp - age), allowed);
        bool ok = PriceState(state) == PriceState.Live && age <= 88_200 && allowed;
        if (!ok) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), age
                )
            );
        }
        _withdraw();
    }

    // TEST-201 verifies: REQ-RISK-061, REQ-ADAPTER-062
    function test_TEST_201_fixedPriceReserveIsNeverAged() public {
        // GHO is priced at a fixed value: its source must be the recorded one, and no DebtOracle is read or poked.
        vm.warp(block.timestamp + 10 * 88_200);
        _reportAt(uint64(block.timestamp), uint64(block.timestamp));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        _borrow();
        aaveOracle.setSource(GHO_RESERVE, makeAddr("otherGhoSource"));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.UnexpectedDebtPriceSource.selector, GHO_RESERVE, makeAddr("otherGhoSource")
            )
        );
        _withdraw();
    }

    // TEST-201 verifies: REQ-RISK-061, REQ-RISK-056
    function test_TEST_201_debtOracleOfABorrowedReserveIsPoked() public {
        // The reserve borrowed is in scope before it is held: its DebtOracle is poked and its price gated.
        uint256 before = usdcOracle.pokes();
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 1);
        assertEq(usdcOracle.pokes(), before + 1);
        // A withdraw-with-debt of an account that holds no USDC neither pokes nor reads it.
        usdcOracle.setReport(PriceState.Expired, 0, false);
        _withdraw();
        assertEq(usdcOracle.pokes(), before + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), block.timestamp
            )
        );
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 1);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Health floor (REQ-RISK-059, REQ-RISK-068)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-236 verifies: REQ-RISK-059, REQ-ADAPTER-027, SPEC-CF-005
    function test_TEST_236_healthFloorBoundary() public {
        // Required level max(1.00, hardHealthFloor, minHealthFactor): equal passes, one wei below reverts.
        _debt(1.25e18, 1000);
        store.setHardFloor(mid, 1.25e18);
        assertEq(riskModule.postHealthCheck(address(proxy), 1.1e18), 1.25e18);
        _debt(1.25e18 - 1, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.25e18 - 1, 1.25e18));
        riskModule.postHealthCheck(address(proxy), 1.1e18);
        // The caller's minimum above the floor sets the level.
        _debt(1.3e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1.3e18, 1.3e18 + 1));
        riskModule.postHealthCheck(address(proxy), 1.3e18 + 1);
        // Both below Aave's 1.00: the level is 1.00.
        store.setHardFloor(mid, 0.5e18);
        _debt(1e18 - 1, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, 1e18 - 1, 1e18));
        riskModule.postHealthCheck(address(proxy), 0.9e18);
    }

    // TEST-236 verifies: REQ-RISK-059, SPEC-CF-005
    function testFuzz_TEST_236_healthFloor(
        uint96 hf,
        uint96 hardFloor,
        uint96 minHf
    ) public {
        _debt(hf, 1000);
        store.setHardFloor(mid, hardFloor);
        uint256 required = 1e18;
        if (hardFloor > required) required = hardFloor;
        if (minHf > required) required = minHf;
        if (hf < required) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hf, required));
        }
        riskModule.postHealthCheck(address(proxy), minHf);
    }

    // TEST-236 verifies: REQ-RISK-059
    function test_TEST_236_debtFreeAccountPasses() public {
        // Aave reports type(uint256).max for an account without debt.
        rSpoke.setAccount(address(proxy), type(uint256).max, 0, 0);
        assertEq(riskModule.postHealthCheck(address(proxy), type(uint256).max), type(uint256).max);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Frozen reserve, Hub shares, keepers (REQ-ADAPTER-019, REQ-ADAPTER-021, REQ-ADAPTER-010)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-155 verifies: REQ-ADAPTER-019, INV-023
    function testFuzz_TEST_155_frozenReserveNeedsSuppliedShares(
        uint256 shares
    ) public {
        shares = bound(shares, 0, 1e30);
        IAaveV4Spoke.ReserveConfig memory v;
        v.frozen = true;
        rSpoke.setConfig(VT_RESERVE, v);
        rSpoke.setSupplied(address(proxy), VT_RESERVE, shares);
        if (shares > 0) vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, VT_RESERVE));
        _borrow();
        // A frozen reserve never blocks withdraw-with-debt.
        _withdraw();
    }

    // TEST-028 verifies: REQ-ADAPTER-021, REQ-ADAPTER-037
    function testFuzz_TEST_028_hubSharesExactlyEqual(
        uint128 assets,
        uint128 shares
    ) public {
        rHub.setAdded(VT_ASSET, assets, shares);
        assertEq(riskModule.isHubSharesEqualAssets(mid), assets == shares);
        if (assets != shares) {
            vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HubSharesNotEqualAssets.selector, mid));
        }
        _withdraw();
    }

    // TEST-068 verifies: REQ-ADAPTER-010, REQ-RISK-071
    function testFuzz_TEST_068_anyActiveKeeperSuffices(
        uint256 keepers
    ) public {
        keepers = bound(keepers, 0, 1000);
        swap.setKeepers(keepers);
        if (keepers == 0) vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        _borrow();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Sequencer grace end (REQ-RISK-081)
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-275 verifies: REQ-RISK-081
    function test_TEST_275_graceEndsExactlyAtStartPlusPeriod() public {
        RiskSequencerFeed feed = new RiskSequencerFeed();
        store.setSequencer(address(feed), 3600);
        uint256 started = block.timestamp - 3599;
        feed.set(0, started, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SequencerGrace.selector, started + 3600));
        _borrow();
        vm.warp(block.timestamp + 1);
        _reportAt(uint64(block.timestamp), uint64(block.timestamp));
        _borrow();
        // The status never reverts on the sequencer: it reports both actions refused.
        feed.set(1, block.timestamp, false);
        AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
        assertFalse(s.statusUnavailable);
        assertFalse(s.borrowAllowed);
        assertFalse(s.withdrawWithDebtAllowed);
        // A feed whose read reverts is down.
        feed.set(0, 1, true);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        _withdraw();
    }

    // TEST-275 verifies: REQ-RISK-081
    function testFuzz_TEST_275_unknownAnswerIsDown(
        int256 answer
    ) public {
        vm.assume(answer != 0);
        RiskSequencerFeed feed = new RiskSequencerFeed();
        store.setSequencer(address(feed), 3600);
        feed.set(answer, 1, false);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        _borrow();
    }
}
