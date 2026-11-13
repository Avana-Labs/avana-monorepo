// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModulePriceStateRowsUnitTest
/// @notice The RiskModule's share of the USD-band breach (TEST-043) and of the persistent disagreement (TEST-157): how
/// the reviewed RiskModule, on the real MarketRegistry, gates borrow, withdraw-with-debt and pledges on the LPOracle's
/// reported state and reasons. The LPOracle is the fixture's settable report (`RiskLPOracleMock`); the oracle's own
/// state machine is the LPOracle suite's subject.
contract RiskModulePriceStateRowsUnitTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18;
    uint32 internal constant USD_BAND = 1 << 3;
    uint32 internal constant ANY_TOKEN_DISAGREE = 1 << 2;

    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-043 verifies: REQ-ADAPTER-015, REQ-RISK-017, REQ-RISK-048, INV-026
    // Sources: 5.1 TEST-043 (RiskModule side), Q-176, Q-195
    /// @notice With the routes fresh and in agreement and the LP's USD level outside the band (Drifting for the USD
    /// band only): a borrow and a withdrawal that leaves debt revert `PriceNotLive(market, Drifting)`; a new-account
    /// pledge and a top-up of an indebted account still pass; once the level is back inside the band (Live) the
    /// borrow passes again.
    function test_TEST_043_usdBandBreachBlocksBorrowingOnly() public {
        _debt(1.5e18, 1000);
        oracle.setState(PriceState.Drifting, USD_BAND, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Drifting));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Drifting));
        riskModule.preWithdrawCheck(address(proxy));
        // A top-up of the indebted account continues.
        PledgeCharge memory topUp = _pledge(TEN_K, _counters(), false);
        assertGt(topUp.usdCharge, 0, "top-up booked");
        // A new account's pledge continues under a band-only breach.
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, false);
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        PledgeCharge memory fresh = _pledge(TEN_K, _counters(), false);
        assertGt(fresh.usdCharge, 0, "new-account pledge booked");
        // Back inside the band: borrowing resumes.
        _debt(1.5e18, 1000);
        oracle.setState(PriceState.Live, 0, true);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-157 verifies: REQ-ADAPTER-015, REQ-RISK-017, REQ-RISK-049, INV-026
    // Sources: 5.1 TEST-157 (RiskModule side), Q-162, Q-199
    /// @notice Routes disagreeing beyond the tolerance (Drifting for a token disagreement) and then for longer than
    /// `disagreementPauseMax` (Expired): borrow and withdraw-with-debt revert `PriceNotLive` in both states, a
    /// new-account pledge is refused, and a top-up is refused once Expired; when the routes agree again (Live) the
    /// borrow and the withdrawal check pass.
    function test_TEST_157_persistentDisagreementBlocksBorrowing() public {
        _debt(1.5e18, 1000);
        oracle.setState(PriceState.Drifting, ANY_TOKEN_DISAGREE, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Drifting));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        oracle.setState(PriceState.Expired, ANY_TOKEN_DISAGREE, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Expired));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Expired));
        riskModule.preWithdrawCheck(address(proxy));
        uint128 units = TEN_K;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotAccepted.selector, uint8(3)));
        _pledge(units, _counters(), false);
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, false);
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        oracle.setState(PriceState.Drifting, ANY_TOKEN_DISAGREE, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotAccepted.selector, uint8(1)));
        _pledge(units, _counters(), false);
        // The routes agree again.
        _debt(1.5e18, 1000);
        oracle.setState(PriceState.Live, 0, true);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
    }
}
