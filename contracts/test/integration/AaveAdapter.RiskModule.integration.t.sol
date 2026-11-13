// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

interface IGateSpokeConfigurator {
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
    function updateBorrowable(
        address spoke,
        uint256 reserveId,
        bool borrowable
    ) external;
    function updateReceiveSharesEnabled(
        address spoke,
        uint256 reserveId,
        bool receiveSharesEnabled
    ) external;
    function updateLiquidationFee(
        address spoke,
        uint256 reserveId,
        uint32 dynamicConfigKey,
        uint256 liquidationFee
    ) external;
    function updateReservePriceSource(
        address spoke,
        uint256 reserveId,
        address priceSource
    ) external;
}

interface IGateHubConfigurator {
    function updateSpokeHalted(
        address hub,
        uint256 assetId,
        address spoke,
        bool halted
    ) external;
    function updateSpokeDrawCap(
        address hub,
        uint256 assetId,
        address spoke,
        uint256 drawCap
    ) external;
    function updateSpokeRiskPremiumThreshold(
        address hub,
        uint256 assetId,
        address spoke,
        uint256 riskPremiumThreshold
    ) external;
}

interface IGateCollateralRisk {
    function updateCollateralRisk(
        address spoke,
        uint256 reserveId,
        uint256 collateralRisk
    ) external;
}

