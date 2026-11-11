// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {AccountGateStatus} from "../../src/types/AccountGateStatus.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {MarketGateStatus} from "../../src/types/MarketGateStatus.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskSpokeMock} from "../utils/mocks/RiskModuleMocks.sol";

/// @title RiskModuleStatusUnitTest
/// @notice `getAccountGateStatus`: every reason field of the account status, the per-market outcome and the two
/// "would pass now" flags, read without poking and without reverting (REQ-ADAPTER-038, REQ-RISK-060).
contract RiskModuleStatusUnitTest is RiskModuleFixture {
    uint256 internal constant NONE = type(uint256).max;

    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
    }

    function _status() internal view returns (AccountGateStatus memory) {
        return riskModule.getAccountGateStatus(address(proxy));
    }

    function _assertBlocked(
        AccountGateStatus memory s
    ) internal pure {
        assertFalse(s.borrowAllowed);
        assertFalse(s.withdrawWithDebtAllowed);
    }

    function _assertNoDebtReason(
        AccountGateStatus memory s
    ) internal pure {
        assertEq(s.unapprovedDebtReserveId, NONE);
        assertEq(s.pausedDebtReserveId, NONE);
        assertEq(s.staleDebtReserveId, NONE);
        assertEq(s.haltedDebtReserveId, NONE);
        assertEq(s.breakerDebtReserveId, NONE);
        assertEq(s.debtBreakerReasons, 0);
    }

    function _vtConfig(
        bool paused,
        bool frozen,
        bool receiveShares
    ) internal {
        IAaveV4Spoke.ReserveConfig memory c;
        (c.paused, c.frozen, c.receiveSharesEnabled) = (paused, frozen, receiveShares);
        rSpoke.setConfig(VT_RESERVE, c);
    }

    function _debtConfig(
        uint256 r,
        bool paused
    ) internal {
        IAaveV4Spoke.ReserveConfig memory c;
        (c.borrowable, c.paused) = (true, paused);
        rSpoke.setConfig(r, c);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-060, REQ-ADAPTER-024, REQ-ADAPTER-025
    function test_TEST_028_statusOfAnOpenAccount() public view {
        uint256 pokes = oracle.pokes();
        AccountGateStatus memory s = _status();
        assertTrue(s.spokeApproved);
        assertEq(s.unknownCollateralReserveId, NONE);
        _assertNoDebtReason(s);
        assertEq(s.driftMarketId, 0);
        assertEq(uint8(s.driftReason), uint8(DriftReason.None));
        assertFalse(s.noApprovedKeeper);
        assertEq(uint8(s.pauseState), uint8(PauseState.None));
        assertEq(uint8(s.pauseReason), uint8(PauseReason.None));
        assertEq(s.healthFactor, 1.5e18);
        assertEq(s.healthFactorExcludingRescue, 1.5e18);
        assertEq(s.hardHealthFloor, 0);
        assertTrue(s.borrowAllowed);
        assertTrue(s.withdrawWithDebtAllowed);
        assertEq(s.markets.length, 1);
        MarketGateStatus memory g = s.markets[0];
        assertEq(g.marketId, mid);
        assertEq(g.reserveId, VT_RESERVE);
        assertEq(uint8(g.priceState), uint8(PriceState.Live));
        assertEq(g.oldestFeedAge, 0);
        assertFalse(g.feedTooOld);
        assertFalse(g.offboarding);
        assertFalse(g.aaveReservePaused);
        assertFalse(g.aaveReserveFrozen);
        assertTrue(g.hubSharesEqualAssets);
        assertFalse(g.noSettlementPath);
        assertFalse(g.liquidationHalted);
        assertEq(g.breakerReasons, 0);
        assertEq(g.breakerLatchedUntil, 0);
        // The status never pokes (REQ-RISK-060).
        assertEq(oracle.pokes(), pokes);
        assertEq(usdcOracle.pokes(), 0);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-ADAPTER-016
    // Sources: 2.7 REQ-ADAPTER-016 (per-feed heartbeat plus margin, 88,200 s)
    function test_TEST_028_statusFeedAges() public {
        _report(uint64(block.timestamp - 100), 1e8, 1e8);
        AccountGateStatus memory s = _status();
        assertEq(s.markets[0].oldestFeedAge, 100);
        assertFalse(s.markets[0].feedTooOld);
        assertTrue(s.borrowAllowed);
        // One second past the feed's limit: too old, and both actions refused.
        _report(uint64(block.timestamp - FEED_AGE - 1), 1e8, 1e8);
        s = _status();
        assertEq(s.markets[0].oldestFeedAge, FEED_AGE + 1);
        assertTrue(s.markets[0].feedTooOld);
        _assertBlocked(s);
        // An input dated in the future is never fresh; its age reads 0.
        _report(uint64(block.timestamp + 1), 1e8, 1e8);
        s = _status();
        assertEq(s.markets[0].oldestFeedAge, 0);
        assertTrue(s.markets[0].feedTooOld);
        _assertBlocked(s);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-ADAPTER-012, REQ-ADAPTER-013, REQ-ADAPTER-019
    function test_TEST_028_statusCollateralScope() public {
        // The first collateral reserve that maps to no market of the account, in reserve order.
        rSpoke.setStatus(address(proxy), USDC_RESERVE, true, false);
        rSpoke.setStatus(address(proxy), 3, true, false);
        AccountGateStatus memory s = _status();
        assertEq(s.unknownCollateralReserveId, 3);
        _assertBlocked(s);
        rSpoke.setStatus(address(proxy), 3, false, false);
        assertEq(_status().unknownCollateralReserveId, USDC_RESERVE);
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, false);
        // An Offboarding market still maps its reserve; it refuses borrows and allows withdraw-with-debt.
        vm.prank(address(timelock));
        registry.setMarketOffboarding(mid);
        s = _status();
        assertEq(s.unknownCollateralReserveId, NONE);
        assertTrue(s.markets[0].offboarding);
        assertFalse(s.borrowAllowed);
        assertTrue(s.withdrawWithDebtAllowed);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-ADAPTER-014, REQ-RISK-062
    function test_TEST_028_statusUnapprovedDebtReserve() public {
        rSpoke.setStatus(address(proxy), 3, false, true);
        rSpoke.setStatus(address(proxy), 4, false, true);
        AccountGateStatus memory s = _status();
        assertEq(s.unapprovedDebtReserveId, 3);
        // An unapproved reserve has no recorded route either, and is never priced or breaker-checked.
        assertEq(s.haltedDebtReserveId, 3);
        assertTrue(s.markets[0].noSettlementPath);
        assertEq(s.pausedDebtReserveId, NONE);
        assertEq(s.staleDebtReserveId, NONE);
        assertEq(s.breakerDebtReserveId, NONE);
        _assertBlocked(s);
    }

    // TEST-201 verifies: REQ-ADAPTER-038, REQ-RISK-061, REQ-ADAPTER-062
    function test_TEST_201_statusPausedAndStaleDebtReserves() public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        assertTrue(_status().borrowAllowed);
        // Paused on Aave: the first paused reserve held, in reserve order.
        _debtConfig(USDC_RESERVE, true);
        AccountGateStatus memory s = _status();
        assertEq(s.pausedDebtReserveId, USDC_RESERVE);
        _assertBlocked(s);
        _debtConfig(GHO_RESERVE, true);
        assertEq(_status().pausedDebtReserveId, GHO_RESERVE);
        _debtConfig(GHO_RESERVE, false);
        _debtConfig(USDC_RESERVE, false);
        // Stale: the DebtOracle fails its borrow gate.
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), false);
        s = _status();
        assertEq(s.staleDebtReserveId, USDC_RESERVE);
        assertEq(s.pausedDebtReserveId, NONE);
        _assertBlocked(s);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        assertEq(_status().staleDebtReserveId, NONE);
        // Stale: the AaveOracle prices the reserve from another source (also a Spoke-wide drift).
        aaveOracle.setSource(USDC_RESERVE, address(ghoSource));
        s = _status();
        assertEq(s.staleDebtReserveId, USDC_RESERVE);
        assertEq(s.driftMarketId, 0);
        assertEq(uint8(s.driftReason), uint8(DriftReason.DebtPriceSource));
        _assertBlocked(s);
        // A fixed-price reserve is stale only on another source; the first stale reserve is reported.
        aaveOracle.setSource(GHO_RESERVE, makeAddr("otherGhoSource"));
        assertEq(_status().staleDebtReserveId, GHO_RESERVE);
    }

    // TEST-068 verifies: REQ-ADAPTER-038, REQ-ADAPTER-010, REQ-RISK-062, REQ-RISK-071
    function test_TEST_068_statusLiquidationHalts() public {
        swap.setKeepers(0);
        AccountGateStatus memory s = _status();
        assertTrue(s.noApprovedKeeper);
        assertTrue(s.markets[0].liquidationHalted);
        assertFalse(s.markets[0].noSettlementPath);
        assertEq(s.haltedDebtReserveId, NONE);
        _assertBlocked(s);
        swap.setKeepers(1);
        // USDT loses both routes into USDC while the account owes USDC.
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        vm.startPrank(address(timelock));
        registry.disableRoute(mid, address(usdt), address(usdc), 0);
        registry.disableRoute(mid, address(usdt), address(usdc), 1);
        vm.stopPrank();
        s = _status();
        assertFalse(s.noApprovedKeeper);
        assertEq(s.haltedDebtReserveId, USDC_RESERVE);
        assertTrue(s.markets[0].noSettlementPath);
        assertTrue(s.markets[0].liquidationHalted);
        _assertBlocked(s);
    }

    // TEST-228 verifies: REQ-ADAPTER-038, REQ-RISK-065, SPEC-BRK-007, SPEC-BRK-008
    function test_TEST_228_statusBreakers() public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        vm.prank(emergencyGuardian);
        registry.tripDebtBreaker(address(spoke), USDC_RESERVE);
        AccountGateStatus memory s = _status();
        assertEq(s.breakerDebtReserveId, USDC_RESERVE);
        assertEq(s.debtBreakerReasons, BreakerReasons.MANUAL);
        assertEq(s.markets[0].breakerReasons, 0);
        // A borrow applies only the borrowed reserve's debt breaker, so a borrow of another reserve still passes;
        // a withdraw-with-debt applies every held reserve's.
        assertTrue(s.borrowAllowed);
        assertFalse(s.withdrawWithDebtAllowed);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.prank(emergencyGuardian);
        registry.resetDebtBreaker(address(spoke), USDC_RESERVE);
        assertTrue(_status().borrowAllowed);
        // A temporary market gate reports its reasons and the time it reopens.
        oracle.setState(PriceState.Drifting, 1 << 2, false);
        s = _status();
        assertEq(uint8(s.markets[0].priceState), uint8(PriceState.Drifting));
        assertEq(s.markets[0].breakerReasons, BreakerReasons.ORACLE);
        assertEq(s.markets[0].breakerLatchedUntil, block.timestamp + 1800);
        _assertBlocked(s);
        oracle.setState(PriceState.Live, 0, true);
        // A latched security reason.
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(mid);
        s = _status();
        assertEq(s.markets[0].breakerReasons, BreakerReasons.MANUAL);
        assertEq(s.breakerDebtReserveId, NONE);
        _assertBlocked(s);
    }

    // TEST-155 verifies: REQ-ADAPTER-038, REQ-ADAPTER-019, REQ-ADAPTER-061, REQ-ADAPTER-021
    function test_TEST_155_statusAaveFlagsAndHubShares() public {
        _vtConfig(true, false, false);
        AccountGateStatus memory s = _status();
        assertTrue(s.markets[0].aaveReservePaused);
        assertFalse(s.markets[0].aaveReserveFrozen);
        _assertBlocked(s);
        _vtConfig(false, false, false);
        rHub.setAdded(VT_ASSET, 1000, 999);
        s = _status();
        assertFalse(s.markets[0].hubSharesEqualAssets);
        _assertBlocked(s);
    }

    // TEST-033 verifies: REQ-ADAPTER-038, REQ-ADAPTER-020, REQ-RISK-088
    function test_TEST_033_statusDrift() public {
        _vtConfig(false, false, true);
        AccountGateStatus memory s = _status();
        assertEq(s.driftMarketId, mid);
        assertEq(uint8(s.driftReason), uint8(DriftReason.ReceiveSharesOn));
        // Drift of the market's Spoke is also a live CONFIG_DRIFT market reason.
        assertEq(s.markets[0].breakerReasons, BreakerReasons.CONFIG_DRIFT);
        _assertBlocked(s);
        _vtConfig(false, false, false);
        rSpoke.setImplSlot(bytes32(uint256(uint160(makeAddr("upgraded")))));
        s = _status();
        assertEq(s.driftMarketId, 0);
        assertEq(uint8(s.driftReason), uint8(DriftReason.SpokeImplementation));
        _assertBlocked(s);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-038
    function test_TEST_028_statusPauseStateAndFloor() public {
        store.setHardFloor(mid, 1.25e18);
        assertEq(_status().hardHealthFloor, 1.25e18);
        // Frozen stops borrowing only.
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        AccountGateStatus memory s = _status();
        assertEq(uint8(s.pauseState), uint8(PauseState.Frozen));
        assertEq(uint8(s.pauseReason), uint8(PauseReason.None));
        assertFalse(s.borrowAllowed);
        assertTrue(s.withdrawWithDebtAllowed);
        // Paused stops both, with its reason.
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.MintPathSuspect);
        s = _status();
        assertEq(uint8(s.pauseState), uint8(PauseState.Paused));
        assertEq(uint8(s.pauseReason), uint8(PauseReason.MintPathSuspect));
        _assertBlocked(s);
    }

    // TEST-236 verifies: REQ-ADAPTER-038, SPEC-CF-005, REQ-RISK-068
    // Sources: 2.7 SPEC-CF-005 example (HF 1.2000, debt $10,000, rescue $1,000 at CF 0.312)
    function test_TEST_236_statusHealthExcludingRescue() public {
        _debt(1.2e18, 10_000);
        coll.setRescue(address(proxy), 500e18);
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus) = (3120, 10_500);
        rSpoke.setDynamicAt(VT_RESERVE, 9, d);
        rSpoke.setUserKey(address(proxy), VT_RESERVE, 9);
        AccountGateStatus memory s = _status();
        assertEq(s.healthFactor, 1.2e18);
        assertEq(s.healthFactorExcludingRescue, 1.1688e18);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-ADAPTER-011
    function test_TEST_028_statusOfAnUnapprovedSpoke() public {
        RiskSpokeMock other = new RiskSpokeMock();
        PositionProxy foreign = new PositionProxy(address(adapter), wallet, address(other), mid);
        AccountGateStatus memory s = riskModule.getAccountGateStatus(address(foreign));
        assertFalse(s.spokeApproved);
        // The market record names another Spoke, so the market fails its reserve identity on this one.
        assertEq(s.driftMarketId, mid);
        assertEq(uint8(s.driftReason), uint8(DriftReason.ReserveIdentity));
        assertEq(s.markets[0].marketId, mid);
        _assertNoDebtReason(s);
        _assertBlocked(s);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-060
    function test_TEST_028_statusNeverReverts() public {
        AccountGateStatus memory s = riskModule.getAccountGateStatus(makeAddr("notAProxy"));
        assertFalse(s.spokeApproved);
        assertEq(s.markets.length, 0);
        assertEq(s.unknownCollateralReserveId, NONE);
        _assertBlocked(s);
    }
}
