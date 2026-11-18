// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {DriftReason} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {PledgeCounters} from "../../src/types/PositionTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModulePledgeUnitTest
/// @notice `checkPledge`: eligibility, price state, new-account checks, the minimum value, the Aave pre-checks, the caps
/// and the slice, the pool-share cap, the market breaker and the rescue rule, on the real MarketRegistry.
contract RiskModulePledgeUnitTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18; // $20,000 at $2.00 per whole token

    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-010 verifies: REQ-RISK-025, REQ-RISK-026, SPEC-CAP-001
    // Sources: 2.7 LIFECYCLE step 2
    function test_TEST_010_newAccountPledgeReturnsCharge() public {
        PledgeCharge memory c = _pledge(TEN_K, _counters(), false);
        assertEq(c.usdCharge, 20_000e8);
        assertEq(c.sliceUsd, 0);
        assertFalse(c.rescue);
        assertEq(c.rescueUnits, 0);
    }

    // TEST-012 verifies: REQ-RISK-009, REQ-RISK-014, INV-026, REQ-ACCESS-036, REQ-VAULT-144, REQ-RISK-034
    function test_TEST_012_offboardingAndNotActive() public {
        vm.prank(address(timelock));
        registry.setMarketOffboarding(mid);
        PledgeCounters memory k = _counters();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, mid));
        _pledge(TEN_K, k, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.MarketNotActive.selector, mid + 1));
        riskModule.checkPledge(wallet, address(proxy), mid + 1, V3, bytes32(0), TEN_K, k, false);
    }

    // TEST-012 verifies: REQ-RISK-010, REQ-RISK-013
    function test_TEST_012_integrationAndZeroUnits() public {
        PledgeCounters memory k = _counters();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.IntegrationMismatch.selector, mid, uint32(2)));
        riskModule.checkPledge(wallet, address(proxy), mid, 2, bytes32(0), TEN_K, k, false);
        vm.expectRevert(IRiskModuleErrors.ZeroLiquidity.selector);
        _pledge(0, k, false);
    }

    // TEST-012 verifies: REQ-RISK-018, REQ-RISK-019, REQ-RISK-050, INV-029, REQ-RISK-028
    function test_TEST_012_newAccountChecksSkippedForTopUps() public {
        PledgeCounters memory k = _counters();
        // Hub shares != assets.
        rHub.setAdded(VT_ASSET, 100, 99);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HubSharesNotEqualAssets.selector, mid));
        _pledge(TEN_K, k, false);
        _debt(1.5e18, 1000);
        _pledge(TEN_K, k, false);
        rHub.setAdded(VT_ASSET, 0, 0);
        // A paused enabled debt reserve.
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        IAaveV4Spoke.ReserveConfig memory c;
        (c.borrowable, c.paused) = (true, true);
        rSpoke.setConfig(GHO_RESERVE, c);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, GHO_RESERVE));
        _pledge(TEN_K, k, false);
        _debt(1.5e18, 1000);
        _pledge(TEN_K, k, false);
    }

    // TEST-033 verifies: REQ-RISK-018, REQ-RISK-069, REQ-RISK-076, INV-029
    function test_TEST_033_newAccountDriftReverts() public {
        PledgeCounters memory k = _counters();
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3300, 10_500);
        spoke.setDynamic(VT_RESERVE, d);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.ConfigDrift.selector, mid, DriftReason.CollateralFactorAboveExpected
            )
        );
        _pledge(TEN_K, k, false);
        // A top-up of an indebted account passes the drift.
        _debt(1.5e18, 1000);
        _pledge(TEN_K, k, false);
    }

    // TEST-012 verifies: REQ-RISK-020
    function test_TEST_012_aavePreChecks() public {
        PledgeCounters memory k = _counters();
        IAaveV4Spoke.ReserveConfig memory c;
        c.frozen = true;
        rSpoke.setConfig(VT_RESERVE, c);
        vm.expectRevert(IRiskModuleErrors.AaveReserveUnavailable.selector);
        _pledge(TEN_K, k, false);
        c.frozen = false;
        rSpoke.setConfig(VT_RESERVE, c);
        rHub.setActive(VT_ASSET, address(spoke), true, true);
        vm.expectRevert(IRiskModuleErrors.HubSpokeUnavailable.selector);
        _pledge(TEN_K, k, false);
        rHub.setActive(VT_ASSET, address(spoke), true, false);
        // addCap 2,000,000 whole tokens: 1,999,999 added + 2 tokens exceeds it.
        rHub.setAdded(VT_ASSET, 1_999_999e18, 1_999_999e18);
        vm.expectRevert(IRiskModuleErrors.HubAddCapReached.selector);
        _pledge(2e18 + 5e18, k, false);
        rHub.setAdded(VT_ASSET, 0, 0);
        // Reserve limit when the reserve is not yet collateral.
        rSpoke.setStatus(address(proxy), VT_RESERVE, false, false);
        rSpoke.setStatus(address(proxy), GHO_RESERVE, true, false);
        rSpoke.setUserLimit(1);
        vm.expectRevert(IRiskModuleErrors.UserReservesLimit.selector);
        _pledge(TEN_K, k, false);
    }

    // TEST-012 verifies: REQ-RISK-020
    function test_TEST_012_reserveLimitOnlyForNewCollateral() public {
        PledgeCounters memory k = _counters();
        // Not yet collateral, and the Spoke sets no per-account limit: no count is taken.
        rSpoke.setStatus(address(proxy), VT_RESERVE, false, false);
        rSpoke.setStatus(address(proxy), GHO_RESERVE, true, false);
        assertEq(_pledge(TEN_K, k, false).usdCharge, 20_000e8);
        // A limit of 2 with one collateral reserve in use leaves room for this one.
        rSpoke.setUserLimit(2);
        assertEq(_pledge(TEN_K, k, false).usdCharge, 20_000e8);
        rSpoke.setUserLimit(1);
        vm.expectRevert(IRiskModuleErrors.UserReservesLimit.selector);
        _pledge(TEN_K, k, false);
        // Already collateral: the limit is not read.
        rSpoke.setStatus(address(proxy), VT_RESERVE, true, false);
        assertEq(_pledge(TEN_K, k, false).usdCharge, 20_000e8);
    }

    // TEST-196 verifies: REQ-RISK-057, REQ-RISK-064, SPEC-CAP-001, INV-069, REQ-RISK-008
    // Sources: 5.1 TEST-196 example (d = 18, price8 = 2.00e8)
    function test_TEST_196_minimumPledgeValue() public {
        PledgeCounters memory k = _counters();
        assertEq(_pledge(5e18, k, false).usdCharge, 10e8);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 998_000_000, 1_000_000_000));
        _pledge(4.99e18, k, false);
        _debt(1.5e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 998_000_000, 1_000_000_000));
        _pledge(4.99e18, k, false);
        store.setMinPledge(mid, 0);
        _pledge(1, k, false);
    }

    // TEST-235 verifies: REQ-RISK-066, REQ-RISK-067, REQ-RISK-057, INV-069
    // Sources: 2.7 REQ-RISK-057 example (minPledgeUsd $50, rescue minimum $10)
    function test_TEST_235_raisedMinimumAndRescue() public {
        store.setMinPledge(mid, 50e8);
        PledgeCounters memory k = _counters();
        // $12 ordinary top-up of a healthy account reverts with the minimum as the only reason.
        _debt(1.5e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 1_200_000_000, 5_000_000_000));
        _pledge(6e18, k, false);
        // $12 rescue top-up of an account at HF 1.02 passes as rescue with all units rescue units.
        _debt(1.02e18, 10_000);
        PledgeCharge memory c = _pledge(6e18, k, false);
        assertTrue(c.rescue);
        assertEq(c.rescueUnits, 6e18);
        // $9 reverts against the rescue minimum whatever the account.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 900_000_000, 1_000_000_000));
        _pledge(4.5e18, k, false);
    }

    // TEST-235 verifies: REQ-RISK-066, REQ-RISK-074, SPEC-CAP-003
    // Sources: 2.7 REQ-RISK-066 example (hf 1.02, $10,000 debt, CF 3,000, restoreBooked $2,666.67)
    function test_TEST_235_requireRescue() public {
        PledgeCounters memory k = _counters();
        _debt(1.02e18, 10_000);
        assertEq(riskModule.usdToRestore(address(proxy)), 266_666_666_667);
        PledgeCharge memory c = _pledge(1000e18, k, true); // $2,000
        assertTrue(c.rescue);
        assertEq(c.rescueUnits, 1000e18);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.NotRescueTopUp.selector, 1.02e18, 300_000_000_000, 266_666_666_667)
        );
        _pledge(1500e18, k, true); // $3,000
        // A new account's $1,000 pledge under requireRescue.
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.NotRescueTopUp.selector, type(uint256).max, 100_000_000_000, 0)
        );
        _pledge(500e18, k, true);
    }

    // TEST-013 verifies: REQ-RISK-021, REQ-RISK-024, REQ-RISK-080, SPEC-CAP-002, INV-028, REQ-RISK-087
    // Sources: 2.7 REQ-RISK-080 example (whale holds $900,000 of $1,000,000)
    function test_TEST_013_marketCapAndSquatting() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 900_000e8;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("MARKET")));
        _pledge(250_000e18, k, false); // $500,000
        assertEq(_pledge(50_000e18, k, false).usdCharge, 100_000e8);
    }

    // TEST-272 verifies: REQ-RISK-079, REQ-RISK-021, SPEC-CAP-002, INV-028
    // Sources: 2.7 REQ-RISK-079 example (tokenUsdCap $10,000,000, $9,500,000 used)
    function test_TEST_272_tokenCaps() public {
        PledgeCounters memory k = _counters();
        store.setCaps(mid, 100_000_000e8, 100_000e8, 1e8);
        k.tokenUsed[1] = 9_500_000e8;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(300_000e18, k, false); // $600,000
        k.tokenUsed = new uint256[](1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(TEN_K, k, false);
    }

    // TEST-013 verifies: REQ-RISK-022, REQ-RISK-051, SPEC-CAP-002, SPEC-CAP-003, INV-028
    // Sources: 2.7 SPEC-CAP-002 example (R = $990,000, eligible top-up of $20,000)
    function test_TEST_013_sliceForEligibleTopUp() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 990_000e8;
        _debt(1.02e18, 1_000_000); // restore far above the charge
        PledgeCharge memory c = _pledge(TEN_K, k, false);
        assertEq(c.usdCharge, 20_000e8);
        assertEq(c.sliceUsd, 10_000e8);
        assertFalse(c.rescue);
        assertEq(c.rescueUnits, TEN_K / 2);
        // Slice above the restore amount.
        _debt(1.0999e18, 1000);
        vm.expectRevert(IRiskModuleErrors.SliceNotAvailable.selector);
        _pledge(TEN_K, k, false);
        // Slice cap.
        _debt(1.02e18, 1_000_000);
        k.sliceUsed = 95_000e8;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("SLICE")));
        _pledge(TEN_K, k, false);
        // Healthy top-up (HF above 1.10) and a new account need regular room.
        k.sliceUsed = 0;
        _debt(1.2e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("MARKET")));
        _pledge(TEN_K, k, false);
    }

    // TEST-272 verifies: REQ-RISK-022, REQ-RISK-066, SPEC-CAP-002, SPEC-CAP-003
    /// @notice Market full and USDT exactly at its cap: an eligible top-up is charged entirely to the slice and passes.
    /// Collateralization then books the full charge into the token counter, lifting it above the cap; a second
    /// identical top-up still passes, because the token test applies to the regular part only.
    function test_TEST_272_sliceOnlyRescuePassesWithTheTokenCounterAtOrAboveItsCap() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_000e8;
        k.tokenUsed[1] = 10_000_000e8;
        _debt(1.02e18, 1_000_000);
        PledgeCharge memory c = _pledge(TEN_K, k, false);
        assertEq(c.usdCharge, 20_000e8, "charge");
        assertEq(c.sliceUsd, 20_000e8, "all in the slice");
        k.tokenUsed[0] += c.usdCharge;
        k.tokenUsed[1] += c.usdCharge;
        k.sliceUsed += uint128(c.sliceUsd);
        c = _pledge(TEN_K, k, false);
        assertEq(c.sliceUsd, 20_000e8, "second top-up above the token cap");
        assertEq(c.rescueUnits, TEN_K, "every unit is a rescue unit");
    }

    // TEST-272 verifies: REQ-RISK-022, REQ-RISK-042, REQ-RISK-066, SPEC-CAP-002
    /// @notice Both token caps tightened to 0 with $6,000,000 of exposure booked and the market full: a slice-only
    /// rescue top-up passes, while a new-account pledge is refused.
    function test_TEST_272_sliceOnlyRescuePassesAtAZeroTokenCap() public {
        store.setTokenCap(address(hub), address(usdc), 0);
        store.setTokenCap(address(hub), address(usdt), 0);
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_000e8;
        k.tokenUsed[0] = 6_000_000e8;
        k.tokenUsed[1] = 6_000_000e8;
        _debt(1.02e18, 1_000_000);
        PledgeCharge memory c = _pledge(TEN_K, k, false);
        assertEq(c.sliceUsd, 20_000e8, "slice-only top-up passes at a zero token cap");
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("MARKET")));
        _pledge(TEN_K, k, false);
    }

    // TEST-272 verifies: REQ-RISK-022, REQ-RISK-042, REQ-RISK-066, SPEC-CAP-002, SPEC-CAP-003
    /// @notice USDT's token cap tightened to 0 with $500,000 booked, and the market with $900,000 of regular room: an
    /// eligible top-up within the slice is charged entirely to the slice and passes, a new-account pledge and a healthy
    /// top-up are refused `CapExceeded(TOKEN)`. With token room short of the charge, the slice takes the rest.
    function test_TEST_272_zeroTokenCapWithMarketRoomLeavesRescueTopUpsToTheSlice() public {
        store.setTokenCap(address(hub), address(usdt), 0);
        PledgeCounters memory k = _counters();
        k.regularUsed = 100_000e8;
        k.tokenUsed[0] = 500_000e8;
        k.tokenUsed[1] = 500_000e8;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(TEN_K, k, false); // new account
        _debt(1.2e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(TEN_K, k, false); // healthy top-up: not eligible for the slice
        _debt(1.02e18, 1_000_000);
        PledgeCharge memory c = _pledge(TEN_K, k, false);
        assertEq(c.usdCharge, 20_000e8, "charge");
        assertEq(c.sliceUsd, 20_000e8, "all in the slice despite the market room");
        assertFalse(c.rescue);
        assertEq(c.rescueUnits, TEN_K, "every unit is a rescue unit");
        // USDC with $5,000 of room and USDT reopened with $8,000: the regular part is the smaller room.
        store.setTokenCap(address(hub), address(usdc), 505_000e8);
        store.setTokenCap(address(hub), address(usdt), 508_000e8);
        c = _pledge(TEN_K, k, false);
        assertEq(c.sliceUsd, 15_000e8, "slice takes what the tightest token refuses");
        assertEq(c.rescueUnits, TEN_K * 3 / 4);
    }

    // TEST-272 verifies: REQ-RISK-022, REQ-RISK-042, SPEC-CAP-002, SPEC-CAP-003
    /// @notice A top-up larger than the regular room plus the slice room is refused: $5,000 of token room and $10,000
    /// of slice room cannot take a $20,000 charge (`CapExceeded(SLICE)`), and at a zero token cap a slice part above
    /// the restore amount reverts `SliceNotAvailable`.
    function test_TEST_272_topUpAboveRegularRoomPlusSliceIsRefused() public {
        store.setTokenCap(address(hub), address(usdc), 505_000e8);
        PledgeCounters memory k = _counters();
        k.regularUsed = 100_000e8;
        k.tokenUsed[0] = 500_000e8;
        k.sliceUsed = 90_000e8;
        _debt(1.02e18, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("SLICE")));
        _pledge(TEN_K, k, false);
        assertEq(_pledge(7500e18, k, false).sliceUsd, 10_000e8, "$15,000: $5,000 regular and $10,000 slice fit");
        store.setTokenCap(address(hub), address(usdc), 0);
        k.sliceUsed = 0;
        _debt(1.0999e18, 1000);
        vm.expectRevert(IRiskModuleErrors.SliceNotAvailable.selector);
        _pledge(TEN_K, k, false);
    }

    // TEST-272 verifies: REQ-RISK-021, REQ-RISK-079, SPEC-CAP-002
    /// @notice USDT at its cap, then at a zero cap, with $10,000 of market room: a pledge not eligible for the slice
    /// (a new account, a healthy top-up) has a regular part and is refused `CapExceeded(TOKEN)`; an eligible top-up of
    /// the same $20,000 has no token room, so it is charged entirely to the slice.
    function test_TEST_272_anyRegularPartIsRefusedWithTheTokenAtItsCap() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 990_000e8;
        k.tokenUsed[1] = 10_000_000e8;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(1000e18, k, false); // new account, $2,000
        _debt(1.2e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(1000e18, k, false); // healthy top-up
        _debt(1.02e18, 1_000_000);
        assertEq(_pledge(TEN_K, k, false).sliceUsd, 20_000e8, "eligible: no regular part");
        store.setTokenCap(address(hub), address(usdt), 0);
        _debt(1.2e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(1000e18, k, false);
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(1000e18, k, false);
    }

    // TEST-228 verifies: REQ-RISK-065, REQ-RISK-073, SPEC-BRK-008, INV-081
    function test_TEST_228_liveMarketReasonOnPledge() public {
        // The USDT issuer probe trips: the market breaker holds `ISSUER`.
        tUsdt.setPaused(true, false);
        PledgeCounters memory k = _counters();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.ISSUER));
        _pledge(TEN_K, k, false);
        // A healthy top-up is refused too.
        _debt(1.5e18, 1000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.ISSUER));
        _pledge(TEN_K, k, false);
        // A rescue top-up passes the breaker.
        _debt(1.02e18, 1_000_000);
        assertTrue(_pledge(TEN_K, k, false).rescue);
        // Cleared, the healthy top-up passes in the same block, with no reset.
        tUsdt.setPaused(false, false);
        _debt(1.5e18, 1000);
        assertFalse(_pledge(TEN_K, k, false).rescue);
    }

    // TEST-164 verifies: REQ-RISK-006, REQ-RISK-026, SPEC-CAP-001
    // Sources: 2.7 SPEC-CAP-001 examples (stress floor at a depressed price)
    function test_TEST_164_chargeAtStressFloor() public {
        oracle.setPrices(0.8e8, 0.8e8);
        PledgeCharge memory c = _pledge(50_000e18, _counters(), false);
        assertEq(c.usdCharge, 50_000e8);
        oracle.setPrices(1.9999e8, 1.9999e8);
        assertEq(_pledge(50_000e18, _counters(), false).usdCharge, 99_995e8);
    }
}