/// @title AaveAdapterRiskModuleIntegrationTest
/// @notice The Adapter with the reviewed RiskModule on the real Aave V4 Spoke: every borrow-side gate of 2.7 reaches
/// a borrower through `borrow` and through a withdrawal or removal that leaves debt, with the RiskModule's own error,
/// while repay, the debt-free exits and `repayAllAndWithdraw` never call it and pass in the same states; the
/// rescue-excluded health check; and the drift check against configuration the Aave DAO changes through the real
/// local SpokeConfigurator (the Adapter half of TEST-114, which also runs on a fork).
/// @dev The account holds two records (10,000 and 5,000 vault tokens, $30,000 at CF 80 %) and owes 1,000 GHO and 500
/// USDC; every gate below is opened one at a time from that state.
/// forge-config: default.isolate = false
contract AaveAdapterRiskModuleIntegrationTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 500e6);
    }

    // ─── Helpers ───

    function _expectBorrow(
        bytes memory err,
        uint256 reserveId,
        uint256 amount
    ) internal {
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, reserveId, amount, alice, d, 0, nonce);
        assertEq(adapterC.borrowNonce(p), nonce, "nonce kept");
    }

    function _expectWithdrawWithDebt(
        bytes memory err
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 0);
        uint256[] memory mins = _mins();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k2), 1_000_000, mins, d, 0);
    }

    /// @dev Repay of both reserves by a third party, then `repayAllAndWithdraw` of one record and a debt-free
    /// withdrawal of the other: the exits that never call the RiskModule.
    function _exitsPass() internal {
        _fund(carol, debtReserveId, 10e18);
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 10e18, false, _deadline());
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        (caps[0], caps[1]) = (g, u);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k2), UNITS / 2, ids, caps, _deadline());
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        assertEq(lpVault.ownerOf(k1), alice, "k1 back");
        assertEq(lpVault.ownerOf(k2), alice, "k2 back");
        assertEq(_borrowCountOf(p), 0, "debt-free");
    }

    function _configurator() internal view returns (IGateSpokeConfigurator) {
        return IGateSpokeConfigurator(aave.spokeConfigurator);
    }

    // ─── The gates pass in the normal state ───

    // TEST-028 verifies: REQ-PROXY-019, REQ-PROXY-020, REQ-PROXY-022, REQ-ADAPTER-008, SPEC-PROXY-001, SPEC-PROXY-002, INV-023
    /// @notice With fresh Live prices on the market and both debt reserves, the reviewed RiskModule admits a borrow of
    /// each asset and a withdrawal that leaves debt, poking the market's LPOracle and the USDC DebtOracle each time.
    function test_TEST_028_gatesPassWhenFresh() public {
        uint256 pokesA = lpOracleA.pokes();
        uint256 pokesU = usdcOracle.pokes();
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 100e6);
        assertEq(lpOracleA.pokes(), pokesA + 2, "market oracle poked per borrow");
        assertEq(usdcOracle.pokes(), pokesU + 2, "USDC DebtOracle poked per borrow");
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 1.1e18);
        assertEq(lpVault.ownerOf(k2), alice, "withdrawn with debt");
    }

    // ─── SPEC-PROXY-002: the account price check ───

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-063, REQ-PROXY-066, REQ-PROXY-026, INV-004, INV-072, REQ-ADAPTER-017
    /// @notice A market that is not Live refuses every borrow and every withdrawal or removal with debt with the
    /// RiskModule's `PriceNotLive(market, state)`; repay and the debt-free exits pass in the same state.
    function test_TEST_019_priceNotLive() public {
        PriceState[3] memory states = [PriceState.Drifting, PriceState.Cached, PriceState.Expired];
        for (uint256 i = 0; i < states.length; ++i) {
            lpOracleA.setState(states[i], 0, false);
            bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, MARKET_ID, states[i]);
            _expectBorrow(err, debtReserveId, 1e18);
            _expectBorrow(err, usdcReserveId, 1e6);
            _expectWithdrawWithDebt(err);
        }
        // Live but with borrowing not allowed (an unconfirmed second source): still refused.
        lpOracleA.setState(PriceState.Live, 0, false);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, MARKET_ID, PriceState.Live),
            debtReserveId,
            1e18
        );
        lpOracleA.setState(PriceState.Expired, 0, false);
        _exitsPass();
    }

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-064, INV-004
    // Sources: 2.6 SPEC-PROXY-002 (feed age against heartbeat plus margin)
    /// @notice A collateral input older than its `borrowPriceMaxAge` refuses borrow and with-debt exits with
    /// `PriceTooOld(feed, age)`; one aged exactly the maximum passes; a timestamp in the future reads as age 0 and is
    /// refused.
    function test_TEST_019_collateralFeedAge() public {
        vm.warp(block.timestamp + FEED_AGE);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        vm.warp(block.timestamp + 1);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, FEED_AGE + 1);
        _expectBorrow(err, debtReserveId, 1e18);
        _expectWithdrawWithDebt(err);
        _report(lpOracleA, uint64(block.timestamp + 5));
        _expectBorrow(abi.encodeWithSelector(IRiskModuleErrors.PriceTooOld.selector, feedUsdc, 0), debtReserveId, 1e18);
        _report(lpOracleA, uint64(block.timestamp - FEED_AGE - 1));
        _exitsPass();
    }

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-064, REQ-PROXY-018, INV-072
    // Sources: 2.6 SPEC-PROXY-002 example (a stale USDC price blocks a GHO borrow)
    /// @notice A debt reserve's DebtOracle that is stale or not Live blocks every borrow on the account, a GHO borrow
    /// included although GHO itself has a fixed price, and every with-debt exit: `DebtPriceTooOld(r, source, age)`.
    function test_TEST_019_debtPriceTooOld() public {
        uint64 old = uint64(block.timestamp - 88_201);
        usdcOracle.setReport(PriceState.Live, old, true);
        bytes memory err = abi.encodeWithSelector(
            IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), 88_201
        );
        _expectBorrow(err, debtReserveId, 1e18);
        _expectBorrow(err, usdcReserveId, 1e6);
        _expectWithdrawWithDebt(err);
        usdcOracle.setReport(PriceState.Expired, uint64(block.timestamp), true);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), 0),
            debtReserveId,
            1e18
        );
        _exitsPass();
    }

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-018
    /// @notice A second market of the same wallet is a separate account: a stale USDC price blocks the account that
    /// owes USDC, while the wallet's GHO-only account in market B still borrows GHO.
    function test_TEST_019_staleDebtPriceScopedToAccount() public {
        (, address pB) = _pledgeAs(alice, MARKET_B, UNITS);
        _report(lpOracleB, uint64(block.timestamp));
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 100_000), true);
        _expectBorrow(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), 100_000
            ),
            debtReserveId,
            1e18
        );
        _borrowAs(alice, MARKET_B, debtReserveId, 100e18);
        assertEq(_debtOf(pB, debtReserveId), 100e18, "market B borrows");
    }

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-065, INV-073
    /// @notice A debt reserve whose AaveOracle source differs from the recorded one refuses the borrow with
    /// `UnexpectedDebtPriceSource(r, source)`; the change made by the DAO through the real SpokeConfigurator.
    function test_TEST_019_unexpectedDebtPriceSource() public {
        vm.prank(aaveDao);
        _configurator().updateReservePriceSource(aave.cdpSpoke, debtReserveId, address(usdcPrice));
        bytes memory err = abi.encodeWithSelector(
            IRiskModuleErrors.UnexpectedDebtPriceSource.selector, debtReserveId, address(usdcPrice)
        );
        _expectBorrow(err, debtReserveId, 1e18);
        _expectBorrow(err, usdcReserveId, 1e6);
        _expectWithdrawWithDebt(err);
        _exitsPass();
    }

    // ─── Aave reserve states ───

    // TEST-155 verifies: REQ-PROXY-079, REQ-PROXY-080, REQ-ADAPTER-049, INV-060, ATTACK-112, REQ-RISK-015, REQ-ADAPTER-017, REQ-RISK-032
    // Sources: 5.1 TEST-155, 2.6 two-reserve example (market B's reserve frozen)
    /// @notice The vault-token reserve frozen on Aave refuses every borrow with `ReserveFrozen(reserveId)`; a
    /// withdrawal with debt, repay and the debt-free exits still pass, since Aave still allows them.
    function test_TEST_155_frozenCollateralReserve() public {
        vm.prank(aaveDao);
        _configurator().updateFrozen(aave.cdpSpoke, vtReserveId, true);
        bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, vtReserveId);
        _expectBorrow(err, debtReserveId, 1e18);
        _expectBorrow(err, usdcReserveId, 1e6);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 0);
        assertEq(lpVault.ownerOf(k2), alice, "withdraw with debt passes");
        _fund(alice, debtReserveId, 10e18);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 10e18, false, _deadline());
    }

    // TEST-158 verifies: REQ-PROXY-077, REQ-PROXY-020, ATTACK-112
    /// @notice A paused vault-token or debt reserve refuses a borrow with the RiskModule's `AaveReservePaused` or
    /// `DebtReservePaused` before any Spoke call.
    function test_TEST_158_pausedReserves() public {
        vm.prank(aaveDao);
        _configurator().updatePaused(aave.cdpSpoke, usdcReserveId, true);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.DebtReservePaused.selector, usdcReserveId), debtReserveId, 1e18
        );
        vm.startPrank(aaveDao);
        _configurator().updatePaused(aave.cdpSpoke, usdcReserveId, false);
        _configurator().updatePaused(aave.cdpSpoke, vtReserveId, true);
        vm.stopPrank();
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.AaveReservePaused.selector, vtReserveId), debtReserveId, 1e18
        );
        _fund(alice, usdcReserveId, 1e6);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 1e6, false, _deadline());
    }

    // ─── Offboarding and breakers ───

    // TEST-213 verifies: REQ-ADAPTER-049, REQ-ADAPTER-086, REQ-PROXY-020, REQ-RISK-034
    /// @notice An `Offboarding` market refuses new borrowing (`MarketOffboarding`) while a withdrawal with debt,
    /// repay and every exit continue.
    function test_TEST_213_offboardingRefusesBorrowOnly() public {
        registry.setMarketStatus(MARKET_ID, MarketStatus.Offboarding);
        bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, MARKET_ID);
        _expectBorrow(err, debtReserveId, 1e18);
        _expectBorrow(err, usdcReserveId, 1e6);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000, _mins(), _deadline(), 0);
        _exitsPassAfterRemoval();
    }

    function _exitsPassAfterRemoval() internal {
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        (caps[0], caps[1]) = (g, u);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k2), UNITS / 2, ids, caps, _deadline());
        assertEq(_borrowCountOf(p), 0, "debt-free");
    }

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-ADAPTER-049, REQ-ADAPTER-086, REQ-RISK-065, INV-072
    /// @notice A latched market breaker refuses every borrow and every withdrawal with debt with
    /// `BreakerTripped(market, reasons)`; repay and the debt-free exits read no breaker and pass.
    function test_TEST_028_latchedMarketBreaker() public {
        registry.setLatched(bytes32(MARKET_ID), BreakerReasons.MANUAL, 0);
        bytes memory err =
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, BreakerReasons.MANUAL);
        _expectBorrow(err, debtReserveId, 1e18);
        _expectWithdrawWithDebt(err);
        _exitsPass();
    }

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-RISK-065, REQ-RISK-015
    /// @notice A live pool-depth condition trips the market breaker the same way.
    function test_TEST_028_liveDepthBreaker() public {
        riskVault.setDepth(0, false);
        bytes memory err =
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, BreakerReasons.POOL_DEPTH);
        _expectBorrow(err, debtReserveId, 1e18);
        _expectWithdrawWithDebt(err);
        riskVault.setDepth(2e13, true);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
    }

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-RISK-065
    /// @notice A debt breaker on the borrowed reserve refuses that borrow (`DebtBreakerTripped(spoke, r, reasons)`)
    /// but not a borrow of another reserve; at a withdrawal with debt every reserve the account holds is checked.
    function test_TEST_028_debtBreaker() public {
        registry.setLatched(keccak256(abi.encode(aave.cdpSpoke, usdcReserveId)), BreakerReasons.DEFICIT, 0);
        bytes memory err = abi.encodeWithSelector(
            IRiskModuleErrors.DebtBreakerTripped.selector, aave.cdpSpoke, usdcReserveId, BreakerReasons.DEFICIT
        );
        _expectBorrow(err, usdcReserveId, 1e6);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        _expectWithdrawWithDebt(err);
        _exitsPass();
    }

    // TEST-068 verifies: REQ-PROXY-020, REQ-PROXY-066
    /// @notice With no committed liquidation operator, or no usable route from a pool token into a debt asset of the
    /// account, borrowing stops (`LiquidationHalted`, `DebtLiquidationHalted`) and repay still passes.
    function test_TEST_068_liquidationHaltStopsBorrowing() public {
        swap.setActiveKeeperCount(0);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, MARKET_ID), debtReserveId, 1e18
        );
        swap.setActiveKeeperCount(1);
        registry.setRouteDown(MARKET_ID, address(usdt), address(usdcDebt), 0, true);
        registry.setRouteDown(MARKET_ID, address(usdt), address(usdcDebt), 1, true);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.DebtLiquidationHalted.selector, usdcReserveId), debtReserveId, 1e18
        );
        registry.setRouteDown(MARKET_ID, address(usdt), address(usdcDebt), 0, false);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        registry.setRouteDown(MARKET_ID, address(usdt), address(usdcDebt), 0, true);
        _fund(alice, usdcReserveId, 1e6);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 1e6, false, _deadline());
    }

    // ─── Sequencer and the LPOracle poke ───

    // TEST-275 verifies: REQ-ADAPTER-102, REQ-RISK-081, REQ-PROXY-026
    /// @notice While the sequencer is down borrow and with-debt exits revert `SequencerDown()`, during the grace
    /// period `SequencerGrace(end)`; repay and the debt-free exits pass.
    function test_TEST_275_sequencerGate() public {
        RiskSequencerFeed feed = new RiskSequencerFeed();
        rstore.setSequencer(address(feed), 3600);
        feed.set(1, block.timestamp - 10, false);
        bytes memory down = abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector);
        _expectBorrow(down, debtReserveId, 1e18);
        _expectWithdrawWithDebt(down);
        feed.set(0, block.timestamp - 10, false);
        bytes memory grace =
            abi.encodeWithSelector(IRiskModuleErrors.SequencerGrace.selector, block.timestamp - 10 + 3600);
        _expectBorrow(grace, debtReserveId, 1e18);
        _expectWithdrawWithDebt(grace);
        feed.set(1, block.timestamp - 10, false);
        _exitsPass();
    }

    // TEST-028 verifies: REQ-PROXY-081, REQ-PROXY-019, REQ-ADAPTER-039
    /// @notice An LPOracle `poke()` that reverts makes the borrow revert with its data and changes nothing.
    function test_TEST_028_pokeRevertPropagates() public {
        lpOracleA.setPokeReverts(true);
        _expectBorrow(abi.encodeWithSignature("Error(string)", "poke"), debtReserveId, 1e18);
        _expectWithdrawWithDebt(abi.encodeWithSignature("Error(string)", "poke"));
        assertEq(_debtOf(p, debtReserveId), 1000e18, "no new debt");
    }

    // ─── Health check with rescue units ───

    // TEST-236 verifies: REQ-PROXY-022, SPEC-PROXY-001, REQ-RISK-068, REQ-ADAPTER-059, INV-025
    // Sources: 2.6 SPEC-PROXY-001 (rescue units valued at zero)
    /// @notice Rescue units count for Aave but not for the reviewed RiskModule's health check: a borrow that Aave
    /// admits but that only the rescue units support reverts `HealthFactorTooLow`, and the same borrow without them in
    /// the excluded value passes.
    function test_TEST_236_rescueUnitsExcluded() public {
        riskModule.setRescue(true);
        _pledgeAs(alice, MARKET_ID, UNITS);
        riskModule.setRescue(false);
        // Regular collateral $30,000 × 0.80 = $24,000; rescue $20,000 × 0.80 = $16,000; debt ≈ $1,500.
        uint256 aaveHf = _hf(p);
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectPartialRevert(IRiskModuleErrors.HealthFactorTooLow.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 25_000e18, alice, d, 0, nonce);
        assertGt(aaveHf, 1e18, "Aave admits");
        _borrowAs(alice, MARKET_ID, debtReserveId, 20_000e18);
        assertGt(_hf(p), 1.6e18, "Aave counts the rescue units");
    }

    // TEST-019 verifies: REQ-PROXY-036, REQ-PROXY-067, SPEC-PROXY-001
    /// @notice A withdrawal with debt is checked after the release, against the remaining collateral: a minimum
    /// health factor above what remains reverts `HealthFactorTooLow(hf, minHf)` with the Spoke's own value.
    function test_TEST_019_withdrawHealthAfterRelease() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 13_000e18);
        // After k2 leaves: $20,000 × 0.80 = $16,000 against 14,000 GHO + 500 USDC.
        uint256 d = _deadline();
        vm.expectPartialRevert(IRiskModuleErrors.HealthFactorTooLow.selector);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 1.2e18);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 1.05e18);
        assertGe(_hf(p), 1.05e18, "at or above the minimum");
    }

    // ─── Drift against the real local configurators (TEST-114, Adapter side) ───

    // TEST-114 verifies: REQ-PROXY-020, REQ-ADAPTER-008, REQ-ADAPTER-086, INV-029, INV-073
    // Sources: 5.1 TEST-114 (local configurators; the fork run is separate)
    /// @notice Each critical setting the Aave DAO changes on the CDP Spoke makes the reviewed RiskModule refuse
    /// borrowing on the account with `ConfigDrift(market, reason)`, while repay and the exits stay open.
    function test_TEST_114_receiveSharesDrift() public {
        vm.prank(aaveDao);
        _configurator().updateReceiveSharesEnabled(aave.cdpSpoke, vtReserveId, true);
        bytes memory err =
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.ReceiveSharesOn);
        _expectBorrow(err, debtReserveId, 1e18);
        _expectWithdrawWithDebt(err);
        _exitsPass();
    }

    // TEST-114 verifies: REQ-PROXY-020, INV-029, INV-093
    function test_TEST_114_liquidationFeeDrift() public {
        uint32 key = IAaveV4Spoke(aave.cdpSpoke).getReserve(vtReserveId).dynamicConfigKey;
        vm.prank(aaveDao);
        _configurator().updateLiquidationFee(aave.cdpSpoke, vtReserveId, key, 100);
        _expectBorrow(
            abi.encodeWithSelector(
                IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.LiquidationFeeNonZero
            ),
            debtReserveId,
            1e18
        );
        _exitsPass();
    }

    // TEST-114 verifies: REQ-PROXY-009, REQ-PROXY-020, INV-073
    /// @notice The vault-token reserve made borrowable, or another reserve made borrowable outside the registry's
    /// set, is a Spoke-wide drift (`DebtReserveSet`).
    function test_TEST_114_borrowableDrift() public {
        vm.prank(aaveDao);
        _configurator().updateBorrowable(aave.cdpSpoke, vtReserveIdB, true);
        bytes memory err = abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.DebtReserveSet);
        _expectBorrow(err, debtReserveId, 1e18);
        vm.startPrank(aaveDao);
        _configurator().updateBorrowable(aave.cdpSpoke, vtReserveIdB, false);
        _configurator().updateBorrowable(aave.cdpSpoke, vtReserveId, true);
        vm.stopPrank();
        _expectBorrow(err, debtReserveId, 1e18);
        _exitsPass();
    }

    // TEST-114 verifies: REQ-PROXY-020, INV-017, ATTACK-106
    /// @notice A new price source for the vault-token reserve (no longer the market's LPOracle) is drift
    /// (`PriceSource`).
    function test_TEST_114_collateralPriceSourceDrift() public {
        vm.prank(aaveDao);
        _configurator().updateReservePriceSource(aave.cdpSpoke, vtReserveId, address(lpOracleB));
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.PriceSource),
            debtReserveId,
            1e18
        );
        _exitsPass();
    }

    // TEST-114 verifies: REQ-PROXY-020, REQ-ADAPTER-063
    /// @notice A Spoke implementation the registry no longer reports as current is drift (`SpokeImplementation`).
    function test_TEST_114_implementationDrift() public {
        registry.setImplementationStale(true);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.SpokeImplementation),
            debtReserveId,
            1e18
        );
        _exitsPass();
    }

    // TEST-114 verifies: REQ-PROXY-020, INV-029
    /// @notice An unchanged configuration has no drift, and reverting the DAO's change reopens borrowing.
    function test_TEST_114_driftClearsWhenReverted() public {
        vm.prank(aaveDao);
        _configurator().updateReceiveSharesEnabled(aave.cdpSpoke, vtReserveId, true);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.ReceiveSharesOn),
            debtReserveId,
            1e18
        );
        vm.prank(aaveDao);
        _configurator().updateReceiveSharesEnabled(aave.cdpSpoke, vtReserveId, false);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
    }

    // TEST-026 verifies: REQ-ADAPTER-008, REQ-PROXY-026
    /// @notice The Adapter's own bounds still come first: an unknown debt reserve reverts in the Adapter before the
    /// RiskModule is called, whatever the RiskModule would say.
    function test_TEST_026_adapterBoundsBeforeRiskModule() public {
        lpOracleA.setState(PriceState.Expired, 0, false);
        _expectBorrow(
            abi.encodeWithSelector(IAaveAdapterErrors.UnknownDebtReserve.selector, aave.cdpSpoke, vtReserveId),
            vtReserveId,
            1e18
        );
    }

    // TEST-114 verifies: REQ-PROXY-020, INV-029, INV-093
    /// @notice A non-zero draw cap for the vault-token asset is drift (`DrawCapNonZero`).
    function test_TEST_114_vaultTokenDrawCapDrift() public {
        vm.prank(aaveDao);
        IGateHubConfigurator(aave.hubConfigurator).updateSpokeDrawCap(aave.hub, vtAssetId, aave.cdpSpoke, 1);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.DrawCapNonZero),
            debtReserveId,
            1e18
        );
        _exitsPass();
    }

    // TEST-114 verifies: REQ-PROXY-020, INV-029
    /// @notice The Hub halting the Spoke on the vault-token asset is drift (`SpokeHalted`) for borrowing; repay of a
    /// debt asset is unaffected.
    function test_TEST_114_spokeHaltedDrift() public {
        vm.prank(aaveDao);
        IGateHubConfigurator(aave.hubConfigurator).updateSpokeHalted(aave.hub, vtAssetId, aave.cdpSpoke, true);
        _expectBorrow(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.SpokeHalted),
            debtReserveId,
            1e18
        );
        _fund(carol, debtReserveId, 10e18);
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 10e18, false, _deadline());
    }

    // TEST-114 verifies: REQ-PROXY-020, INV-029
    /// @notice A collateral risk at or above a debt reserve's risk-premium threshold is drift
    /// (`CollateralRiskAboveThreshold`); below it is not.
    function test_TEST_114_collateralRiskDrift() public {
        vm.startPrank(aaveDao);
        IGateHubConfigurator(aave.hubConfigurator)
            .updateSpokeRiskPremiumThreshold(aave.hub, ghoAssetId, aave.cdpSpoke, 100);
        IGateCollateralRisk(aave.spokeConfigurator).updateCollateralRisk(aave.cdpSpoke, vtReserveId, 99);
        vm.stopPrank();
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        vm.prank(aaveDao);
        IGateCollateralRisk(aave.spokeConfigurator).updateCollateralRisk(aave.cdpSpoke, vtReserveId, 100);
        _expectBorrow(
            abi.encodeWithSelector(
                IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.CollateralRiskAboveThreshold
            ),
            debtReserveId,
            1e18
        );
        _exitsPass();
    }

    // TEST-019 verifies: SPEC-PROXY-002, REQ-PROXY-065, INV-073
    /// @notice A DebtOracle replaced on the AaveOracle for the USDC reserve (another source than the recorded one)
    /// refuses a USDC borrow and a GHO borrow on the account with `UnexpectedDebtPriceSource(usdc, source)`; restoring
    /// the recorded source reopens borrowing.
    function test_TEST_019_debtSourceSwapOnHeldReserve() public {
        vm.prank(aaveDao);
        _configurator().updateReservePriceSource(aave.cdpSpoke, usdcReserveId, address(debtPrice));
        bytes memory err = abi.encodeWithSelector(
            IRiskModuleErrors.UnexpectedDebtPriceSource.selector, usdcReserveId, address(debtPrice)
        );
        _expectBorrow(err, usdcReserveId, 1e6);
        _expectBorrow(err, debtReserveId, 1e18);
        vm.prank(aaveDao);
        _configurator().updateReservePriceSource(aave.cdpSpoke, usdcReserveId, address(usdcOracle));
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1e6);
    }
}
