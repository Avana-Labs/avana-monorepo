// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";

contract ParameterStoreReviewPoC is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
    }

    function _wideFeed(uint16 dev, uint16 drift) internal pure returns (FeedDef memory d) {
        d = _feedDef(86_400, 1800);
        d.feedDeviationThresholdBps = dev;
        d.heartbeatDriftBps = drift;
    }

    /// Lists market 1 with a wide USDC primary (dev 3,000 + drift 3,100 = 6,100 bps).
    function _listWide(uint16 cf, uint16 prf) internal {
        vm.startPrank(address(timelock));
        store.setFeedAgreementToleranceBps(usdc, 3100);
        store.setFeedAgreementToleranceBps(usdt, 150);
        store.setFeed(address(fUsdc), _wideFeed(3000, 3100));
        store.setFeed(address(fUsdcAlt), _feedDef(86_400, 1800));
        store.setFeed(address(fUsdt), _feedDef(86_400, 1800));
        store.setFeed(address(fUsdtAlt), _feedDef(86_400, 1800));
        store.setTokenCollateralFactorBps(usdc, cf);
        store.setTokenCollateralFactorBps(usdt, cf);
        MarketParams memory p = _launchMarketParams();
        p.poolRiskFactor = prf;
        store.setInitialMarketParams(M, p);
        vm.stopPrank();
    }

    /// F1: raising poolRiskFactor to reach CF_LP = 3,999 re-checks SPEC-CF-004 and reverts...
    function test_PoC_F1_poolRiskFactorRaiseRechecksMargin() public {
        _listWide(9999, 1000); // CF_LP = 999, margin 9,001 > 6,100
        _activate();
        _tl();
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        store.setPoolRiskFactor(M, 4000); // CF_LP 3,999, margin 6,001 <= 6,100
    }

    /// ...but reaching the same CF_LP through setTokenCollateralFactorBps is accepted.
    function test_PoC_F1_collateralFactorRaiseBreaksListingMargin() public {
        _listWide(1000, 4000); // CF_LP = 400, margin 9,600 > 6,100
        _activate();
        vm.startPrank(address(timelock));
        store.setTokenCollateralFactorBps(usdc, 9999);
        store.setTokenCollateralFactorBps(usdt, 9999);
        vm.stopPrank();
        uint256 cfLp = (uint256(9999) * store.getMarketParams(M).poolRiskFactor) / 10_000;
        assertEq(cfLp, 3999);
        assertLe(10_000 - cfLp, 6100, "SPEC-CF-004 now violated, no revert");
    }

    /// F2: a standby-route feed is changed with no tolerance check (it is not in force); after the guardian's
    /// standby switch the token's tolerance is below its lower bound and the short-delay tighten of an unrelated
    /// feed field reverts LivenessBound.
    function test_PoC_F2_standbySwitchBlocksShortDelayTighten() public {
        MockAggregator fStby = new MockAggregator(8, 1e6, 1e12);
        registry.setToken(usdc, _one(address(fUsdc)), _one(address(fUsdcAlt)), _one(address(fStby)));
        _listMarket();
        _activate();
        // Normal-delay feed change of the standby feed: dev 200 bps. Not re-checked against tolerance 150.
        _tl();
        store.setFeed(address(fStby), _wideFeed(200, 25));
        // Guardian: useStandbyRoute(usdc, Primary) -> routes in force become [fStby] / [fUsdcAlt].
        registry.setActiveRoutes(usdc, _one(address(fStby)), _one(address(fUsdcAlt)));
        assertGt(store.feedAgreementToleranceMinBps(usdc), store.feedAgreementToleranceBps(usdc));
        // Short-delay emergency tighten of the alternate feed's borrow age now fails closed.
        uint32 age = store.borrowPriceMaxAge(address(fUsdcAlt));
        _tl();
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenBorrowPriceMaxAge(address(fUsdcAlt), age - 3600);
        // A real LPOracle would also fail its feed-agreement check, which blocks the consistency tighten too.
        lpOracle.setFailed(1);
        _tl();
        vm.expectRevert();
        store.tightenConsistencyToleranceBps(M, 40);
    }

    /// F3: restoreSecondSource changes the served second source with no checkConfig and emits on a no-op.
    function test_PoC_F3_restoreSecondSourceNoRecheck() public {
        _listMarket();
        address pyth = address(new MockAggregator(8, 1, 2));
        SecondSource memory src;
        (src.kind, src.source, src.toleranceBps) = (SecondSourceKind.OracleNetwork, pyth, 50);
        _tl();
        store.setSecondSource(usdc, src, SecondSource(SecondSourceKind.None, address(0), bytes32(0), 0, 0, 0));
        lpOracle.setFailed(type(uint256).max);
        _tl();
        store.restoreSecondSource(usdc); // not on standby, config failing: still succeeds
        assertFalse(store.onStandby(usdc));
    }

    /// Info: logic contracts are callable directly and emit store events from their own address.
    function test_PoC_Info_logicCallableDirectly() public {
        ParameterStoreTightenLogic t = ParameterStoreTightenLogic(logics.tighten);
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        t.tightenMaxShortfallBps(0);
        t.tightenGateRecoverySeconds(7200); // writes the logic's own storage, emits ParameterTightened
        assertEq(store.gateRecoverySeconds(), 1800);
    }

    /// Info: an undeployed (counterfactual) PositionProxy address passes the fee-recipient check.
    function test_PoC_Info_counterfactualProxyRecipient() public {
        address predicted = makeAddr("predictedPositionProxy");
        _tl();
        store.setFeeRecipient(predicted);
        assertEq(store.feeRecipient(), predicted);
    }
}
