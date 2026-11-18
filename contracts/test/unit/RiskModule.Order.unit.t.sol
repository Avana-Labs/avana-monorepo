// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AccountGateStatus, DriftReason} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
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
        return abi.encodeWithSelector(IMarketRegistry.CrossHubLinesDisabled.selector);
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

    // -----------------------------------------------------------------------------------------------------------------
    // Per-action table: pre-checks against the account status
    // -----------------------------------------------------------------------------------------------------------------
}
