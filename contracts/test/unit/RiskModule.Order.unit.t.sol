// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title RiskModuleOrderUnitTest
/// @notice The borrow-side checks of 2.7 run in their stated order and revert on the first failure: for every pair of
/// failing steps the earlier step's exact error is the one reported, for `preBorrowCheck` and `preWithdrawCheck`. A
/// per-action table states, for every single failing step, whether a borrow, a withdraw-with-debt and the two flags of
/// the account status pass (REQ-ADAPTER-024, REQ-ADAPTER-025, REQ-ADAPTER-038, REQ-RISK-060).
/// @dev The account owes GHO (reserve 0) and borrows DAI (reserve 6, funded by a second Hub), so the cross-Hub step
/// applies. Each step has one fault; a fault never trips an earlier step.
contract RiskModuleOrderUnitTest is RiskModuleFixture {
    uint256 internal constant SEQ = 0;
    uint256 internal constant COLL = 1;
    uint256 internal constant DEBT_UNAPPROVED = 2;
    uint256 internal constant POKE = 3;
    uint256 internal constant PRICE = 4;
    uint256 internal constant DEBT_PAUSED = 5;
    uint256 internal constant VT_PAUSED = 6;
    uint256 internal constant OFFBOARD = 7;
    uint256 internal constant DRIFT = 8;
    uint256 internal constant SHARES = 9;
    uint256 internal constant KEEPER = 10;
    uint256 internal constant BREAKER = 11;
    uint256 internal constant CROSS = 12;
    uint256 internal constant STEPS = 13;
    uint256 internal constant UNAPPROVED_RESERVE = 3;

    IAaveV4Spoke.ReserveConfig internal vtCfg;
    RiskSequencerFeed internal seqFeed;

    function setUp() public {
        _deployRiskWorld();
        _enableCrossHubDebt();
        _debt(1.5e18, 1000);
        seqFeed = new RiskSequencerFeed();
        store.setSequencer(address(seqFeed), 3600);
        seqFeed.set(0, 1, false);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Faults
    // -----------------------------------------------------------------------------------------------------------------

    function _inject(
        uint256 step
    ) internal {
        if (step == SEQ) {
            seqFeed.set(1, 1, false);
        } else if (step == COLL) {
            rSpoke.setStatus(address(proxy), USDC_RESERVE, true, false);
        } else if (step == DEBT_UNAPPROVED) {
            rSpoke.setStatus(address(proxy), UNAPPROVED_RESERVE, false, true);
        } else if (step == POKE) {
            oracle.setPokeReverts(true);
        } else if (step == PRICE) {
            oracle.setState(PriceState.Drifting, 1 << 3, false);
        } else if (step == DEBT_PAUSED) {
            IAaveV4Spoke.ReserveConfig memory c;
            (c.borrowable, c.paused) = (true, true);
            rSpoke.setConfig(GHO_RESERVE, c);
        } else if (step == VT_PAUSED) {
            vtCfg.paused = true;
            rSpoke.setConfig(VT_RESERVE, vtCfg);
        } else if (step == OFFBOARD) {
            vm.prank(address(timelock));
            registry.setMarketOffboarding(mid);
        } else if (step == DRIFT) {
            vtCfg.receiveSharesEnabled = true;
            rSpoke.setConfig(VT_RESERVE, vtCfg);
        } else if (step == SHARES) {
            rHub.setAdded(VT_ASSET, 1000, 999);
        } else if (step == KEEPER) {
            swap.setKeepers(0);
        } else if (step == BREAKER) {
            vm.prank(emergencyGuardian);
            registry.tripMarketBreaker(mid);
        } else {
            vm.prank(address(timelock));
            registry.setCrossHubLinesEnabled(false);
        }
    }

    /// @dev The exact revert data of a step's failure.
    function _error(
        uint256 step
    ) internal view returns (bytes memory) {
        if (step == SEQ) return abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector);
        if (step == COLL) return abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, USDC_RESERVE);
        if (step == DEBT_UNAPPROVED) {
            return
                abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.BorrowedUnapprovedReserve);
        }
        if (step == POKE) return abi.encodeWithSignature("Error(string)", "poke");
        if (step == PRICE) {
            return abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Drifting);
        }
        if (step == DEBT_PAUSED) {
            return abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, GHO_RESERVE);
        }
        if (step == VT_PAUSED) return abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, VT_RESERVE);
        if (step == OFFBOARD) return abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, mid);
        if (step == DRIFT) {
            return abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, mid, DriftReason.ReceiveSharesOn);
        }
        if (step == SHARES) return abi.encodeWithSelector(IRiskModuleErrors.HubSharesNotEqualAssets.selector, mid);
        if (step == KEEPER) return abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid);
        if (step == BREAKER) {
            return abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.MANUAL);
        }
        return abi.encodeWithSelector(IMarketRegistryHubs.CrossHubLinesDisabled.selector);
    }

    /// @dev Steps `preWithdrawCheck` does not run.
    function _borrowOnly(
        uint256 step
    ) internal pure returns (bool) {
        return step == OFFBOARD || step == CROSS;
    }

    function _borrowCall() internal returns (bool ok, bytes memory ret) {
        (ok, ret) =
            address(riskModule).call(abi.encodeCall(riskModule.preBorrowCheck, (address(proxy), DAI_RESERVE, 1)));
    }

    function _withdrawCall() internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(riskModule).call(abi.encodeCall(riskModule.preWithdrawCheck, (address(proxy))));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Order
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-028 verifies: REQ-ADAPTER-024, REQ-ADAPTER-025, REQ-RISK-081, INV-024
    function test_TEST_028_eachStepAloneHasItsError() public {
        (bool ok,) = _borrowCall();
        assertTrue(ok, "clean account must pass");
        (ok,) = _withdrawCall();
        assertTrue(ok, "clean withdraw must pass");
        for (uint256 k = 0; k < STEPS; ++k) {
            uint256 snap = vm.snapshotState();
            _inject(k);
            bytes memory ret;
            (ok, ret) = _borrowCall();
            assertFalse(ok, vm.toString(k));
            assertEq(ret, _error(k), string.concat("borrow error of step ", vm.toString(k)));
            (ok, ret) = _withdrawCall();
            if (_borrowOnly(k)) {
                assertTrue(ok, string.concat("withdraw passes step ", vm.toString(k)));
            } else {
                assertFalse(ok);
                assertEq(ret, _error(k), string.concat("withdraw error of step ", vm.toString(k)));
            }
            vm.revertToState(snap);
        }
    }

    // TEST-028 verifies: REQ-ADAPTER-024, REQ-ADAPTER-025, REQ-ADAPTER-019, REQ-RISK-082
    function test_TEST_028_firstFailingStepWinsForEveryPair() public {
        for (uint256 k = 0; k < STEPS; ++k) {
            for (uint256 j = k + 1; j < STEPS; ++j) {
                uint256 snap = vm.snapshotState();
                _inject(k);
                _inject(j);
                (bool ok, bytes memory ret) = _borrowCall();
                assertFalse(ok);
                assertEq(ret, _error(k), string.concat("borrow pair ", vm.toString(k), ",", vm.toString(j)));
                (ok, ret) = _withdrawCall();
                // A withdrawal skips the borrow-only steps, so the first step it runs reports.
                uint256 first = _borrowOnly(k) ? j : k;
                if (_borrowOnly(first)) {
                    assertTrue(ok);
                } else {
                    assertFalse(ok);
                    assertEq(ret, _error(first), string.concat("withdraw pair ", vm.toString(k), ",", vm.toString(j)));
                }
                vm.revertToState(snap);
            }
        }
    }

    // TEST-028 verifies: REQ-ADAPTER-024, REQ-ADAPTER-025
    function testFuzz_TEST_028_firstFailingStepWins(
        uint256 mask
    ) public {
        mask = bound(mask, 1, (1 << STEPS) - 1);
        uint256 first = STEPS;
        uint256 firstWithdraw = STEPS;
        for (uint256 k = 0; k < STEPS; ++k) {
            if (mask & (1 << k) == 0) continue;
            _inject(k);
            if (first == STEPS) first = k;
            if (firstWithdraw == STEPS && !_borrowOnly(k)) firstWithdraw = k;
        }
        (bool ok, bytes memory ret) = _borrowCall();
        assertFalse(ok);
        assertEq(ret, _error(first));
        (ok, ret) = _withdrawCall();
        if (firstWithdraw == STEPS) {
            assertTrue(ok);
        } else {
            assertFalse(ok);
            assertEq(ret, _error(firstWithdraw));
        }
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Per-action table: pre-checks against the account status
    // -----------------------------------------------------------------------------------------------------------------

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-060, REQ-RISK-082
    function test_TEST_028_statusMatchesThePreChecksPerStep() public {
        // Status flags per step: the status runs the same gates without poking and without the borrowed reserve, so a
        // poke failure and the cross-Hub gate of the reserve borrowed are not in it.
        for (uint256 k = 0; k < STEPS; ++k) {
            uint256 snap = vm.snapshotState();
            _inject(k);
            AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
            assertFalse(s.statusUnavailable);
            bool statusBorrow = k == POKE || k == CROSS;
            bool statusWithdraw = k == POKE || k == CROSS || k == OFFBOARD;
            assertEq(s.borrowAllowed, statusBorrow, string.concat("status borrow at step ", vm.toString(k)));
            assertEq(s.withdrawWithDebtAllowed, statusWithdraw, string.concat("status withdraw ", vm.toString(k)));
            (bool ok,) = _withdrawCall();
            if (k != POKE) assertEq(ok, statusWithdraw, string.concat("withdraw parity ", vm.toString(k)));
            vm.revertToState(snap);
        }
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-ADAPTER-016, REQ-ADAPTER-015, REQ-ADAPTER-061
    function test_TEST_028_statusFieldsPerStep() public {
        _inject(PRICE);
        AccountGateStatus memory s = riskModule.getAccountGateStatus(address(proxy));
        assertEq(uint8(s.markets[0].priceState), uint8(PriceState.Drifting));
        oracle.setState(PriceState.Live, 0, true);
        _inject(VT_PAUSED);
        s = riskModule.getAccountGateStatus(address(proxy));
        assertTrue(s.markets[0].aaveReservePaused);
        // The paused vault-token reserve is also the Spoke-halted drift reason.
        assertEq(uint8(s.driftReason), uint8(DriftReason.SpokeHalted));
        vtCfg.paused = false;
        rSpoke.setConfig(VT_RESERVE, vtCfg);
        _inject(SHARES);
        s = riskModule.getAccountGateStatus(address(proxy));
        assertFalse(s.markets[0].hubSharesEqualAssets);
        rHub.setAdded(VT_ASSET, 1000, 1000);
        _inject(KEEPER);
        s = riskModule.getAccountGateStatus(address(proxy));
        assertTrue(s.noApprovedKeeper);
        assertTrue(s.markets[0].liquidationHalted);
        swap.setKeepers(1);
        _inject(DEBT_PAUSED);
        s = riskModule.getAccountGateStatus(address(proxy));
        assertEq(s.pausedDebtReserveId, GHO_RESERVE);
        assertFalse(s.borrowAllowed);
    }
}
