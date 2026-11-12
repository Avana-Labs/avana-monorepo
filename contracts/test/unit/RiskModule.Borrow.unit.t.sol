// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title RiskModuleBorrowUnitTest
/// @notice `preBorrowCheck` and `preWithdrawCheck`: scope, pokes, price gates, Aave pauses and freezes, drift, Hub
/// shares, liquidation halts, breakers and the sequencer gate, in the order of 2.7 Borrow-side checks.
contract RiskModuleBorrowUnitTest is RiskModuleFixture {
    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
    }

    function _borrow(
        uint256 r
    ) internal {
        riskModule.preBorrowCheck(address(proxy), r, 1);
    }

    // TEST-028 verifies: REQ-ADAPTER-024, REQ-RISK-056, REQ-RISK-077, INV-023, INV-024
    // Sources: 2.7 LIFECYCLE step 3
    function test_TEST_028_borrowPassesAndPokes() public {
        uint256 before = oracle.pokes();
        _borrow(GHO_RESERVE);
        assertEq(oracle.pokes(), before + 1);
        // A USDC borrow also pokes the USDC DebtOracle (no fixed price).
        uint256 debtBefore = usdcOracle.pokes();
        _borrow(USDC_RESERVE);
        assertEq(usdcOracle.pokes(), debtBefore + 1);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-278 verifies: REQ-RISK-077, REQ-RISK-083, REQ-RISK-008
    function test_TEST_278_noMinimumDebt() public {
        rSpoke.setAccount(address(proxy), 0, 0, 0);
        rSpoke.setStatus(address(proxy), GHO_RESERVE, false, false);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-163 verifies: REQ-RISK-056, REQ-ORACLE-096, INV-004, REQ-ADAPTER-039
    function test_TEST_163_pokeRevertPropagates() public {
        oracle.setPokeReverts(true);
        vm.expectRevert(bytes("poke"));
        _borrow(GHO_RESERVE);
        vm.expectRevert(bytes("poke"));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-028 verifies: REQ-ADAPTER-011, REQ-ADAPTER-013, REQ-ADAPTER-014, REQ-ADAPTER-022, INV-024
    function test_TEST_028_scope() public {
        address other = makeAddr("otherSpoke");
        PositionProxy foreign = new PositionProxy(address(adapter), wallet, other, mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownSpoke.selector, other));
        riskModule.preBorrowCheck(address(foreign), GHO_RESERVE, 1);
        // A collateral reserve that is not the account's market.
        rSpoke.setStatus(address(proxy), USDC_RESERVE, true, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, USDC_RESERVE));
        _borrow(GHO_RESERVE);
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, false);
        // A borrowed reserve the registry has not enabled.
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.BorrowedUnapprovedReserve)
        );
        _borrow(3);
        // An enabled reserve whose Aave reserve no longer matches its definition.
        IAaveV4Spoke.Reserve memory r;
        (r.underlying, r.hub, r.assetId, r.decimals) = (address(gho), address(hub), uint16(GHO_ASSET), 6);
        IAaveV4Spoke.ReserveConfig memory c;
        c.borrowable = true;
        spoke.setReserve(GHO_RESERVE, r, c, IAaveV4Spoke.DynamicReserveConfig(0, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.DebtReserveMismatch)
        );
        _borrow(USDC_RESERVE);
    }

    // TEST-028 verifies: REQ-ADAPTER-015, REQ-ADAPTER-016, REQ-ADAPTER-055, INV-024
    // Sources: 2.7 REQ-ADAPTER-016 (per-feed heartbeat plus margin, 88,200 s)
    function test_TEST_028_collateralPriceGates() public {
        oracle.setState(PriceState.Drifting, 1 << 3, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Drifting));
        _borrow(GHO_RESERVE);
        oracle.setState(PriceState.Live, 0, true);
        _report(uint64(block.timestamp - FEED_AGE), 1e8, 1e8);
        _borrow(GHO_RESERVE);
        _report(uint64(block.timestamp - FEED_AGE - 1), 1e8, 1e8);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, FEED_AGE + 1));
        _borrow(GHO_RESERVE);
        _report(uint64(block.timestamp), 1e8, 1e8);
        oracle.setState(PriceState.Live, 0, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, mid, PriceState.Live));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-276 verifies: REQ-ORACLE-100, SPEC-ORC-020
    function test_TEST_276_secondSourceDisagrees() public {
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(usdt));
        address[] memory feeds = new address[](2);
        (feeds[0], feeds[1]) = (feedUsdc, feedUsdt);
        uint64[] memory ats = new uint64[](2);
        (ats[0], ats[1]) = (uint64(block.timestamp), uint64(block.timestamp));
        uint256[] memory q = new uint256[](2);
        uint32[] memory reasons = new uint32[](2);
        reasons[1] = 1 << 4;
        oracle.setTokens(toks, feeds, ats, q, reasons);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SecondSourceDisagrees.selector, address(usdt)));
        _borrow(GHO_RESERVE);
    }

    // TEST-201 verifies: REQ-RISK-061, REQ-ADAPTER-055, INV-072
    function test_TEST_201_debtPriceGatesAccountWide() public {
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        usdcOracle.setReport(PriceState.Drifting, uint64(block.timestamp), false);
        // A GHO borrow is refused while the account's USDC debt price is not Live.
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), 0)
        );
        _borrow(GHO_RESERVE);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 88_201), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), 88_201
            )
        );
        riskModule.preWithdrawCheck(address(proxy));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        aaveOracle.setSource(USDC_RESERVE, address(ghoSource));
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.UnexpectedDebtPriceSource.selector, USDC_RESERVE, address(ghoSource)
            )
        );
        _borrow(GHO_RESERVE);
    }

    // TEST-158 verifies: REQ-ADAPTER-061, REQ-ADAPTER-062, REQ-RISK-061, INV-060, REQ-ACCESS-130
    function test_TEST_158_aavePauses() public {
        IAaveV4Spoke.ReserveConfig memory c;
        (c.borrowable, c.paused) = (true, true);
        rSpoke.setConfig(GHO_RESERVE, c);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, GHO_RESERVE));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, GHO_RESERVE));
        riskModule.preWithdrawCheck(address(proxy));
        c.paused = false;
        rSpoke.setConfig(GHO_RESERVE, c);
        IAaveV4Spoke.ReserveConfig memory v;
        v.paused = true;
        rSpoke.setConfig(VT_RESERVE, v);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, VT_RESERVE));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, VT_RESERVE));
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-155 verifies: REQ-ADAPTER-019, REQ-ADAPTER-025, REQ-ADAPTER-056, REQ-PROXY-079, INV-060, REQ-ACCESS-036, REQ-RISK-032, REQ-RISK-034
    function test_TEST_155_frozenAndOffboardingBlockBorrowOnly() public {
        IAaveV4Spoke.ReserveConfig memory v;
        v.frozen = true;
        rSpoke.setConfig(VT_RESERVE, v);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, VT_RESERVE));
        _borrow(GHO_RESERVE);
        riskModule.preWithdrawCheck(address(proxy));
        // Frozen with no supplied shares does not block.
        rSpoke.setSupplied(address(proxy), VT_RESERVE, 0);
        _borrow(GHO_RESERVE);
        rSpoke.setConfig(VT_RESERVE, IAaveV4Spoke.ReserveConfig(0, false, false, false, false));
        vm.prank(address(timelock));
        registry.setMarketOffboarding(mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, mid));
        _borrow(GHO_RESERVE);
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-033 verifies: REQ-ADAPTER-020, REQ-ADAPTER-030, REQ-RISK-069, INV-029
    function test_TEST_033_driftOnAccountKey() public {
        // The account's own dynamic key carries a liquidation fee while the latest key is clean.
        IAaveV4Spoke.DynamicReserveConfig memory d;
        (d.collateralFactor, d.maxLiquidationBonus, d.liquidationFee) = (3000, 10_500, 100);
        rSpoke.setDynamicAt(VT_RESERVE, 7, d);
        rSpoke.setUserKey(address(proxy), VT_RESERVE, 7);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, mid, DriftReason.LiquidationFeeNonZero)
        );
        _borrow(GHO_RESERVE);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, mid, DriftReason.LiquidationFeeNonZero)
        );
        riskModule.preWithdrawCheck(address(proxy));
        // The pledge-side drift check reads only the latest key.
        riskModule.checkAaveConfig(address(spoke), _ids());
    }

    // TEST-028 verifies: REQ-ADAPTER-021, REQ-ADAPTER-058
    function test_TEST_028_hubSharesNotEqualAssets() public {
        rHub.setAdded(VT_ASSET, 1000, 999);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.HubSharesNotEqualAssets.selector, mid));
        _borrow(GHO_RESERVE);
    }

    // TEST-068 verifies: REQ-ADAPTER-010, REQ-RISK-062, REQ-RISK-071, REQ-ADAPTER-054, REQ-ACCESS-075, REQ-ROUTE-021
    // Sources: 2.7 REQ-RISK-071 example (freezing the last committed operator)
    function test_TEST_068_liquidationHalts() public {
        swap.setKeepers(0);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, mid));
        riskModule.preWithdrawCheck(address(proxy));
        swap.setKeepers(1);
        // USDT has no usable route into USDC once both routes are gone; USDC itself needs none.
        vm.startPrank(address(timelock));
        registry.disableRoute(mid, address(usdt), address(usdc), 0);
        registry.disableRoute(mid, address(usdt), address(usdc), 1);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, USDC_RESERVE));
        _borrow(USDC_RESERVE);
        _borrow(GHO_RESERVE);
    }

    // TEST-228 verifies: REQ-RISK-065, REQ-RISK-073, SPEC-BRK-008, INV-081, REQ-ACCESS-166, REQ-ACCESS-084
    function test_TEST_228_breakersOnBorrowAndWithdraw() public {
        vm.prank(emergencyGuardian);
        registry.tripDebtBreaker(address(spoke), USDC_RESERVE);
        // A GHO borrow passes; a USDC borrow reverts.
        _borrow(GHO_RESERVE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), USDC_RESERVE, BreakerReasons.MANUAL
            )
        );
        _borrow(USDC_RESERVE);
        // Withdraw-with-debt checks the debt breaker of every reserve held.
        riskModule.preWithdrawCheck(address(proxy));
        rSpoke.setStatus(address(proxy), USDC_RESERVE, false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), USDC_RESERVE, BreakerReasons.MANUAL
            )
        );
        riskModule.preWithdrawCheck(address(proxy));
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(mid);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, mid, BreakerReasons.MANUAL));
        _borrow(GHO_RESERVE);
    }

    // TEST-275 verifies: REQ-RISK-081, REQ-RISK-084, REQ-ORACLE-099
    // Sources: 2.7 REQ-RISK-081 example (restart at 1,000,000; borrow at 1,002,000 reverts until 1,003,600)
    function test_TEST_275_sequencerGate() public {
        RiskSequencerFeed feed = new RiskSequencerFeed();
        store.setSequencer(address(feed), 3600);
        vm.warp(1_002_000);
        _report(uint64(block.timestamp), 1e8, 1e8);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        feed.set(0, 1_000_000, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SequencerGrace.selector, 1_003_600));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.SequencerGrace.selector, 1_003_600));
        riskModule.preWithdrawCheck(address(proxy));
        vm.warp(1_003_600);
        _report(uint64(block.timestamp), 1e8, 1e8);
        _borrow(GHO_RESERVE);
        feed.set(1, 1_003_000, false);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        _borrow(GHO_RESERVE);
    }

    // TEST-028 verifies: REQ-ADAPTER-016, REQ-RISK-061, INV-024
    function test_TEST_028_futureTimestampsAreNeverFresh() public {
        // A collateral feed dated after the block: PriceTooOld(feed, 0).
        _report(uint64(block.timestamp + 1), 1e8, 1e8);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, 0));
        _borrow(GHO_RESERVE);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, 0));
        riskModule.preWithdrawCheck(address(proxy));
        _report(uint64(block.timestamp), 1e8, 1e8);
        // A debt price served with a time after the block: DebtPriceTooOld(r, source, 0).
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp + 1), true);
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, USDC_RESERVE, address(usdcOracle), 0)
        );
        _borrow(USDC_RESERVE);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        _borrow(USDC_RESERVE);
    }

    // TEST-028 verifies: REQ-ADAPTER-013, REQ-RISK-009, INV-024
    function test_TEST_028_marketNotActiveOrOffboarding() public {
        // A proxy of a market that is still Registered, and of a market without a record.
        uint256 registered = _listRegisteredMarket();
        PositionProxy p = new PositionProxy(address(adapter), wallet, address(spoke), registered);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, 0));
        riskModule.preBorrowCheck(address(p), GHO_RESERVE, 1);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, 0));
        riskModule.preWithdrawCheck(address(p));
        p = new PositionProxy(address(adapter), wallet, address(spoke), 999);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.UnknownCollateral.selector, 0));
        riskModule.preWithdrawCheck(address(p));
    }

    // TEST-275 verifies: REQ-RISK-081, REQ-RISK-084
    function test_TEST_275_unreadableSequencerFeedIsDown() public {
        // A feed address without code returns nothing: the gate reads it as down.
        store.setSequencer(makeAddr("noCodeFeed"), 3600);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        _borrow(GHO_RESERVE);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        riskModule.preWithdrawCheck(address(proxy));
        // A reverting feed is down too.
        RiskSequencerFeed feed = new RiskSequencerFeed();
        feed.set(0, 0, true);
        store.setSequencer(address(feed), 3600);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        _borrow(GHO_RESERVE);
    }

    function _ids() internal view returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = mid;
    }
}
