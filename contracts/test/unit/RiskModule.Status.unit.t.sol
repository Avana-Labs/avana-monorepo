// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/legacy/risk-module/IRiskModuleErrors.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {AccountGateStatus, DriftReason, MarketGateStatus} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
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
        assertEq(s.staleDebtReserveId, NONE);
        assertEq(s.haltedDebtReserveId, NONE);
        assertEq(s.breakerDebtReserveId, NONE);
        assertEq(s.breakerDebtReasons, 0);
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
        assertEq(s.healthFactor, 1.5e18);
        assertEq(s.healthFactorExcludingRescue, 1.5e18);
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
        assertTrue(g.hubSharesEqualAssets);
        assertFalse(g.noSettlementPath);
        assertFalse(g.liquidationHalted);
        assertEq(g.breakerReasons, 0);
        // The status never pokes (REQ-RISK-060).
        assertEq(oracle.pokes(), pokes);
        assertEq(usdcOracle.pokes(), 0);
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
        vm.prank(governor);
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
        assertEq(s.staleDebtReserveId, NONE);
        assertEq(s.breakerDebtReserveId, NONE);
        _assertBlocked(s);
    }

    // TEST-201 verifies: REQ-ADAPTER-038, REQ-RISK-061, REQ-ADAPTER-062
    function test_TEST_201_statusStaleDebtReserves() public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        assertTrue(_status().borrowAllowed);
        // Stale: the DebtOracle fails its borrow gate.
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), false);
        AccountGateStatus memory s = _status();
        assertEq(s.staleDebtReserveId, USDC_RESERVE);
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
        vm.startPrank(governor);
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

    // TEST-228 verifies: REQ-ADAPTER-038, REQ-RISK-065, REQ-RISK-073
    function test_TEST_228_borrowAllowedIgnoresDebtBreakers() public {
        // The account owes GHO and USDC; the Hub's deficit of each is above its `deficitMax`.
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, true);
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        store.setDeficitMax(address(hub), address(gho), 10_000e18);
        store.setDeficitMax(address(hub), address(usdc), 1000e6);
        hub.setOwed(GHO_ASSET, address(spoke), 0, 10_000.5e18 * 1e27);
        hub.setOwed(USDC_ASSET, address(spoke), 0, 1000.5e6 * 1e27);
        AccountGateStatus memory s = _status();
        // The status reports the first tripped reserve in reserve order, and the borrow flag ignores every debt
        // breaker: which reserve's breaker applies depends on the reserve borrowed, which the status does not know.
        uint256 first = GHO_RESERVE < USDC_RESERVE ? GHO_RESERVE : USDC_RESERVE;
        assertEq(s.breakerDebtReserveId, first);
        assertEq(s.breakerDebtReasons, BreakerReasons.DEFICIT);
        assertTrue(s.borrowAllowed);
        // Withdraw-with-debt applies the breaker of every held reserve.
        assertFalse(s.withdrawWithDebtAllowed);
        // The pre-checks enforce them: a borrow of either reserve, and a withdraw-with-debt, revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), USDC_RESERVE, BreakerReasons.DEFICIT
            )
        );
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.DEFICIT
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), first, BreakerReasons.DEFICIT
            )
        );
        riskModule.preWithdrawCheck(address(proxy));
        // The GHO deficit covered: a GHO borrow passes in the same block, and a held reserve's breaker never blocks a
        // borrow of another reserve.
        hub.setOwed(GHO_ASSET, address(spoke), 0, 0);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        assertTrue(_status().borrowAllowed);
        assertEq(_status().breakerDebtReserveId, USDC_RESERVE);
        // The USDC deficit back at its limit: withdraw-with-debt passes too.
        hub.setOwed(USDC_ASSET, address(spoke), 0, 1000e6 * 1e27);
        s = _status();
        assertEq(s.breakerDebtReserveId, NONE);
        assertTrue(s.withdrawWithDebtAllowed);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-155 verifies: REQ-ADAPTER-038, REQ-ADAPTER-019, REQ-ADAPTER-061, REQ-ADAPTER-021
    function test_TEST_155_statusHubShares() public {
        rHub.setAdded(VT_ASSET, 1000, 999);
        AccountGateStatus memory s = _status();
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
        assertFalse(s.statusUnavailable);
        // The MarketRegistry has no implementation record for an unknown Spoke, so the Spoke-wide check fails first.
        assertEq(s.driftMarketId, 0);
        assertEq(uint8(s.driftReason), uint8(DriftReason.SpokeImplementation));
        assertEq(s.markets[0].marketId, mid);
        _assertNoDebtReason(s);
        _assertBlocked(s);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-060
    function test_TEST_028_statusNeverReverts() public {
        // An address that is not a proxy: the body reverts on `SPOKE()`.
        _assertUnavailable(riskModule.getAccountGateStatus(makeAddr("notAProxy")));
        // A proxy whose market record cannot be read.
        PositionProxy orphan = new PositionProxy(address(adapter), wallet, address(spoke), 999);
        _assertUnavailable(riskModule.getAccountGateStatus(address(orphan)));
        // The account's LPOracle report reverts: the body reverts, the view does not.
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("getPriceStatus()"), "oracle");
        _assertUnavailable(_status());
        vm.clearMockedCalls();
        assertFalse(_status().statusUnavailable);
    }

    // TEST-028 verifies: REQ-ADAPTER-038, REQ-RISK-060
    function test_TEST_028_statusUnavailableOnABrokenDebtOracle() public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        assertTrue(_status().borrowAllowed);
        vm.mockCallRevert(address(usdcOracle), abi.encodeWithSignature("latestRoundData()"), "debt");
        _assertUnavailable(_status());
    }

    /// @dev Every field of the unavailable status (REQ-ADAPTER-038).
    function _assertUnavailable(
        AccountGateStatus memory s
    ) internal pure {
        assertTrue(s.statusUnavailable);
        assertFalse(s.spokeApproved);
        assertEq(s.markets.length, 0);
        assertEq(s.unknownCollateralReserveId, NONE);
        assertEq(s.unapprovedDebtReserveId, NONE);
        assertEq(s.staleDebtReserveId, NONE);
        assertEq(s.haltedDebtReserveId, NONE);
        assertEq(s.breakerDebtReserveId, NONE);
        assertEq(s.breakerDebtReasons, 0);
        assertEq(s.driftMarketId, 0);
        assertEq(uint8(s.driftReason), uint8(DriftReason.None));
        assertFalse(s.noApprovedKeeper);
        assertEq(s.healthFactor, 0);
        assertEq(s.healthFactorExcludingRescue, 0);
        assertFalse(s.borrowAllowed);
        assertFalse(s.withdrawWithDebtAllowed);
    }
}
