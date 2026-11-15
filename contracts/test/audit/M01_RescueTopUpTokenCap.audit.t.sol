// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title M01 proof of concept: a slice-only rescue top-up is refused by a token or depositor counter above its cap
/// @notice `RiskModulePledgeLogic._caps` tests `fits(T_i, regular, tokenUsdCap)` and `fits(P, regular, depositorUsdCap)`
/// even when `regular == 0`, and `RiskModuleMath.fits` fails whenever `used > cap`. Collateralization books the full
/// `usdCharge` of a slice top-up into every token counter and the depositor counter (`CollateralizationBase._book`), so
/// one rescue top-up into a full market can lift `T_i` above its cap, after which every later rescue top-up on that Hub
/// and token reverts `CapExceeded("TOKEN")`, although its regular part is zero and slice top-ups are meant to be exempt
/// from token and depositor caps. A steward `tightenTokenUsdCap` below current exposure has the same effect at once.
/// @dev Fixture defaults: marketUsdCap $1,000,000, topUpSliceUsd $100,000, tokenUsdCap $10,000,000 for both pool
/// tokens, depositorUsdCap $5,000,000; `TEN_K` units are worth $20,000.
contract M01RescueTopUpTokenCapAuditTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18;

    function setUp() public {
        _deployRiskWorld();
    }

    function test_M01_sliceOnlyRescueBlockedOnceTokenCounterPassesCap() public {
        // Market full: no regular room, so an eligible top-up is charged entirely to the slice.
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_000e8;
        k.tokenUsed[1] = 10_000_000e8; // exactly at the token cap
        _debt(1.02e18, 1_000_000); // HF 1.02 < 1.10, restore amount far above the charge

        // First rescue top-up passes: all $20,000 goes to the slice, regular part 0.
        PledgeCharge memory c = _pledge(TEN_K, k, false);
        assertEq(c.usdCharge, 20_000e8, "charge");
        assertEq(c.sliceUsd, 20_000e8, "all slice");

        // Collateralization._book adds the full charge to the token counter and the slice counter.
        k.tokenUsed[1] += c.usdCharge;
        k.sliceUsed += uint128(c.sliceUsd);
        k.depositorUsed += c.usdCharge;

        // Second identical rescue top-up (any borrower of any market holding this token on the Hub): the slice has
        // $80,000 of room left and the regular part is again 0, yet the token test refuses it.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(TEN_K, k, false);
    }

    function test_M01_tokenCapTightenedBelowExposureBlocksAllRescues() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_000e8;
        k.tokenUsed[1] = 6_000_000e8;
        _debt(1.02e18, 1_000_000);
        // Steward tightens the token cap below current exposure (or to 0, as open PR #71 allows).
        store.setTokenCap(address(hub), address(usdt), 5_000_000e8);
        store.setTokenCap(address(hub), address(usdc), 5_000_000e8);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("TOKEN")));
        _pledge(TEN_K, k, false);
    }

    function test_M01_depositorCounterAboveCapBlocksOwnSecondRescue() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 1_000_000e8;
        k.depositorUsed = 5_000_000e8 + 1; // one earlier slice top-up lifted the depositor past the cap
        _debt(1.02e18, 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("DEPOSITOR")));
        _pledge(TEN_K, k, false);
    }
}
