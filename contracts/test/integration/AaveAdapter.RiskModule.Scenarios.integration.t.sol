// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title AaveAdapterRiskModuleScenariosIntegrationTest
/// @notice Account scope, gate precedence and the repay with collateral against the reviewed RiskModule on the real
/// Aave V4 Spoke: the Adapter's own bounds (deadline, pause state, proxy, debt reserve, receiver, freeze, nonce) come
/// before any RiskModule gate; the RiskModule's scope is the account's one market and every reserve it borrows;
/// a repay with collateral and every exit never call the RiskModule, so no gate it applies can stop them.
/// forge-config: default.isolate = false
contract AaveAdapterRiskModuleScenariosIntegrationTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1000e6);
    }

    function _borrowExpect(
        bytes memory err
    ) internal {
        uint256 n = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, n);
    }

    function _withdrawExpect(
        bytes memory err
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 0);
    }

    function _stopEverythingTheRiskModuleReads() internal {
        lpOracleA.setState(PriceState.Expired, 0, false);
        usdcOracle.setReport(PriceState.Expired, uint64(block.timestamp), false);
        registry.setLatched(bytes32(MARKET_ID), BreakerReasons.MANUAL, 0);
        swap.setActiveKeeperCount(0);
        RiskSequencerFeed feed = new RiskSequencerFeed();
        feed.set(1, block.timestamp - 1, false);
        rstore.setSequencer(address(feed), 3600);
    }

    // ─── Precedence: the Adapter's bounds before the RiskModule ───

    // TEST-027 verifies: REQ-PROXY-015, REQ-PROXY-026, REQ-ADAPTER-008
    /// @notice With every RiskModule gate failing, the Adapter's own bounds still decide first, each in its order:
    /// the pause state (Frozen, Paused), the receiver rule, the freeze, then the nonce; only a borrow that passes them
    /// meets the RiskModule's first failing gate (the sequencer).
    function test_TEST_027_adapterBoundsPrecedeRiskGates() public {
        _stopEverythingTheRiskModuleReads();
        _pause(PauseState.Frozen, PauseReason.None);
        _borrowExpect(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationFrozen.selector));
        _pause(PauseState.Paused, PauseReason.General);
        _borrowExpect(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector));
        _pause(PauseState.None, PauseReason.None);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, vt));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, vt, d, 0, 2);
        registry.setFrozen(alice, true);
        _borrowExpect(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice));
        registry.setFrozen(alice, false);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.BadNonce.selector, 2, 9));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 9);
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector));
    }

    // TEST-019 verifies: REQ-PROXY-036, REQ-ADAPTER-046, REQ-ADAPTER-045, REQ-PROXY-026
    /// @notice A withdrawal with debt: Paused refuses in the Adapter whatever the RiskModule says; under Frozen the
    /// Adapter lets it through and the RiskModule's gate decides.
    function test_TEST_019_withDebtPrecedence() public {
        lpOracleA.setState(PriceState.Expired, 0, false);
        _pause(PauseState.Paused, PauseReason.General);
        _withdrawExpect(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector));
        _pause(PauseState.Frozen, PauseReason.None);
        _withdrawExpect(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, MARKET_ID, PriceState.Expired));
        registry.setFrozen(alice, true);
        _withdrawExpect(abi.encodeWithSelector(IAaveAdapterErrors.AddressIsFrozen.selector, alice));
        registry.setFrozen(alice, false);
        lpOracleA.setState(PriceState.Live, 0, true);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 0);
        assertEq(lpVault.ownerOf(k2), alice, "passes under Frozen once Live");
    }

    // TEST-028 verifies: REQ-PROXY-019, REQ-PROXY-020, REQ-ADAPTER-008
    /// @notice The RiskModule's own order: the sequencer first, then the market's price, then the debt prices, then
    /// the breakers; each reached by clearing the one before.
    function test_TEST_028_riskGateOrder() public {
        _stopEverythingTheRiskModuleReads();
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector));
        rstore.setSequencer(address(0), 0);
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, MARKET_ID, PriceState.Expired));
        lpOracleA.setState(PriceState.Live, 0, true);
        _borrowExpect(
            abi.encodeWithSelector(IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), 0)
        );
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.LiquidationHalted.selector, MARKET_ID));
        swap.setActiveKeeperCount(1);
        _borrowExpect(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, BreakerReasons.MANUAL)
        );
        registry.setLatched(bytes32(MARKET_ID), 0, 0);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
    }

    // ─── Scope: one market, every reserve the account borrows ───

    // TEST-203 verifies: REQ-PROXY-018, SPEC-PROXY-006, Q-307
    /// @notice A wallet's two markets are two accounts: market B's price failing stops only market B's borrowing;
    /// market A's account keeps borrowing both reserves.
    function test_TEST_203_marketScopeIsTheAccount() public {
        _pledgeAs(alice, MARKET_B, UNITS);
        lpOracleB.setState(PriceState.Cached, 0, false);
        uint256 d = _deadline();
        address pB = adapterC.proxyOf(alice, MARKET_B);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, MARKET_B, PriceState.Cached));
        vm.prank(alice);
        adapterC.borrow(MARKET_B, debtReserveId, 1e18, alice, d, 0, 0);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1e6);
        assertEq(adapterC.borrowNonce(pB), 0, "B nonce unchanged");
    }

    // TEST-203 verifies: REQ-PROXY-018, SPEC-PROXY-002, REQ-ADAPTER-067
    /// @notice The scope covers the reserve being borrowed even before the account holds it: a GHO-only account
    /// borrowing USDC for the first time is stopped by a stale USDC price.
    function test_TEST_203_borrowedReserveJoinsScope() public {
        (, address pB) = _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(bob, MARKET_ID, debtReserveId, 100e18);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 90_000), true);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtPriceTooOld.selector, usdcReserveId, address(usdcOracle), 90_000
            )
        );
        vm.prank(bob);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, bob, d, 0, 1);
        // Bob's GHO borrowing is untouched: his account owes no USDC.
        _borrowAs(bob, MARKET_ID, debtReserveId, 1e18);
        assertEq(_debtOf(pB, debtReserveId), 101e18, "bob borrows GHO");
    }

    // TEST-030 verifies: REQ-ADAPTER-067, REQ-ADAPTER-057, REQ-PROXY-009, INV-073
    /// @notice A reserve the account still owes but the registry no longer approves stops every borrow and every
    /// withdrawal with debt (`ConfigDrift(0, BorrowedUnapprovedReserve)` in the RiskModule; `UnknownDebtReserve` in the
    /// Adapter for that reserve itself); repay of it and the exits never read the set and pass.
    function test_TEST_030_unapprovedHeldReserve() public {
        DebtReserveDef memory u = _debtDef(usdcReserveId, address(usdcDebt), 6, usdcAssetId);
        u.priceSource = address(usdcOracle);
        u.approved = false;
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, u);
        bytes memory drift =
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.BorrowedUnapprovedReserve);
        _borrowExpect(drift);
        _withdrawExpect(drift);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.UnknownDebtReserve.selector, aave.cdpSpoke, usdcReserveId)
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, alice, d, 0, 2);
        uint256 owed = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, owed);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, owed, true, d);
        assertEq(_debtOf(p, usdcReserveId), 0, "repaid without the set");
    }

    // TEST-030 verifies: REQ-PROXY-009, INV-073
    /// @notice A registry record that disagrees with the Spoke's reserve (another asset) stops borrowing with
    /// `ConfigDrift(0, DebtReserveMismatch)`.
    function test_TEST_030_debtRecordMismatch() public {
        DebtReserveDef memory u = _debtDef(usdcReserveId, address(debt), 6, usdcAssetId);
        u.priceSource = address(usdcOracle);
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, u);
        _borrowExpect(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.DebtReserveMismatch)
        );
    }

    // ─── Repay with collateral and exits reach no RiskModule gate ───

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-086, REQ-ADAPTER-047, Q-356
    /// @notice With every gate the RiskModule applies failing (sequencer aside, which the Adapter itself reads for a
    /// repay with collateral), a repay with collateral completes and calls the RiskModule not once.
    function test_TEST_239_repayWithCollateralCallsNoRiskModule() public {
        lpOracleA.setState(PriceState.Expired, 0, false);
        usdcOracle.setReport(PriceState.Expired, uint64(block.timestamp), false);
        registry.setLatched(bytes32(MARKET_ID), BreakerReasons.MANUAL, 0);
        swap.setActiveKeeperCount(0);
        swap.setDeleverage(1000e18, 2e12, 0);
        vm.expectCall(address(rm), "", 0);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, 500_000_000, debtReserveId);
        vm.prank(alice);
        (uint256 repaid,) = adapterC.repayWithCollateral(params);
        assertEq(repaid, 1000e18, "repaid");
        assertEq(_debtOf(p, debtReserveId), 4000e18, "debt lowered");
    }

    // TEST-099 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-035, INV-043, INV-045
    /// @notice Every exit completes with every RiskModule gate failing, the sequencer down included, and none calls
    /// the RiskModule.
    function test_TEST_099_exitsCallNoRiskModule() public {
        _stopEverythingTheRiskModuleReads();
        vm.expectCall(address(rm), "", 0);
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        (caps[0], caps[1]) = (g, u);
        vm.startPrank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k2), UNITS / 2, ids, caps, _deadline());
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000_000, _mins(), _deadline(), 0);
        adapterC.collectFees(MARKET_ID, _ref(k1), _deadline());
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS - 1_000_000_000, _deadline(), 0);
        adapterC.refreshDebtMark(p);
        vm.stopPrank();
        assertEq(_sharesOf(p, vtReserveId), 0, "account closed");
    }

    // ─── Exact numbers through the reviewed health check ───

    // TEST-027 verifies: SPEC-PROXY-001, REQ-PROXY-022, REQ-PROXY-024
    /// @notice The `Borrowed` health factor is the reviewed RiskModule's value, the Spoke's own: $30,000 at CF 0.80
    /// against 5,000 GHO and 1,000 USDC at $1.00 after a further 4,000 GHO.
    function test_TEST_027_borrowedReportsSpokeHealth() public {
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 4000e18, alice, d, 1.5e18, 2);
        assertEq(_hf(p), uint256(24_000e18) * 1e18 / 10_000e18, "2.4");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.HealthFactorTooLow.selector, uint256(24_000e18) * 1e18 / 11_000e18, 2.3e18
            )
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1000e18, alice, d, 2.3e18, 3);
    }

    // TEST-019 verifies: SPEC-PROXY-001, REQ-PROXY-036
    /// @notice A per-market hard floor above the caller's minimum is the binding requirement.
    function test_TEST_019_hardFloorBinds() public {
        rstore.setHardFloor(MARKET_ID, 5e18);
        // After k2 leaves: $16,000 against $6,000: 2.666….
        uint256 hf = uint256(16_000e18) * 1e18 / 6000e18;
        _withdrawExpect(abi.encodeWithSelector(IRiskModuleErrors.HealthFactorTooLow.selector, hf, 5e18));
        rstore.setHardFloor(MARKET_ID, 2e18);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 0);
    }

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-PROXY-018, REQ-ADAPTER-049
    /// @notice A market breaker is the market's own: market A's latched breaker and Offboarding status stop market A's
    /// account, while the same wallet's account in market B keeps borrowing, and market B's breaker stops only B.
    function test_TEST_028_breakerScopedToMarket() public {
        (, address pB) = _pledgeAs(alice, MARKET_B, UNITS);
        registry.setLatched(bytes32(MARKET_ID), BreakerReasons.MANUAL, 0);
        registry.setMarketStatus(MARKET_ID, MarketStatus.Offboarding);
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, MARKET_ID));
        _borrowAs(alice, MARKET_B, debtReserveId, 100e18);
        assertEq(_debtOf(pB, debtReserveId), 100e18, "market B borrows");
        registry.setLatched(bytes32(MARKET_B), BreakerReasons.MANUAL, 0);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_B, BreakerReasons.MANUAL)
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_B, debtReserveId, 1e18, alice, d, 0, 1);
    }
}
