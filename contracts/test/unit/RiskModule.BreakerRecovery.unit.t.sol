// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/RiskModuleTypes.sol";
import {DriftReason} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {PledgeCounters, PledgePreview} from "../../src/types/PositionTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleBreakerRecoveryUnitTest
/// @notice Per-reason recovery of the temporary gates (SPEC-BRK-007), the oracle pokes at the start of `pokeBreakers`
/// (REQ-RISK-091), a paused vault-token reserve kept to its own market (REQ-RISK-014, REQ-RISK-088) and the cap charge
/// at the fresh price (REQ-RISK-026, SPEC-CAP-001), on the real RiskModule and MarketRegistry.
contract RiskModuleBreakerRecoveryUnitTest is RiskModuleFixture {
    uint128 internal constant TEN_K = 10_000e18; // $20,000 at $2.00 per whole token

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    // ----------------------------------------------------------------------------------------- per-reason recovery

    // TEST-228 verifies: SPEC-BRK-007, REQ-RISK-017, REQ-RISK-066, REQ-MREG-026
    /// @dev A recorded `ORACLE` breach recovers `ORACLE` alone: a top-up of a healthy account, which masks `ORACLE`,
    /// passes inside the recovery instead of meeting `POOL_DEPTH`.
    function test_TEST_228_oracleBreachRecoversOracleAlone() public {
        oracle.setState(PriceState.Drifting, 1 << 3, false);
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.ORACLE);
        oracle.setState(PriceState.Live, 0, true);
        (uint32 reasons, uint64 reopensAt) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, BreakerReasons.ORACLE, "only the recorded reason recovers");
        assertEq(reopensAt, block.timestamp + 1800);
        // The borrow side still waits for the recovery.
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.ORACLE));
        riskModule.preWithdrawCheck(address(proxy));
        // A non-rescue top-up of an account at HF 1.5 passes.
        PledgeCharge memory c = _pledge(TEN_K, _counters(), false);
        assertFalse(c.rescue);
        vm.warp(block.timestamp + 1800);
        (reasons, reopensAt) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, 0);
        assertEq(reopensAt, 0);
    }

    // TEST-228 verifies: SPEC-BRK-007, REQ-MREG-026
    function test_TEST_228_eachReasonKeepsItsOwnBreachTime() public {
        uint256 start = block.timestamp;
        rVault.setDepth(0, false);
        assertEq(riskModule.pokeBreakers(mid), BreakerReasons.POOL_DEPTH);
        rVault.setDepth(2e13, true);
        vm.warp(start + 1000);
        oracle.setState(PriceState.Drifting, 1 << 3, false);
        riskModule.pokeBreakers(mid);
        oracle.setState(PriceState.Live, 0, true);
        bytes32 key = bytes32(mid);
        assertEq(registry.lastBreachAt(BreakerReasons.breachKey(key, BreakerReasons.POOL_DEPTH)), start);
        assertEq(registry.lastBreachAt(BreakerReasons.breachKey(key, BreakerReasons.ORACLE)), start + 1000);
        assertEq(registry.lastBreachAt(key), start + 1000, "the latest of any reason");
        (uint32 reasons, uint64 reopensAt) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, BreakerReasons.ORACLE | BreakerReasons.POOL_DEPTH);
        assertEq(reopensAt, start + 1000 + 1800, "the last gate to reopen");
        vm.warp(start + 1800);
        (reasons,) = riskModule.getBreakerStatus(mid);
        assertEq(reasons, BreakerReasons.ORACLE, "the depth gate reopened on its own time");
    }

    // ----------------------------------------------------------------------------------------- oracle pokes

    // ----------------------------------------------------------------------------------------- reserve pause

    // TEST-268 verifies: REQ-RISK-014, REQ-RISK-078, REQ-RISK-088, REQ-RISK-090
    /// @dev A paused vault-token reserve is the market's own containment: no drift, nothing latched on the Spoke, and
    /// the market's own borrow and pledge gates refuse it.
    function test_TEST_268_pausedReserveStaysPerMarket() public {
        IAaveV4Spoke.ReserveConfig memory c;
        c.paused = true;
        rSpoke.setConfig(VT_RESERVE, c);
        uint256[] memory none = new uint256[](0);
        riskModule.checkAaveConfig(address(spoke), none);
        assertEq(uint8(riskModule.pokeConfig(address(spoke))), uint8(DriftReason.None), "no drift");
        (uint32 latched,) = registry.marketBreaker(mid);
        assertEq(latched, 0, "nothing latched");
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, VT_RESERVE));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(IRiskModuleErrors.AaveReserveUnavailable.selector);
        _pledge(TEN_K, _counters(), false);
        // Unpaused, the market reopens with no reset.
        c.paused = false;
        rSpoke.setConfig(VT_RESERVE, c);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // ----------------------------------------------------------------------------------------- cap price

    // TEST-230 verifies: REQ-RISK-026, REQ-RISK-057
    function test_TEST_230_minimumStaysAtTheLowerPrice() public {
        oracle.setState(PriceState.Drifting, 1 << 3, true);
        oracle.setFresh(2.3e8);
        store.setMarket(mid, 4000, 100_000e8, 100_000_000e8, 100_000e8, 1e8);
        // Minimum $100,000: 50,000 tokens are $100,000 at $2.00 and pass; 49,999 are $99,998 at $2.00 and fail even
        // though they are $114,997.7 at $2.30.
        _pledge(50_000e18, _counters(), false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 99_998e8, 100_000e8));
        _pledge(49_999e18, _counters(), false);
    }
}
